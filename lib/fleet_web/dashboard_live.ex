defmodule FleetWeb.DashboardLive do
  use Phoenix.LiveView, layout: false

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet")
    fleet = Fleet.Telemetry.snapshot()
    {:ok, assign(socket, fleet: fleet, selected_id: 1, selected: nil, chaos: 0, notice: nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    id =
      case Integer.parse(params["robot"] || "1") do
        {id, ""} when id > 0 and id <= 5000 -> id
        _ -> 1
      end

    {:noreply,
     assign(socket,
       selected_id: id,
       selected: Enum.find(socket.assigns.fleet.robots, &(&1.id == id))
     )}
  end

  @impl true
  def handle_info({:fleet, fleet}, socket) do
    names = Enum.map(fleet.nodes, & &1.name)

    robots =
      Enum.map(fleet.robots, fn r ->
        [
          r.id,
          Float.round(r.x / 1, 2),
          Float.round(r.y / 1, 2),
          Enum.find_index(names, &(&1 == r.owner)) || 0,
          r.online,
          r.paused,
          r.cargo != nil
        ]
      end)

    selected = Enum.find(fleet.robots, &(&1.id == socket.assigns.selected_id))

    {:noreply,
     socket
     |> assign(fleet: fleet, selected: selected)
     |> push_event("fleet-frame", %{
       robots: robots,
       nodes: names,
       selected: socket.assigns.selected_id
     })}
  end

  def handle_info({:command_result, result}, socket) do
    notice =
      case result do
        {:ok, robot} -> "Command ##{robot.commands} committed to disk"
        {:error, reason} -> "Command not acknowledged: #{reason}. Try again after recovery."
      end

    {:noreply, assign(socket, notice: notice)}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: "/?robot=#{id}")}
  end

  def handle_event("kill", %{"node" => name}, socket) do
    Fleet.Cluster.action({:kill, name})
    {:noreply, socket}
  end

  def handle_event("destroy", _params, socket) do
    Fleet.Cluster.action(:destroy)
    {:noreply, assign(socket, chaos: 0)}
  end

  def handle_event("restore", _params, socket) do
    Fleet.Cluster.action(:restore)
    {:noreply, socket}
  end

  def handle_event("west", _params, socket) do
    Fleet.Cluster.action(:west)
    {:noreply, socket}
  end

  def handle_event("scale", %{"count" => count}, socket) when count in ["300", "1000", "5000"] do
    Fleet.Cluster.action({:scale, String.to_integer(count)})
    {:noreply, socket}
  end

  def handle_event("chaos", %{"rate" => rate}, socket) do
    {value, _} = Integer.parse(rate)
    Fleet.Cluster.action({:chaos, value})
    {:noreply, assign(socket, chaos: value)}
  end

  def handle_event("command", %{"command" => command}, socket)
      when command in ["pause", "resume", "charge"] do
    parent = self()
    id = socket.assigns.selected_id
    command = String.to_existing_atom(command)

    Task.Supervisor.start_child(Fleet.Tasks, fn ->
      send(parent, {:command_result, Fleet.Cluster.command(id, command)})
    end)

    {:noreply, assign(socket, notice: "Sending command to robot/#{id}…")}
  end

  defp robot_count(fleet, name), do: Enum.count(fleet.robots, &(&1.owner == name and &1.online))

  defp phase_label(phase),
    do: Enum.at(["Navigate to pickup", "Pick pallet", "Navigate to drop", "Drop pallet"], phase)

  defp comma(number),
    do: number |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="shell">
      <header class="topbar">
        <a class="brand" href="/"><span class="brand-symbol">◈</span><span>BEAM<span class="brand-divider"> / </span><span class="brand-light">CONTINUUM</span></span></a>
        <span class="header-caption">DURABLE ACTORS · REAL NODE FAILURE</span>
        <div class="live-indicator">
          <i></i> LIVE EXPERIMENT <span id="connection-indicator">CONNECTED</span>
        </div>
      </header>

      <div class="intro">
        <div>
          <div class="eyebrow">THE MACHINE IS TEMPORARY. THE PROCESS IS NOT.</div><h1>
            A fleet that outlives its servers<span>.</span>
          </h1><p>Every dot is a durable Elixir process. Pull the plug. Watch it come back.</p>
        </div>
        <div class="intro-stamp">
          <span>ELIXIR / ERLANG / OTP</span><strong>Built to survive.</strong><small>Three worker VMs. One persistent fleet.</small>
        </div>
      </div>

      <section class="stats" aria-label="Live fleet statistics">
        <div class="stat">
          <span>ROBOTS ONLINE</span><strong>{comma(@fleet.online)}<small> / {comma(@fleet.total)}</small></strong><div class="mini-bar">
            <i style={"width: #{if @fleet.total == 0, do: 0, else: @fleet.online / @fleet.total * 100}%"}></i>
          </div>
        </div>
        <div class="stat">
          <span>ORDERS DELIVERED</span><strong>{comma(@fleet.completed)}</strong><small>Workflow state, carried through recovery</small>
        </div>
        <div class="stat">
          <span>ACTOR RECOVERIES</span><strong class="teal">{comma(@fleet.recoveries)}</strong><small>Restored from committed state</small>
        </div>
        <div class="stat">
          <span>MEAN RECOVERY</span><strong>{@fleet.recovery_ms}<small> ms</small></strong><small>Observed process-down → first report</small>
        </div>
      </section>

      <main class="workspace">
        <section class="map-panel panel">
          <div class="panel-head">
            <div>
              <span class="status-dot"></span><h2>WAREHOUSE / 01</h2><span class="muted">LIVE DIGITAL TWIN</span>
            </div><div class="map-tools">
              <button id="reset-map" type="button">↺ Reset view</button><button
                id="toggle-trails"
                type="button"
              >⌁ Trails</button>
            </div>
          </div>
          <div id="warehouse" phx-hook="Warehouse" phx-update="ignore" class="warehouse">
            <canvas
              id="fleet-canvas"
              aria-label="Warehouse map. Click a robot to inspect its durable state."
            ></canvas>
            <div class="map-coordinate">100 × 64 m <span>LOCAL SIMULATION</span></div>
            <div class="map-help">Click a robot to inspect · Scroll to zoom · Drag to pan</div>
            <div class="map-offline" id="map-offline" hidden>
              <span>WORKER CLUSTER OFFLINE</span><strong>The fleet is on disk.</strong><p>
                Bring up a fresh cluster to resume.
              </p>
            </div>
          </div>
          <div class="map-footer">
            <div class="legend">
              <span><i class="node-0"></i> NODE A</span><span><i class="node-1"></i> NODE B</span><span><i class="node-2"></i>
              NODE C</span><span><i class="offline"></i> RECOVERING</span>
            </div><span class="mono">250 ms ticks · commit before broadcast</span>
          </div>
        </section>

        <aside class="inspector panel">
          <div class="panel-head">
            <h2>ACTOR INSPECTOR</h2><span class="mono">SINGLE IDENTITY</span>
          </div>
          <div class="robot-title">
            <div class="robot-icon">▣</div><div>
              <span class="eyebrow">DURABLE ROBOT</span><h3>
                R-{String.pad_leading(to_string(@selected_id), 4, "0")}
              </h3>
            </div><span class={"pill #{if @selected && @selected.online, do: "ok", else: "waiting"}"}>{if @selected &&
                                                                                                            @selected.online,
                                                                                                          do:
                                                                                                            "ONLINE",
                                                                                                          else:
                                                                                                            "RECOVERING"}</span>
          </div>
          <div :if={@selected} class="robot-details">
            <div class="detail"><span>Process key</span><code>robot/{@selected.id}</code></div>
            <div class="detail"><span>Current host</span><code>{@selected.owner}</code></div>
            <div class="detail"><span>Incarnations</span><strong>{@selected.boots}</strong></div>
            <div class="battery">
              <div><span>BATTERY</span><strong>{Float.round(@selected.battery / 1, 1)}%</strong></div><div class="battery-track">
                <i style={"width: #{@selected.battery}%"}></i>
              </div>
            </div>
            <div class="order-heading">
              <span>ORDER #{@selected.order}</span><span>STATE PRESERVED</span>
            </div>
            <ol class="workflow">
              <li
                :for={phase <- 0..3}
                class={
                  cond do
                    phase < @selected.phase -> "done"
                    phase == @selected.phase -> "current"
                    true -> "future"
                  end
                }
              >
                <span>{if phase < @selected.phase, do: "✓", else: phase + 1}</span><div>
                  {phase_label(phase)}<small :if={phase == @selected.phase}>{if @selected.paused,
                    do: "Paused by operator",
                    else: "Step #{@selected.progress} · mailbox active"}</small>
                </div>
              </li>
            </ol>
            <div class="detail cargo">
              <span>Carrying</span><code>{@selected.cargo || "— empty —"}</code>
            </div>
            <div class="detail">
              <span>Committed ticks</span><strong>{comma(@selected.ticks)}</strong>
            </div>
            <div class="detail">
              <span>Serialized commands</span><strong>{@selected.commands}</strong>
            </div>
            <div class="robot-controls">
              <button
                phx-click="command"
                phx-value-command={if @selected.paused, do: "resume", else: "pause"}
                disabled={!@selected.online}
              >{if @selected.paused, do: "▶ Resume", else: "Ⅱ Pause"}</button><button
                phx-click="command"
                phx-value-command="charge"
                disabled={!@selected.online}
              >ϟ Charge</button>
            </div>
            <a class="actor-link" href={"/?robot=#{@selected_id}"} target="_blank" rel="noopener">↗ Open this actor in another window</a>
          </div>
          <div :if={!@selected} class="empty-state">
            Waiting for robot/{@selected_id} to come online…
          </div>
          <p :if={@notice} class="notice" role="status">{@notice}</p>
        </aside>

        <section class="cluster-panel panel">
          <div class="panel-head">
            <div>
              <h2>THE INFRASTRUCTURE</h2><span class="muted">REAL BEAM VMS</span>
            </div><button phx-click="restore" class="text-button">+ Restore failed nodes</button>
          </div>
          <div class="node-grid">
            <div
              :for={{node, index} <- Enum.with_index(@fleet.nodes)}
              class={"node-card #{if node.alive, do: "", else: "dead"}"}
            >
              <div class="node-card-top">
                <span class={"node-light node-#{rem(index, 3)}"}></span><strong>{node.name}</strong><span class="node-status">{if node.alive,
                  do: "HEALTHY",
                  else: "OFFLINE"}</span>
              </div>
              <div class="node-count">{comma(robot_count(@fleet, node.name))}<span>actors</span></div>
              <div class="node-card-bottom">
                <code>PID {node.os_pid}</code><button
                  phx-click="kill"
                  phx-value-node={node.name}
                  disabled={!node.alive}
                  aria-label={"Kill #{node.name}"}
                >✕ Kill node</button>
              </div>
            </div>
            <div :if={@fleet.nodes == []} class="empty-state">Provisioning worker VMs…</div>
          </div>
          <div class="chaos-controls">
            <form phx-change="chaos">
              <label for="chaos-rate"><span>CHAOS MONKEY</span><strong>{@chaos}%</strong></label><input
                id="chaos-rate"
                type="range"
                name="rate"
                min="0"
                max="100"
                value={@chaos}
                phx-debounce="250"
              /><small>Chance of a worker kill every 6s · restores after 4s</small>
            </form><div class="fleet-scale">
              <span>FLEET SIZE</span><div>
                <button
                  :for={count <- [300, 1000, 5000]}
                  phx-click="scale"
                  phx-value-count={count}
                  disabled={@fleet.total >= count}
                >{comma(count)}</button>
              </div><small>Add actors without stopping the fleet</small>
            </div>
          </div>
          <div class="datacenter-controls">
            <div>
              <strong>Ready for the second act?</strong><span>Destroy the worker cluster. Recover on fresh machines.</span>
            </div><button phx-click="destroy" class="danger-button">↯ Destroy datacenter</button><button
              phx-click="west"
              class="west-button"
            >↗ Boot US-WEST</button>
          </div>
        </section>

        <section class="events-panel panel">
          <div class="panel-head">
            <h2>FLIGHT RECORDER</h2><span class="mono">OBSERVED EVENTS</span>
          </div><div class="event-list">
            <div :for={event <- @fleet.events} class={"event event-#{event.kind}"}>
              <time>{event.time}</time><span class="event-mark">{case event.kind do
                :failure -> "×"
                :recovery -> "↗"
                :error -> "!"
                _ -> "·"
              end}</span><span>{event.message}</span>
            </div><div :if={@fleet.events == []} class="empty-state">
              Listening for cluster events…
            </div>
          </div><div class="event-footer">
            Persistence: Erlang DETS · Store and observer survive worker failures.
          </div>
        </section>
      </main>
      <footer class="page-footer">
        <span>BEAM CONTINUUM <span class="muted">/ A DISTRIBUTED SYSTEMS EXPERIMENT</span></span><span>Phoenix LiveView + DurableServer + OTP
        <span class="footer-dot">◆</span></span>
      </footer>
    </div>
    """
  end
end
