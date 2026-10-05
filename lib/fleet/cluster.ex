defmodule Fleet.Cluster do
  @moduledoc "Owns only the local demo peer VMs. Actor recovery belongs to DurableServer."
  use GenServer
  require Logger
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def action(action), do: GenServer.cast(__MODULE__, {:action, action})
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    if Application.get_env(:fleet, :start_cluster, true), do: send(self(), :boot)

    {:ok,
     %{
       peers: %{},
       region: "east",
       generation: 0,
       chaos: 0,
       chaos_epoch: 0,
       busy: false,
       booting: 0
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info(:boot, state) do
    case enable_distribution() do
      :ok ->
        Fleet.Telemetry.event(:system, "Control plane online · provisioning three BEAM VMs")
        Process.send_after(self(), :chaos, 6_000)
        {:noreply, launch(state, ["a", "b", "c"])}

      {:error, reason} ->
        Logger.error("Fleet distribution failed: #{inspect(reason)}")
        Fleet.Telemetry.event(:error, "Distribution failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:peer_ready, label, {:ok, peer, worker}}, state) do
    Process.link(peer)
    Process.monitor(peer)

    entry = %{
      peer: peer,
      node: worker,
      alive: true,
      region: label |> String.split("-") |> hd(),
      os_pid: to_string(:rpc.call(worker, :os, :getpid, []))
    }

    state = %{
      state
      | peers: Map.put(state.peers, label, entry),
        booting: max(0, state.booting - 1)
    }

    publish_nodes(state)
    Fleet.Telemetry.event(:system, "#{label} online · OS process #{entry.os_pid}")

    state =
      if state.booting == 0 do
        seed(state)
        %{state | busy: false}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:peer_ready, label, {:error, reason}}, state) do
    Logger.error("Fleet worker #{label} failed to boot: #{inspect(reason)}")
    Fleet.Telemetry.event(:error, "#{label} failed to boot: #{inspect(reason)}")
    state = %{state | booting: max(0, state.booting - 1)}
    if state.booting == 0, do: seed(state)
    {:noreply, %{state | busy: state.booting > 0}}
  end

  def handle_info({:DOWN, _ref, :process, peer, reason}, state) do
    case Enum.find(state.peers, fn {_, entry} -> entry.peer == peer end) do
      {label, %{alive: true} = entry} ->
        state = put_in(state.peers[label], %{entry | alive: false})
        Fleet.Telemetry.event(:failure, "#{label} offline · #{inspect(reason)}")
        publish_nodes(state)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:chaos, state) do
    Process.send_after(self(), :chaos, 6_000)
    alive = alive(state)

    if state.chaos > 0 and not state.busy and length(alive) > 1 and
         :rand.uniform(100) <= state.chaos do
      {label, _} = Enum.random(alive)
      Process.send_after(self(), {:restore_now, label, state.chaos_epoch}, 4000)
      {:noreply, kill(state, label)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:restore_now, _label, epoch}, state) when epoch != state.chaos_epoch do
    {:noreply, state}
  end

  def handle_info({:restore_now, label, epoch}, state) do
    case state.peers[label] do
      %{alive: false} when not state.busy ->
        {:noreply, launch_labels(state, [label])}

      %{alive: false} ->
        Process.send_after(self(), {:restore_now, label, epoch}, 1000)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:action, {:chaos, value}}, state),
    do: {:noreply, %{state | chaos: max(0, min(100, value))}}

  def handle_cast({:action, {:kill, label}}, state), do: {:noreply, kill(state, label)}

  def handle_cast({:action, :destroy}, %{busy: true} = state) do
    Fleet.Telemetry.event(
      :error,
      "Wait for worker provisioning to finish before destroying the cluster"
    )

    {:noreply, state}
  end

  def handle_cast({:action, :destroy}, state) do
    state = Enum.reduce(alive(state), state, fn {label, _}, acc -> kill(acc, label) end)
    Fleet.Telemetry.event(:failure, "All worker VMs destroyed · persisted robot state survives")
    {:noreply, %{state | chaos: 0, chaos_epoch: state.chaos_epoch + 1}}
  end

  def handle_cast({:action, :restore}, %{busy: false} = state) do
    dead = for {label, %{alive: false}} <- state.peers, do: label
    {:noreply, if(dead == [], do: state, else: launch_labels(state, dead))}
  end

  def handle_cast({:action, :west}, %{busy: false} = state) do
    if alive(state) == [] do
      state = %{state | region: "west", generation: state.generation + 1}

      Fleet.Telemetry.event(
        :system,
        "Provisioning fresh west cluster · discovering durable actors"
      )

      {:noreply, launch(state, ["x", "y", "z"])}
    else
      Fleet.Telemetry.event(:error, "Destroy the current worker cluster before moving to west")
      {:noreply, state}
    end
  end

  def handle_cast({:action, {:scale, count}}, state) when count in [300, 1000, 5000] do
    Application.put_env(:fleet, :robot_count, count)
    seed(state)
    {:noreply, state}
  end

  def handle_cast({:action, _}, state), do: {:noreply, state}

  def command(id, command) when command in [:pause, :resume, :charge] do
    peers = status() |> alive()

    case peers do
      [{_, entry} | _] ->
        try do
          :erpc.call(entry.node, Fleet.Worker, :command, [id, command], 15_000)
        catch
          _, _ -> {:error, :recovering}
        end

      [] ->
        {:error, :offline}
    end
  end

  defp enable_distribution do
    if Node.alive?() do
      :ok
    else
      System.cmd("epmd", ["-daemon"])
      name = String.to_atom("fleet_control_#{System.pid()}")

      case Node.start(name, :shortnames) do
        {:ok, _} ->
          Node.set_cookie(:fleet_local_demo_cookie)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp alive(state),
    do: state.peers |> Enum.filter(fn {_, entry} -> entry.alive end) |> Enum.sort()

  defp launch(state, letters) do
    labels = Enum.map(letters, &"#{state.region}-#{&1}-#{state.generation}-#{System.pid()}")
    launch_labels(state, labels)
  end

  defp launch_labels(state, labels) do
    parent = self()
    host = node()
    paths = :code.get_path()
    cookie = Node.get_cookie()

    Enum.each(labels, fn label ->
      Task.Supervisor.start_child(Fleet.Tasks, fn ->
        result =
          try do
            # :peer uses Erlang's own VM executable and a stdio control channel.
            name = String.to_atom(label)

            {:ok, peer, worker} =
              :peer.start(%{
                name: name,
                connection: :standard_io,
                args: [~c"+S", ~c"2:2", ~c"-setcookie", Atom.to_charlist(cookie)],
                wait_boot: 30_000
              })

            try do
              :ok = :peer.call(peer, :code, :add_paths, [paths])
              :ok = :peer.call(peer, Application, :load, [:fleet])
              :ok = :peer.call(peer, Application, :put_env, [:fleet, :worker, true])
              :ok = :peer.call(peer, Application, :put_env, [:fleet, :store_node, host])
              :ok = :peer.call(peer, Application, :put_env, [:logger, :level, :error])
              {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:fleet], 30_000)
              true = :peer.call(peer, Node, :connect, [host])
              {:ok, peer, worker}
            rescue
              error ->
                :peer.stop(peer)
                {:error, Exception.message(error)}
            catch
              kind, reason ->
                :peer.stop(peer)
                {:error, {kind, reason}}
            end
          rescue
            error -> {:error, Exception.message(error)}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(parent, {:peer_ready, label, result})
      end)
    end)

    %{state | busy: labels != [], booting: state.booting + length(labels)}
  end

  defp seed(state) do
    peers = alive(state) |> Enum.map(fn {_, entry} -> entry.node end)
    count = Application.get_env(:fleet, :robot_count, 300)

    if peers != [] do
      Fleet.Telemetry.event(:system, "Addressing #{count} durable robot identities")

      Task.Supervisor.start_child(Fleet.Tasks, fn ->
        1..count
        |> Task.async_stream(
          fn id ->
            worker = Enum.at(peers, rem(id - 1, length(peers)))

            try do
              :erpc.call(worker, Fleet.Worker, :ensure, [id], 30_000)
            catch
              _, _ -> {:error, :node_down}
            end
          end,
          max_concurrency: 30,
          timeout: 40_000,
          on_timeout: :kill_task
        )
        |> Enum.reduce(0, fn
          {:ok, {:ok, _}}, acc -> acc + 1
          _, acc -> acc
        end)
        |> then(fn started ->
          Fleet.Telemetry.event(
            :system,
            "Fleet discovery complete · #{started}/#{count} identities available"
          )
        end)
      end)
    end
  end

  defp kill(state, label) do
    case state.peers[label] do
      %{alive: true} = entry ->
        # Restricted to a PID returned by a VM spawned by this controller.
        if Regex.match?(~r/^\d+$/, entry.os_pid) do
          {_, status} = System.cmd("kill", ["-KILL", entry.os_pid])

          if status == 0 do
            state = put_in(state.peers[label], %{entry | alive: false})
            Fleet.Telemetry.event(:failure, "SIGKILL → #{label} · no graceful shutdown")
            publish_nodes(state)
            state
          else
            Fleet.Telemetry.event(:error, "Could not SIGKILL #{label}")
            state
          end
        else
          state
        end

      _ ->
        state
    end
  end

  defp publish_nodes(state) do
    nodes =
      for {label, entry} <- Enum.sort(state.peers),
          do: %{name: label, alive: entry.alive, region: entry.region, os_pid: entry.os_pid}

    Fleet.Telemetry.nodes(nodes)
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.peers, fn {_, entry} ->
      try do
        :peer.stop(entry.peer)
      catch
        _, _ -> :ok
      end
    end)
  end
end
