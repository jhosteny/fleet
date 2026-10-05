defmodule Fleet.Worker do
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    host = Application.fetch_env!(:fleet, :store_node)

    children = [
      {DurableServer.Supervisor,
       name: Fleet.Actors,
       prefix: "warehouse/",
       backend: {Fleet.Backend, host: host},
       init_info: %{host: host},
       discovery_interval_ms: 1_000,
       initial_discovery_delay_ms: 200,
       heartbeat_interval_ms: 500,
       heartbeat_staleness_threshold_ms: 3_000,
       parallel_restart_batch_size: 30,
       crash_threshold_count: 1_000_000,
       module_circuit_breaker_count: 1_000_000,
       global_lock_failure_count: 1_000_000,
       group: [log: false]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def ensure(id) do
    DurableServer.Supervisor.ensure_started_child(
      Fleet.Actors,
      {Fleet.Robot, key: "robot/#{id}", initial_state: Fleet.Robot.initial(id)},
      local_only: true
    )
  end

  def command(id, command) do
    case DurableServer.Supervisor.lookup(Fleet.Actors, "robot/#{id}") do
      {pid, _} -> GenServer.call(pid, command, 10_000)
      nil -> {:error, :recovering}
    end
  end
end
