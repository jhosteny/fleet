defmodule Fleet.WorkerBootTest do
  use ExUnit.Case, async: false

  test "fresh BEAM boots the real worker supervision tree and executes a durable robot" do
    # An unnamed stdio peer needs no distribution socket. This exercises the real
    # worker app and its configuration even in a network-restricted sandbox.
    {:ok, peer, _node} =
      :peer.start(%{connection: :standard_io, args: [~c"+S", ~c"2:2"]})

    try do
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
      :ok = :peer.call(peer, Application, :load, [:fleet])
      :ok = :peer.call(peer, Application, :put_env, [:fleet, :worker, true])
      :ok = :peer.call(peer, Application, :put_env, [:fleet, :store_node, :nonode@nohost])
      :ok = :peer.call(peer, Application, :put_env, [:logger, :level, :error])

      dir =
        Path.join(
          System.tmp_dir!(),
          "fleet-worker-test-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      :ok = :peer.call(peer, Application, :put_env, [:fleet, :data_dir, dir])

      # Replace only the remote storage service with a local instance in this
      # isolated VM. The worker tree, backend, actor and boot sequence are real.
      {:ok, _store} = :peer.call(peer, Fleet.Store, :start_link, [[]])
      assert {:ok, _apps} = :peer.call(peer, Application, :ensure_all_started, [:fleet], 30_000)
      assert true == :peer.call(peer, DurableServer.Supervisor, :ready?, [Fleet.Actors])
      assert {:ok, {pid, _}} = :peer.call(peer, Fleet.Worker, :ensure, [1])
      Process.sleep(500)
      assert {:ok, robot} = :peer.call(peer, GenServer, :call, [pid, :pause])
      assert robot.ticks > 0
      assert robot.paused
      assert robot.commands == 1
    after
      :peer.stop(peer)
    end
  end
end
