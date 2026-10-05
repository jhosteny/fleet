defmodule Fleet.Telemetry do
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def event(kind, message), do: GenServer.cast(__MODULE__, {:event, kind, message})
  def nodes(nodes), do: GenServer.cast(__MODULE__, {:nodes, nodes})

  @impl true
  def init(_opts) do
    Process.send_after(self(), :publish, 200)

    {:ok,
     %{
       robots: %{},
       nodes: [],
       events: [],
       migrations: 0,
       recoveries: 0,
       downtime_total: 0,
       downtime_count: 0,
       selected: nil,
       monitors: %{}
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, public(state), state}

  @impl true
  def handle_cast({:robot, owner, pid, robot}, state) do
    now = System.monotonic_time(:millisecond)
    old = Map.get(state.robots, robot.id)
    label = owner |> Atom.to_string() |> String.split("@") |> hd()
    entry = Map.merge(robot, %{owner: label, pid: pid, online: true, seen: now, down_at: nil})

    state =
      cond do
        old && old.pid != pid ->
          downtime = if old.down_at, do: max(0, now - old.down_at), else: 0

          message =
            "R#{robot.id} · #{old.owner} → #{label} · step #{robot.phase + 1} · #{downtime}ms"

          state
          |> add_event(:recovery, message)
          |> Map.update!(:recoveries, &(&1 + 1))
          |> Map.update!(:migrations, &(&1 + if(old.owner != label, do: 1, else: 0)))
          |> Map.update!(:downtime_total, &(&1 + downtime))
          |> Map.update!(:downtime_count, &(&1 + 1))

        true ->
          state
      end

    state =
      if Map.has_key?(state.monitors, pid) do
        state
      else
        Process.monitor(pid)
        put_in(state.monitors[pid], robot.id)
      end

    {:noreply, put_in(state.robots[robot.id], entry)}
  end

  def handle_cast({:nodes, nodes}, state), do: {:noreply, %{state | nodes: nodes}}
  def handle_cast({:event, kind, message}, state), do: {:noreply, add_event(state, kind, message)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {id, monitors} = Map.pop(state.monitors, pid)
    state = %{state | monitors: monitors}

    state =
      case Map.get(state.robots, id) do
        %{pid: ^pid} = robot ->
          put_in(state.robots[id], %{
            robot
            | online: false,
              down_at: System.monotonic_time(:millisecond)
          })

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info(:publish, state) do
    Phoenix.PubSub.broadcast(Fleet.PubSub, "fleet", {:fleet, public(state)})
    Process.send_after(self(), :publish, 200)
    {:noreply, state}
  end

  defp add_event(state, kind, message) do
    event = %{
      kind: kind,
      message: message,
      time: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    }

    %{state | events: Enum.take([event | state.events], 80)}
  end

  defp public(state) do
    robots = state.robots |> Map.values() |> Enum.map(&Map.drop(&1, [:pid, :seen, :down_at]))
    online = Enum.count(robots, & &1.online)
    completed = Enum.reduce(robots, 0, &(&1.completed + &2))

    %{
      robots: robots,
      nodes: state.nodes,
      events: Enum.take(state.events, 20),
      online: online,
      total: length(robots),
      completed: completed,
      migrations: state.migrations,
      recoveries: state.recoveries,
      recovery_ms:
        if(state.downtime_count > 0,
          do: round(state.downtime_total / state.downtime_count),
          else: 0
        )
    }
  end
end
