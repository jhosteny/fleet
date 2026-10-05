defmodule DurableServer.ObjectStore do
  @moduledoc """
  S3-compatible object storage client for bucket and object operations.

  The object path is intentionally generic and works with S3-compatible
  endpoints.

  Authentication can be supplied either as static `:access_key_id` /
  `:secret_access_key` values or through `:credential_provider`, which may
  resolve to short-lived credentials with a session token.

  ## Consistency

  The client defaults to the configured `:default_region` and can opt into the
  alternate `:region` with `consistent: false`. This is primarily useful for
  backends that distinguish between a stronger default region and a lower-latency
  local region.
  """

  @default_timeout 30_000

  @derive {Inspect, only: []}
  defstruct access_key_id: nil,
            secret_access_key: nil,
            token: nil,
            credential_provider: nil,
            region: nil,
            default_region: nil,
            s3_endpoint: nil,
            bucket: nil,
            req_opts: nil,
            s3: nil,
            json_codec: nil,
            xml_codec: nil,
            iam: nil,
            headers: [],
            finch: nil,
            task_supervisor: nil

  require Logger
  require ReqS3

  alias Req

  # Create ObjectStore client with default configuration
  @valid_new_opts [
    :headers,
    :bucket,
    :region,
    :default_region,
    :req_opts,
    :s3_endpoint,
    :access_key_id,
    :secret_access_key,
    :token,
    :credential_provider,
    :finch,
    :task_supervisor
  ]

  def new(%__MODULE__{} = client, opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @valid_new_opts)

    merged_opts =
      Enum.map(@valid_new_opts, fn key ->
        case Keyword.fetch(opts, key) do
          {:ok, value} -> {key, value}
          :error -> {key, Map.get(client, key)}
        end
      end)

    Map.merge(client, new(merged_opts))
  end

  @required_opts [:bucket, :s3_endpoint, :default_region]

  def new(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @valid_new_opts)

    Enum.each(@required_opts, fn key ->
      unless Keyword.has_key?(opts, key) do
        raise ArgumentError, "DurableServer.ObjectStore.new/1 requires #{inspect(key)}"
      end
    end)

    credential_provider = Keyword.get(opts, :credential_provider)

    if credential_provider == nil do
      Enum.each([:access_key_id, :secret_access_key], fn key ->
        unless Keyword.has_key?(opts, key) do
          raise ArgumentError, "DurableServer.ObjectStore.new/1 requires #{inspect(key)}"
        end
      end)
    end

    headers = Keyword.get(opts, :headers, [])
    region = opts[:region] || "auto"

    default_region =
      case opts[:default_region] do
        default when default in [nil, "auto"] ->
          raise ArgumentError,
                "#{inspect(__MODULE__)} :default_region must be set and cannot be \"auto\""

        default when is_binary(default) ->
          default
      end

    {access_key_id, secret_access_key, token} =
      if credential_provider == nil do
        {Keyword.fetch!(opts, :access_key_id), Keyword.fetch!(opts, :secret_access_key), opts[:token]}
      else
        {nil, nil, nil}
      end

    %__MODULE__{
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      token: token,
      credential_provider: credential_provider,
      region: region,
      default_region: default_region,
      s3_endpoint: Keyword.fetch!(opts, :s3_endpoint),
      bucket: Keyword.fetch!(opts, :bucket),
      req_opts: opts[:req_opts] || [],
      json_codec: JSON,
      xml_codec: SweetXml,
      headers: headers,
      finch: opts[:finch] || DurableServer.Finch,
      task_supervisor: opts[:task_supervisor] || DurableServer.TaskSupervisor
    }
  end

  def ensure_bucket_exists(%__MODULE__{} = client) do
    case create_bucket(client, client.bucket) do
      {:error, %{status: 409}} -> :ok
      {:ok, %__MODULE__{}} -> :ok
    end
  end

  @doc """
  Creates a bucket on the configured object storage endpoint.
  Returns {:ok, bucket_info} on success, or {:error, reason} if creation fails.

  Note: If the bucket already exists, this function will return an error,
  which can be handled by the caller.
  """
  def create_bucket(%__MODULE__{} = client, bucket_name, opts \\ []) do
    # Setup req with ReqS3 using client credentials
    req = new_req(client, headers: opts[:headers] || [], consistent: true)

    # Create bucket
    case Req.request(req,
           method: :put,
           url: "s3://#{bucket_name}",
           params: %{
             "location-constraint" => "us-east-1"
           },
           retry: :transient
         ) do
      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        {:ok, new(client, bucket: bucket_name)}

      {:error, reason} ->
        {:error, reason}

      {:ok, response} ->
        {:error, response}
    end
  end

  @doc """
  Lists all buckets in the account.
  Returns {:ok, buckets} on success, or {:error, reason} if listing fails.
  """
  def list_buckets(%__MODULE__{} = client) do
    req = new_req(client)

    # List buckets
    case Req.request(req, method: :get, url: "s3://") do
      {:ok, %{status: status, body: body}} when status >= 200 and status < 300 ->
        buckets = parse_list_buckets_response(body)
        {:ok, buckets}

      {:error, reason} ->
        {:error, reason}

      {:ok, response} ->
        {:error, response}
    end
  end

  @doc """
  Deletes a bucket. This will fail if the bucket is not empty.
  Returns :ok on success, or {:error, reason} if deletion fails.
  """
  def delete_bucket(%__MODULE__{} = client, bucket_name) do
    req = new_req(client, consistent: true)

    # Delete bucket
    case Req.request(req,
           method: :delete,
           url: "s3://#{bucket_name}"
         ) do
      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        :ok

      {:error, reason} ->
        {:error, reason}

      {:ok, response} ->
        {:error, response}
    end
  end

  def new_req(%__MODULE__{} = client, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, [:headers, :consistent])
    initial_caller_headers = Keyword.get(opts, :headers, [])
    # pop `:consistent` from being merged into req_opts
    {consistent, opts} = Keyword.pop(opts, :consistent, true)

    {caller_headers, computed_region} =
      if consistent do
        {initial_caller_headers, client.default_region}
      else
        {initial_caller_headers, client.region}
      end

    req_opts =
      opts
      |> Keyword.merge(client.req_opts)
      |> Keyword.drop([:headers])

    %{access_key_id: access_key_id, secret_access_key: secret_access_key, token: token} =
      credentials_for(client)

    config =
      %{
        access_key_id: access_key_id,
        secret_access_key: secret_access_key,
        region: computed_region
      }
      |> maybe_put_token(token)

    req =
      Req.new(req_opts)
      |> ReqS3.attach(
        aws_endpoint_url_s3: client.s3_endpoint,
        aws_sigv4: config
      )

    req = Req.merge(req, headers: client.headers ++ caller_headers)

    req_opts = [finch: client.finch, receive_timeout: @default_timeout]

    Req.merge(req, Keyword.merge(req_opts, base_url: "s3://#{client.bucket}"))
  end

  defp credentials_for(%__MODULE__{credential_provider: nil} = client) do
    %{
      access_key_id: client.access_key_id,
      secret_access_key: client.secret_access_key,
      token: client.token
    }
  end

  defp credentials_for(%__MODULE__{credential_provider: provider}) do
    case resolve_credential_provider(provider) do
      {:ok, credentials} ->
        credentials

      {:error, reason} ->
        raise ArgumentError, "failed to resolve credential_provider: #{inspect(reason)}"
    end
  end

  defp maybe_put_token(config, nil), do: config
  defp maybe_put_token(config, token), do: Map.put(config, :token, token)

  defp resolve_credential_provider(%{__struct__: module} = provider) when is_atom(module) do
    cond do
      function_exported?(module, :fetch!, 1) ->
        resolve_credential_provider(apply(module, :fetch!, [provider]))

      function_exported?(module, :fetch, 1) ->
        case apply(module, :fetch, [provider]) do
          {:ok, credentials} -> resolve_credential_provider(credentials)
          other -> {:error, other}
        end

      true ->
        {:error, {:unsupported_credential_provider, provider}}
    end
  end

  defp resolve_credential_provider(%{} = provider) do
    provider |> Map.to_list() |> resolve_credential_provider()
  end

  defp resolve_credential_provider(provider) when is_list(provider) do
    if Keyword.has_key?(provider, :access_key_id) and Keyword.has_key?(provider, :secret_access_key) do
      {:ok,
       %{
         access_key_id: Keyword.fetch!(provider, :access_key_id),
         secret_access_key: Keyword.fetch!(provider, :secret_access_key),
         token: Keyword.get(provider, :token)
       }}
    else
      cond do
        Keyword.has_key?(provider, :fetch!) ->
          resolve_credential_provider(Keyword.fetch!(provider, :fetch!))

        Keyword.has_key?(provider, :fetch) ->
          resolve_credential_provider(Keyword.fetch!(provider, :fetch))

        Keyword.has_key?(provider, :source) ->
          resolve_credential_provider(Keyword.fetch!(provider, :source))

        Keyword.has_key?(provider, :credential_provider) ->
          resolve_credential_provider(Keyword.fetch!(provider, :credential_provider))

        true ->
          {:error, {:unsupported_credential_provider, provider}}
      end
    end
  end

  defp resolve_credential_provider({mod, fun, args})
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    resolve_credential_provider(apply(mod, fun, args))
  end

  defp resolve_credential_provider(fun) when is_function(fun, 0) do
    resolve_credential_provider(fun.())
  end

  defp resolve_credential_provider(other) do
    {:error, {:unsupported_credential_provider, other}}
  end

  @doc """
  Attempts to claim a key in a bucket using a CAS (Compare-And-Swap) operation.
  Uses an if-match header to ensure the key doesn't exist when creating.

  Args:
    - req: A configured %ObjectStore{} client
    - key: The key to claim
    - body: The content to write if claim succeeds

  Returns:
    - {:ok, {:claimed, etag}} if successful
    - {:error, :already_claimed} if key exists
    - {:error, reason} for other failures
  """
  def try_claim(%__MODULE__{} = client, key, body) do
    req = new_req(client, consistent: true, headers: [{"if-none-match", "*"}])

    case Req.request(req,
           method: :put,
           url: key,
           body: body,
           retry: false
         ) do
      {:ok, %{status: status, headers: headers}}
      when status >= 200 and status < 300 ->
        {:ok, {:claimed, parse_etag!(headers)}}

      {:ok, %{status: 412}} ->
        # Precondition Failed - object exists (already claimed)
        {:error, :already_claimed}

      {:ok, response} ->
        # Other unexpected response
        {:error, response}

      {:error, exception} ->
        # Network or other errors
        {:error, exception}
    end
  end

  @doc """
  Gets an object from storage.

  ## Options
    `:consistent` - whether to make a consistent request to the default region. (Default `true`)

  ## Examples

      iex> get_object(ObjectStore.new(), "my-key")
      {:ok, %{body: "my-value", etag: "..."}

  Returns of a map of the form `%{body: body, etag: etag}` or `{:error, reason}`.
  """
  def get_object(%__MODULE__{} = client, key, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, [:consistent])
    consistent = Keyword.get(opts, :consistent, true)
    req = new_req(client, consistent: consistent)

    case Req.get(req, url: key) do
      {:ok, %{status: 200, body: body, headers: response_headers}} ->
        etag = parse_etag!(response_headers)
        {:ok, %{body: body, etag: etag}}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, response} ->
        Logger.error("Failed to get object: #{inspect(key: key, response: response)}")

        {:error, :bad_gateway}

      {:error, reason} ->
        Logger.error("Failed to get object: #{inspect(key: key, error: reason)}")
        {:error, reason}
    end
  end

  @doc """
  Lists objects in a bucket with optional prefix filtering.

  ## Options
    `:consistent` - whether to make a consistent request to the default region. (Default `true`)
  """
  def list_objects(%__MODULE__{} = client, prefix, opts \\ []) when is_list(opts) do
    opts = validate_opts!(opts)
    consistent = Keyword.get(opts, :consistent, true)
    req = new_req(client, consistent: consistent)
    max_results = Keyword.get(opts, :max_results, 1000)
    continuation_token = Keyword.get(opts, :continuation_token)

    params = %{
      "list-type" => "2",
      "prefix" => prefix,
      "max-keys" => max_results
    }

    params =
      if continuation_token do
        Map.put(params, "continuation-token", continuation_token)
      else
        params
      end

    case Req.get(req, url: "/", params: params, retry: :transient) do
      {:ok, %{status: 200, body: body}} ->
        parse_list_objects_response(body)

      {:ok, response} ->
        Logger.error("Failed to list objects: #{inspect(response: response)}")
        {:error, %{errors: ["list objects failed"]}}

      {:error, reason} ->
        Logger.error("Failed to list objects: #{inspect(error: reason)}")
        {:error, reason}
    end
  end

  @doc """
  Streams all object keys in a bucket with optional prefix filtering.

  *CAUTION*: use this with care as since this will stream over _every_ matching object
  in the bucket. While the stream will efficiently enumerable all objects without loading
  them all into memory at a time, it can still enumerate the entire object space on an
  eager match.

  Returns a Stream that automatically handles pagination using continuation tokens.
  This is memory-efficient for large buckets as it only loads one page at a time.

  ## Options

    * `:error_handler` - Function to handle errors. Receives error reason and should
      return `:halt` to stop the stream or `:continue` to skip the error.
      Defaults to raising the error.

  ## Examples

      # Stream all keys with prefix
      ObjectStore.list_all_objects_stream(store, "my-prefix/")
      |> Stream.take(100)
      |> Enum.map(fn %{key: key, etag: etag} = _obj -> ... end)

      # With custom error handling
      ObjectStore.list_all_objects_stream(store, "prefix/",
        error_handler: fn error_reason ->
          Logger.warning("List error: \#{inspect(error_reason)}")
          :continue
        end)

  """
  def list_all_objects_stream(%__MODULE__{} = client, prefix, opts \\ []) do
    {error_handler, list_opts} =
      Keyword.pop(opts, :error_handler, fn reason -> raise inspect(reason) end)

    Stream.unfold(nil, fn
      :done ->
        nil

      token ->
        # Merge continuation token with other options like max_results
        current_opts =
          if token, do: Keyword.put(list_opts, :continuation_token, token), else: list_opts

        case list_objects(client, prefix, current_opts) do
          {:ok, %{keys: keys, next_continuation_token: next_token}} when next_token != nil ->
            {keys, next_token}

          {:ok, %{keys: keys, next_continuation_token: nil}} ->
            {keys, :done}

          {:ok, %{keys: keys}} ->
            {keys, :done}

          {:error, reason} ->
            case error_handler.(reason) do
              :halt -> nil
              :continue -> {[], :done}
              _ -> nil
            end
        end
    end)
    |> Stream.flat_map(& &1)
  end

  @doc """
  Puts an object to S3.

  ## Options
  - `:max_retries` - The maximum number of times to retry put. Default 0.
  - `:etag` - The existing etag to match. Conflicts return `{:error, :conflict}`
  - `:timeout` - Total time in ms for the operation including retries. If exceeded,
    no further retries will be attempted. Default: no timeout (unlimited retries until max_retries).
  """
  def put_object(%__MODULE__{} = client, key, data, opts \\ []) do
    opts = validate_opts!(opts)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    consistent = Keyword.get(opts, :consistent, true)
    timeout = Keyword.get(opts, :timeout)

    # Handle :infinity and nil as no deadline
    deadline_at =
      case timeout do
        nil -> nil
        :infinity -> nil
        ms when is_integer(ms) -> System.system_time(:millisecond) + ms
      end

    # Add If-Match header for etag verification
    base_headers = [
      {"content-type", content_type}
    ]

    headers =
      case Keyword.fetch(opts, :etag) do
        {:ok, etag} when is_binary(etag) ->
          [{"if-match", etag} | base_headers]

        {:ok, invalid} ->
          raise ArgumentError, "excepted etag to be a string, got: #{inspect(invalid)}"

        :error ->
          base_headers
      end

    req = new_req(client, consistent: consistent, headers: headers)

    req_with_retries =
      case Keyword.fetch(opts, :max_retries) do
        {:ok, retries} when is_integer(retries) and retries >= 0 ->
          Req.merge(req,
            max_retries: retries,
            retry: fn
              # don't retry good response, conflict, or not found
              # 404 on PUT with if-match means object doesn't exist (localstack behavior)
              %Req.Request{}, %Req.Response{status: status}
              when status in 200..299 or status in [404, 409, 412] ->
                false

              # check deadline before retrying transient errors
              %Req.Request{}, _exception ->
                if deadline_at && System.system_time(:millisecond) >= deadline_at do
                  false
                else
                  true
                end
            end
          )

        :error ->
          req
      end

    case Req.put(req_with_retries, url: key, body: data) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        etag = parse_etag!(response.headers)
        {:ok, %{etag: etag, body: data}}

      {:ok, %{status: status}} when status in [409, 412] ->
        # Precondition Failed - etag mismatch
        {:error, :conflict}

      {:ok, response} ->
        Logger.error("Failed to put object with etag: #{inspect(key: key, response: response)}")
        {:error, response}

      {:error, reason} ->
        Logger.error("Failed to put object with etag: #{inspect(key: key, error: reason)}")
        {:error, reason}
    end
  end

  defp parse_etag!(%{} = headers_or_attrs) do
    case headers_or_attrs["etag"] || headers_or_attrs["ETag"] do
      [etag_value] when is_binary(etag_value) -> String.replace(etag_value, "\"", "")
      etag_value when is_binary(etag_value) -> String.replace(etag_value, "\"", "")
      nil -> raise "ETag not found in response: #{inspect(headers_or_attrs)}"
      other -> raise "Unexpected ETag format: #{inspect(other)}"
    end
  end

  defp validate_opts!(opts) do
    Keyword.validate!(opts, [
      :content_type,
      :consistent,
      :headers,
      :backoff_fun,
      :timeout,
      :task_supervisor,
      :max_retries,
      :max_results,
      :continuation_token,
      :prefix,
      :etag
    ])
  end

  @doc """
  Deletes an object from S3.
  """
  def delete_object(%__MODULE__{} = client, key) do
    req = new_req(client, consistent: true)

    case Req.request(req,
           method: :delete,
           url: key,
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 412}} ->
        {:error, :not_found}

      {:ok, response} ->
        Logger.error("Failed to delete object: #{inspect(key: key, response: response)}")

        {:error, %{errors: ["delete object failed"]}}

      {:error, reason} ->
        Logger.error("Failed to delete object: #{inspect(key: key, error: reason)}")
        {:error, reason}
    end
  end

  @doc """
  Copies an object within S3 (used for moving to trash).
  """
  def copy_object(%__MODULE__{} = client, source_bucket, source_key, dest_bucket, dest_key) do
    copy_source = "/#{source_bucket}/#{source_key}"

    headers = [
      {"x-amz-copy-source", copy_source}
    ]

    req = new_req(client, consistent: true, headers: headers)

    case Req.put(req, url: "/#{dest_bucket}/#{dest_key}") do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, response} ->
        Logger.error(
          "Failed to copy object: #{inspect(source: "#{source_bucket}/#{source_key}",
          dest: "#{dest_bucket}/#{dest_key}",
          response: response)}"
        )

        {:error, %{errors: ["copy object failed"]}}

      {:error, reason} ->
        Logger.error(
          "Failed to copy object: #{inspect(source: "#{source_bucket}/#{source_key}",
          dest: "#{dest_bucket}/#{dest_key}",
          error: reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Atomically updates an object using etag-based conflict resolution.

  Uses a read-modify-write pattern with etag verification to avoid conflicts.
  If a conflict is detected, it will retry up to the specified maximum retries.

  - `key` – The object key to update
  - `update_fn` - Function that takes current data and returns {:ok, new_data} or {:error, reason}
    - To proceed with write, return `{:ok, new_data}`
    - To abort write, return `{:error, reason}`

  ## Options
  - `:timeout` - Operation timeout (default: :infinity)
  - `:max_retries` - Maximum number of retry attempts (default: 5)
  - `:consistent` - Use consistent reads (default: true)
  - `:content_type` - Content type for the object (default: "application/octet-stream")
  - `:task_supervisor` - Task supervisor for async operations (default: uses client.task_supervisor)

  ## Returns:
  - {:ok, %{etag: etag, body: body}} on successful update
  - {:error, :not_found} if the key doesn't exist
  - {:error, :max_retries_exceeded} if retries are exhausted
  - {:error, reason} for other failures

  ## Examples

      store = ObjectStore.new()
      ObjectStore.update_object(store, "my-key", fn %{body: current_data, etag: current_etag} ->
        updated = current_data <> " - updated"
        {:ok, updated}
      end, timeout: :infinity, max_retries: 5)
  """
  def update_object(%__MODULE__{} = client, key, update_fn, opts \\ [])
      when is_function(update_fn, 1) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    max_retries = Keyword.get(opts, :max_retries, 5)
    task_sup = Keyword.get(opts, :task_supervisor, client.task_supervisor)

    if timeout == :infinity do
      do_update_object(client, key, update_fn, opts, 0, max_retries)
    else
      task =
        Task.Supervisor.async(task_sup, fn ->
          do_update_object(client, key, update_fn, opts, 0, max_retries)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end
    end
  end

  defp do_update_object(%__MODULE__{} = client, key, update_fn, opts, attempt, max_retries) do
    if attempt > max_retries do
      {:error, :max_retries_exceeded}
    else
      case get_object(client, key, consistent: true) do
        {:ok, %{body: current_data, etag: current_etag}} ->
          case update_fn.(%{body: current_data, etag: current_etag}) do
            {:ok, new_data} ->
              case put_object(client, key, new_data, Keyword.put(opts, :etag, current_etag)) do
                {:ok, result} ->
                  {:ok, result}

                {:error, :conflict} ->
                  # ETag mismatch, retry with exponential backoff
                  Process.sleep(round(min(100 * :math.pow(2, attempt), 1000)))
                  do_update_object(client, key, update_fn, opts, attempt + 1, max_retries)

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_list_objects_response(response_map) do
    # Navigate to the ListBucketResult in the map
    bucket_result = response_map["ListBucketResult"] || %{}

    # Extract keys from Contents
    # Contents can be a single map or a list of maps
    contents = bucket_result["Contents"] || []
    contents_list = if is_list(contents), do: contents, else: [contents]

    keys =
      contents_list
      |> Enum.map(fn content ->
        case content do
          %{"Key" => key} = item ->
            # Include LastModified if present
            base = %{key: key, etag: parse_etag!(item), size: item["Size"]}

            case Map.get(item, "LastModified") do
              nil -> base
              last_modified -> Map.put(base, :last_modified, last_modified)
            end

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Extract next continuation token
    next_token = bucket_result["NextContinuationToken"]

    # Check if response is truncated
    is_truncated =
      case bucket_result["IsTruncated"] do
        "true" -> true
        true -> true
        _ -> false
      end

    result = %{
      keys: keys,
      is_truncated: is_truncated,
      next_continuation_token: next_token
    }

    {:ok, result}
  end

  defp parse_list_buckets_response(response_map) do
    # Navigate to the ListAllMyBucketsResult in the map
    buckets_result = response_map["ListAllMyBucketsResult"] || %{}

    # The "Buckets" section contains a "Bucket" key with the actual list
    buckets_section = buckets_result["Buckets"] || %{}

    # Extract buckets list - it's directly under "Bucket" key
    bucket_list =
      case buckets_section do
        %{"Bucket" => bucket_data} when is_list(bucket_data) -> bucket_data
        %{"Bucket" => bucket_data} when is_map(bucket_data) -> [bucket_data]
        # Fallback if structure is different
        bucket_data when is_list(bucket_data) -> bucket_data
        _ -> []
      end

    buckets =
      bucket_list
      |> Enum.map(fn bucket ->
        case bucket do
          %{"Name" => name, "CreationDate" => creation_date} ->
            %{name: name, creation_date: creation_date}

          %{"Name" => name} ->
            %{name: name, creation_date: nil}

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    buckets
  end
end
