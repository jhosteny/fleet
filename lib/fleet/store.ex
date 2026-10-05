defmodule Fleet.Store do
  @moduledoc """
  Local demonstration storage service. Serializes CAS operations and group commits
  to Erlang DETS. Write acknowledgements follow dets.sync, never precede it.
  Kept outside the worker failure domain; this is not a replicated storage service.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def request(host, message), do: GenServer.call({__MODULE__, host}, message, 30_000)

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :data_dir, Application.fetch_env!(:fleet, :data_dir))
    File.mkdir_p!(dir)

    {:ok, table} =
      :dets.open_file(:fleet_disk,
        file: String.to_charlist(Path.join(dir, "fleet.dets")),
        type: :set
      )

    objects = :dets.foldl(fn {key, value}, acc -> Map.put(acc, key, value) end, %{}, table)
    {:ok, %{table: table, objects: objects, pending: %{}, replies: [], timer: nil, writes: 0}}
  end

  @impl true
  def handle_call(:ready, _from, state), do: {:reply, :ok, state}

  def handle_call(:stats, _from, state),
    do: {:reply, %{objects: map_size(state.objects), writes: state.writes}, state}

  def handle_call({:get, key}, _from, state) do
    reply =
      case Map.fetch(state.objects, key) do
        {:ok, object} -> {:ok, object}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:list, prefix}, _from, state) do
    objects =
      for {key, object} <- state.objects,
          String.starts_with?(key, prefix),
          do: Map.put(object, :key, key)

    {:reply, objects, state}
  end

  def handle_call({:write, key, body, condition}, from, state) do
    current = Map.get(state.objects, key)

    valid =
      case condition do
        :absent -> current == nil
        :any -> true
        {:etag, etag} -> current != nil and current.etag == etag
      end

    if valid do
      object = %{
        body: body,
        etag: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }

      state = %{
        state
        | objects: Map.put(state.objects, key, object),
          pending: Map.put(state.pending, key, object)
      }

      {:noreply, queue_reply(state, from, {:ok, object})}
    else
      {:reply, {:error, :conflict}, state}
    end
  end

  def handle_call({:delete, key}, from, state) do
    state = %{
      state
      | objects: Map.delete(state.objects, key),
        pending: Map.put(state.pending, key, :deleted)
    }

    {:noreply, queue_reply(state, from, :ok)}
  end

  defp queue_reply(state, from, reply) do
    timer = state.timer || Process.send_after(self(), :commit, 20)
    %{state | replies: [{from, reply} | state.replies], timer: timer}
  end

  @impl true
  def handle_info(:commit, state) do
    {deleted, writes} = Enum.split_with(state.pending, fn {_, value} -> value == :deleted end)
    Enum.each(deleted, fn {key, _} -> :ok = :dets.delete(state.table, key) end)
    :ok = :dets.insert(state.table, writes)
    :ok = :dets.sync(state.table)
    Enum.each(state.replies, fn {from, reply} -> GenServer.reply(from, reply) end)

    {:noreply,
     %{state | pending: %{}, replies: [], timer: nil, writes: state.writes + length(writes)}}
  end

  @impl true
  def terminate(_reason, state), do: :dets.close(state.table)
end
