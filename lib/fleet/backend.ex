defmodule Fleet.Backend do
  @moduledoc "DurableServer storage adapter for the demo's Erlang DETS service."
  @behaviour DurableServer.StorageBackend

  @impl true
  def init_backend(opts),
    do: {:ok, %{state: Keyword.fetch!(opts, :host), features: %{list_includes_body?: true}}}

  @impl true
  def ensure_ready(host), do: Fleet.Store.request(host, :ready)
  @impl true
  def get_object(host, key, _opts) do
    with {:ok, object} <- Fleet.Store.request(host, {:get, key}), do: decode_object(host, object)
  end

  @impl true
  def list_all_objects_stream(host, prefix, _opts) do
    Stream.map(Fleet.Store.request(host, {:list, prefix}), fn object ->
      {:ok, decoded} = decode_object(host, object)
      Map.put(decoded, :key, object.key)
    end)
  end

  @impl true
  def put_object(host, key, body, opts) do
    condition = if opts[:etag], do: {:etag, opts[:etag]}, else: :any

    with {:ok, encoded} <- encode(host, body) do
      case Fleet.Store.request(host, {:write, key, encoded, condition}) do
        {:ok, object} -> decode_object(host, object)
        error -> error
      end
    end
  end

  @impl true
  def delete_object(host, key), do: Fleet.Store.request(host, {:delete, key})
  @impl true
  def try_claim(host, key, body) do
    with {:ok, encoded} <- encode(host, body) do
      case Fleet.Store.request(host, {:write, key, encoded, :absent}) do
        {:ok, object} -> {:ok, {:claimed, object.etag}}
        {:error, :conflict} -> {:error, :already_claimed}
        error -> error
      end
    end
  end

  @impl true
  def update_object(host, key, fun, opts),
    do: update(host, key, fun, Keyword.get(opts, :max_retries, 5))

  defp update(host, key, fun, attempts) do
    with {:ok, object} <- get_object(host, key, []),
         {:ok, decoded} <- decode_object(host, object),
         {:ok, new_body} <- fun.(decoded) do
      case put_object(host, key, new_body, etag: object.etag) do
        {:error, :conflict} when attempts > 0 -> update(host, key, fun, attempts - 1)
        result -> result
      end
    end
  end

  @impl true
  def encode(_host, %DurableServer.StoredState{} = state),
    do: {:ok, DurableServer.StoredState.to_storage_term(state)}

  def encode(_host, term), do: {:ok, term}
  @impl true
  def decode(_host, term) do
    case DurableServer.StoredState.from_storage_term(term) do
      :not_stored_state -> {:ok, term}
      result -> result
    end
  end

  defp decode_object(host, object) do
    with {:ok, body} <- decode(host, object.body), do: {:ok, %{object | body: body}}
  end
end
