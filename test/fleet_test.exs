defmodule FleetTest do
  use ExUnit.Case, async: false

  test "unknown routes return 404 without a missing error template exception" do
    conn = FleetWeb.Endpoint.call(Plug.Test.conn(:get, "/does-not-exist"), [])
    assert conn.status == 404
    assert conn.resp_body == "Not Found"
  end

  test "error renderers handle server errors without exposing exception details" do
    assert FleetWeb.ErrorHTML.render("500.html", %{reason: "private details"}) ==
             "Internal Server Error"

    assert FleetWeb.ErrorJSON.render("500.json", %{reason: "private details"}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end

  test "dashboard and bundled browser assets are served by the endpoint" do
    conn = FleetWeb.Endpoint.call(Plug.Test.conn(:get, "/"), [])
    assert conn.status == 200
    assert conn.resp_body =~ "A fleet that outlives its servers"
    assert conn.resp_body =~ "phx-hook=\"Warehouse\""
    assert conn.resp_body =~ "csrf-token"

    for path <- [
          "/assets/app.js",
          "/assets/app.css",
          "/vendor/phoenix/phoenix.mjs",
          "/vendor/liveview/phoenix_live_view.esm.js"
        ] do
      assert FleetWeb.Endpoint.call(Plug.Test.conn(:get, path), []).status == 200
    end
  end

  test "conditional claims and writes fence stale owners" do
    key = "test/cas/#{System.unique_integer([:positive])}"
    host = node()
    assert {:ok, {:claimed, etag}} = Fleet.Backend.try_claim(host, key, %{value: 1})
    assert {:error, :already_claimed} = Fleet.Backend.try_claim(host, key, %{value: 2})
    assert {:ok, %{etag: new_etag}} = Fleet.Backend.put_object(host, key, %{value: 2}, etag: etag)
    assert new_etag != etag
    assert {:error, :conflict} = Fleet.Backend.put_object(host, key, %{value: 3}, etag: etag)
    assert {:ok, %{body: %{value: 2}}} = Fleet.Backend.get_object(host, key, [])
    assert :ok = Fleet.Backend.delete_object(host, key)
  end

  test "only one concurrent writer can claim the same identity" do
    key = "test/race/#{System.unique_integer([:positive])}"
    host = node()

    results =
      1..30
      |> Task.async_stream(fn _ -> Fleet.Backend.try_claim(host, key, %{}) end,
        max_concurrency: 30
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, {:claimed, _}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_claimed})) == 29
    Fleet.Backend.delete_object(host, key)
  end

  test "acknowledged writes have reached the DETS file" do
    key = "test/disk/#{System.unique_integer([:positive])}"
    assert {:ok, object} = Fleet.Backend.put_object(node(), key, %{mission: 37}, [])
    assert [{^key, stored}] = :dets.lookup(:fleet_disk, key)
    assert stored == object
    Fleet.Backend.delete_object(node(), key)
  end

  test "a paused robot does not advance its mission" do
    robot = %{Fleet.Robot.initial(42) | paused: true, cargo: "PLT-99", progress: 37}
    assert Fleet.Robot.advance(robot) == robot
  end

  test "robot completes a pickup and delivery without crossing storage racks" do
    start = Fleet.Robot.initial(42)

    robot =
      Enum.reduce_while(1..1000, start, fn _, robot ->
        next = Fleet.Robot.advance(robot)
        if next.y != robot.y, do: assert(next.x == 12.0 or next.x == 88.0)
        if next.completed == 1, do: {:halt, next}, else: {:cont, next}
      end)

    assert robot.completed == 1
    assert robot.cargo == nil
    assert robot.order == start.order + 5000
    assert robot.battery < start.battery
  end

  test "DurableServer reloads mission and command state after an ungraceful process kill" do
    sup = :fleet_test_actors

    start_supervised!(
      {DurableServer.Supervisor,
       name: sup,
       prefix: "test/durable/",
       backend: {Fleet.Backend, host: node()},
       init_info: %{host: node()},
       initial_discovery_delay_ms: 60_000,
       group: [log: false]}
    )

    key = "robot/#{System.unique_integer([:positive])}"
    spec = {Fleet.Robot, key: key, initial_state: Fleet.Robot.initial(1042)}
    assert {:ok, {pid, _}} = DurableServer.Supervisor.ensure_started_child(sup, spec)
    assert {:ok, before} = GenServer.call(pid, :pause)

    results =
      1..20
      |> Task.async_stream(fn _ -> GenServer.call(pid, :charge) end, max_concurrency: 20)
      |> Enum.map(fn {:ok, {:ok, robot}} -> robot.commands end)

    assert MapSet.size(MapSet.new(results)) == 20
    assert Enum.max(results) == before.commands + 20
    charged = GenServer.call(pid, :snapshot)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    # Wait for registry cleanup; this explicit address recovers the same stored key.
    assert {:ok, {restored_pid, _}} = DurableServer.Supervisor.ensure_started_child(sup, spec)
    after_restart = GenServer.call(restored_pid, :snapshot)
    assert after_restart.paused
    assert after_restart.ticks == before.ticks
    assert after_restart.order == before.order
    assert after_restart.phase == before.phase
    assert after_restart.commands == charged.commands
    assert after_restart.battery == 100.0
    assert after_restart.boots == before.boots + 1
    DurableServer.Supervisor.terminate_child(sup, restored_pid)
    Fleet.Backend.delete_object(node(), "test/durable/" <> key)
  end

  test "lifecycle manager automatically discovers and recovers a killed permanent actor" do
    sup = :fleet_auto_recovery_test

    start_supervised!(
      {DurableServer.Supervisor,
       name: sup,
       prefix: "test/automatic/",
       backend: {Fleet.Backend, host: node()},
       init_info: %{host: node()},
       initial_discovery_delay_ms: 100,
       discovery_interval_ms: 100,
       heartbeat_interval_ms: 100,
       group: [log: false]}
    )

    key = "robot/#{System.unique_integer([:positive])}"
    spec = {Fleet.Robot, key: key, initial_state: Fleet.Robot.initial(1043)}
    assert {:ok, {pid, _}} = DurableServer.Supervisor.ensure_started_child(sup, spec)
    assert {:ok, paused} = GenServer.call(pid, :pause)
    Process.exit(pid, :kill)
    deadline = System.monotonic_time(:millisecond) + 8000

    wait = fn wait ->
      case DurableServer.Supervisor.lookup(sup, key) do
        {new_pid, _} when new_pid != pid ->
          new_pid

        _ ->
          assert System.monotonic_time(:millisecond) < deadline, "automatic recovery timed out"
          Process.sleep(50)
          wait.(wait)
      end
    end

    replacement = wait.(wait)
    restored = GenServer.call(replacement, :snapshot)
    assert restored.ticks == paused.ticks
    assert restored.order == paused.order
    assert restored.commands == paused.commands
    assert restored.boots == paused.boots + 1
    DurableServer.Supervisor.terminate_child(sup, replacement)
    Fleet.Backend.delete_object(node(), "test/automatic/" <> key)
  end
end
