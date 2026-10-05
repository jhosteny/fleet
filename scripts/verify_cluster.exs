# Run with: mix run --no-start scripts/verify_cluster.exs
# Real VM integration check. Uses its own fresh temporary store, then shuts down.
data_dir = Path.join(System.tmp_dir!(), "fleet-check-#{System.unique_integer([:positive])}")
Application.put_env(:fleet, :data_dir, data_dir)
Application.put_env(:fleet, :robot_count, 30)
Application.put_env(:fleet, :start_cluster, true)
Application.put_env(:fleet, FleetWeb.Endpoint,
  Keyword.put(Application.get_env(:fleet, FleetWeb.Endpoint), :server, false))
{:ok, _} = Application.ensure_all_started(:fleet)

wait = fn predicate, timeout ->
  deadline = System.monotonic_time(:millisecond) + timeout
  recur = fn recur ->
    if predicate.() do
      :ok
    else
      case Enum.find(Fleet.Telemetry.snapshot().events, &(&1.kind == :error)) do
        nil -> :ok
        event -> raise(event.message)
      end
      if System.monotonic_time(:millisecond) > deadline, do: raise("Timed out waiting for fleet")
      Process.sleep(100)
      recur.(recur)
    end
  end
  recur.(recur)
end

try do
  wait.(fn -> Fleet.Telemetry.snapshot().online == 30 end, 60_000)
  {:ok, paused} = Fleet.Cluster.command(1, :pause)
  before = Fleet.Telemetry.snapshot().robots |> Enum.find(&(&1.id == 1))
  Fleet.Cluster.action({:kill, before.owner})
  wait.(fn -> Fleet.Telemetry.snapshot().online < 30 end, 10_000)
  wait.(fn -> Fleet.Telemetry.snapshot().online == 30 end, 30_000)
  restored = Fleet.Telemetry.snapshot().robots |> Enum.find(&(&1.id == 1))
  true = restored.owner != before.owner
  true = restored.paused
  true = restored.order == paused.order
  true = restored.ticks == paused.ticks
  true = restored.commands == paused.commands
  IO.puts("PASS: real VM SIGKILL → cross-node recovery with identical committed mission")

  Fleet.Cluster.action(:destroy)
  wait.(fn -> Fleet.Telemetry.snapshot().online == 0 end, 10_000)
  Fleet.Cluster.action(:west)
  wait.(fn -> Fleet.Telemetry.snapshot().online == 30 end, 60_000)
  restored = Fleet.Telemetry.snapshot().robots |> Enum.find(&(&1.id == 1))
  true = String.starts_with?(restored.owner, "west-")
  true = restored.order == paused.order
  true = restored.ticks == paused.ticks
  true = restored.commands == paused.commands
  IO.puts("PASS: total worker outage → fresh west VMs → durable fleet recovery")
after
  Application.stop(:fleet)
  IO.puts("Integration data retained at #{data_dir}")
end
