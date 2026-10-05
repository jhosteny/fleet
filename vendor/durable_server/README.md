# DurableServer

DurableServer provides durable, distributed GenServer processes backed by pluggable storage backends.

It implements fault-tolerant, stateful processes that can survive node failures, restarts, and deployments by automatically persisting state and coordinating across a distributed cluster.

## Key Features

- **Durable state**: Automatically persists state to storage with configurable sync intervals
- **Cluster coordination**: Uses distributed registry for process discovery and health monitoring
- **Capacity-aware placement**: Monitors CPU, memory, and disk usage to route new processes to nodes with available capacity
- **Sticky placement**: Environment variable-based placement preferences (e.g., same machine, same region, etc.) with time-gated fallback to ensure servers restart on preferred nodes when possible
- **Automatic recovery**: Failed processes are detected and restarted across the cluster
- **Graceful shutdown**: Ensures state is synchronized before termination
- **Lifecycle monitoring & dispatch**: Monitor lifecycle events and dispatch messages between DurableServers and other processes
- **Pluggable backends**: Run with object storage, EKV, or a dual-backend migration adapter

## Installation

Add `durable_server` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:durable_server, "~> 0.1.0"}
  ]
end
```

For releases, add `:os_mon` to `extra_applications`:

```elixir
def application do
  [
    mod: {MyApp.Application, []},
    extra_applications: [:logger, :runtime_tools, :os_mon]
  ]
end
```

## Basic Usage

```elixir
defmodule MyCounterServer do
  use DurableServer, vsn: 1

  def dump_state(state), do: %{count: state.count}

  def load_state(_old_vsn, %{"count" => count}), do: %{count: count}

  def init(%{count: count} = state) do
    {:ok, Map.merge(state, %{started_at: DateTime.utc_now()})}
  end

  def handle_call(:increment, _from, state) do
    new_state = %{state | count: state.count + 1}
    {:reply, new_state.count, new_state}
  end

  def handle_call(:get_count, _from, state) do
    {:reply, state.count, state}
  end
end
```

Start the supervisor (typically in your application supervision tree):

```elixir
children = [
  {DurableServer.Supervisor,
   name: MyDurableSup,
   prefix: "my_app/",
   object_store: [
     bucket: "my-bucket",
     access_key_id: System.fetch_env!("OBJECT_STORE_ACCESS_KEY_ID"),
     secret_access_key: System.fetch_env!("OBJECT_STORE_SECRET_ACCESS_KEY"),
     s3_endpoint: System.fetch_env!("OBJECT_STORE_S3_ENDPOINT_URL"),
     default_region: System.fetch_env!("OBJECT_STORE_REGION")
   ]}
]
```

Start and use individual servers:

```elixir
{:ok, {pid, _meta}} = DurableServer.Supervisor.start_child(
  MyDurableSup,
  {MyCounterServer, key: "user_123", initial_state: %{count: 0}}
)

GenServer.call(pid, :increment)  # => 1
GenServer.call(pid, :increment)  # => 2
GenServer.call(pid, :get_count)  # => 2
```

`:initial_state` is required and must be a map. On first boot, DurableServer
passes it through `dump_state/1`, the configured backend's encode/decode path,
and then `load_state/2` before `init/1` or `init/2`. The dumped initial state
must therefore be encodable by your configured backend.

## Storage Backends

`DurableServer` includes two built-in backends:

### Object Storage Backend

Use this with any S3-compatible object store.

```elixir
{DurableServer.Supervisor,
 name: MyDurableSup,
 prefix: "my_app/",
 backend: {DurableServer.Backends.ObjectStore,
  [
    bucket: "my-bucket",
    access_key_id: "...",
    secret_access_key: "...",
    s3_endpoint: "https://example-s3-endpoint",
    default_region: "us-east-1"
  ]}}
```

### Tigris Bootstrap

If you use Tigris, construct a separate `DurableServer.ObjectStore.Tigris`
wrapper around your generic object-store client:

```elixir
object_store = DurableServer.ObjectStore.new([
  bucket: "my-bucket",
  access_key_id: "...",
  secret_access_key: "...",
  s3_endpoint: "https://t3.storage.dev",
  default_region: "iad"
])

tigris = DurableServer.ObjectStore.Tigris.new(object_store,
  iam_endpoint: "https://iam.storage.dev"
)
```

That wrapper provides bucket creation, bucket-scoped credential generation, and
force-delete cleanup through the IAM API. It is useful for provisioning, but it
is not required for ordinary S3-compatible usage.

### Credential Providers

If you want to avoid hardcoding static keys, pass a `credential_provider`
instead of `access_key_id` / `secret_access_key`.

The object store accepts any provider that resolves to a map with
`access_key_id`, `secret_access_key`, and optional `token`. Supported provider
shapes include:

- a keyword list or map containing those keys
- a 0-arity function that returns one of the supported shapes
- an MFA tuple like `{Mod, :fun, [args]}`
- a provider struct with `fetch!/1` or `fetch/1`

That means an app-level `aws_credentials` dependency can stay optional: if it
returns a compatible credential map, you can hand its provider object directly
to `credential_provider:`.

```elixir
object_store =
  DurableServer.ObjectStore.new([
    bucket: "my-bucket",
    credential_provider: MyApp.AwsCredentialsProvider.new(...),
    s3_endpoint: "https://example-s3-endpoint",
    default_region: "us-east-1"
  ])
```

For the simple case, static credentials still work without any extra library:

```elixir
object_store =
  DurableServer.ObjectStore.new([
    bucket: "my-bucket",
    access_key_id: System.fetch_env!("OBJECT_STORE_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("OBJECT_STORE_SECRET_ACCESS_KEY"),
    s3_endpoint: System.fetch_env!("OBJECT_STORE_S3_ENDPOINT_URL"),
    default_region: System.fetch_env!("OBJECT_STORE_REGION")
  ])
```

### EKV Backend

Start EKV in your application tree (CAS config is required for DurableServer lock semantics):

```elixir
ekv_config = [
  name: :durable_ekv,
  data_dir: "/path/to/ekv_store",
  cluster_size: 3
]

children = [
  {EKV,
   name: :durable_ekv,
   data_dir: "/data/ekv/durable",
   cluster_size: 3,
   node_id: System.fetch_env!("EKV_NODE_ID")},
  {DurableServer.Supervisor,
   name: MyDurableSup,
   prefix: "my_app/",
   backend: {DurableServer.Backends.EKVStore, ekv_config}}
]
```

If you use EKV backend, add EKV to your app's dependencies.

### Mirror Backend (Object Storage -> EKV)

Use the mirror backend to dual-write while you cut over reads/writes in phases.

See `DurableServer.Backends.MirrorStore` for usage and an example rollout.

## Configuration Options

DurableServer supports these options in the `init/1` return tuple:

- `:auto_sync` - Enable automatic periodic syncing (default: false)
- `:sync_every_ms` - Sync interval in milliseconds (default: 30_000)
- `:meta` - Optional metadata included in the global registry

## State Synchronization

State is synchronized to storage in these scenarios:

1. **Manual sync**: Return `:sync` from any callback: `{:noreply, state, :sync}`
2. **Automatic sync**: When `:auto_sync` is enabled, changes sync on the `:sync_every_ms` interval
3. **Graceful shutdown**: State is always synced before termination

## Group

`Group` provides distributed process groups, registry, lifecycle monitoring, and isolated subclusters.

### Monitoring Events

Monitor lifecycle events for DurableServers:

```elixir
# Monitor a specific key
:ok = Group.monitor(MyDurableSup, "user/123")

# Monitor all keys with a prefix
:ok = Group.monitor(MyDurableSup, "user/")

# Monitor all events
:ok = Group.monitor(MyDurableSup, :all)
```

Monitors receive `{:group, events, info}` tuples in their mailbox:

```elixir
def handle_info({:group, events, _info}, state) do
  Enum.each(events, fn
    %Group.Event{type: :registered, key: key, pid: pid, previous_meta: nil} ->
      # A DurableServer started (previous_meta is nil for first registration)
      :ok
    %Group.Event{type: :unregistered, key: key, reason: reason} ->
      # A DurableServer stopped
      :ok
    _ -> :ok
  end)
  {:noreply, state}
end
```

Event types: `:registered`, `:unregistered`, `:joined`, `:left`

`:registered` and `:joined` events include a `previous_meta` field (`nil` for new, old meta for re-register/re-join). Single operations produce one event per tuple; bulk operations (nodedown, process death) batch all events together.

### Joining as a Member

Non-DurableServer processes can join keys to be discoverable and receive dispatched messages:

```elixir
# Join a key (e.g., from a Phoenix Channel)
:ok = Group.join(MyDurableSup, "room/123", %{type: :channel})

# Re-joining updates metadata in place
:ok = Group.join(MyDurableSup, "room/123", %{type: :channel, status: :active})

# Query all members of a key (DurableServers + joined processes)
members = Group.members(MyDurableSup, "room/123")
# => [{#PID<0.150.0>, %{...}}, {#PID<0.200.0>, %{type: :channel, status: :active}}]

# Leave when done (also happens automatically on process death)
:ok = Group.leave(MyDurableSup, "room/123")
```

### Dispatching to Members

Send messages to all members of a key:

```elixir
# From a DurableServer, broadcast to all connected channels
Group.dispatch(MyDurableSup, state.key, {:new_message, message})
```

### Named Clusters

For advanced use cases, you can create isolated subclusters where only connected nodes receive events:

```elixir
# Connect this node to a named cluster
:ok = Group.connect(MyDurableSup, :game_servers)

# Join/monitor/dispatch with the cluster: option
:ok = Group.join(MyDurableSup, "room/123", %{}, cluster: :game_servers)
:ok = Group.monitor(MyDurableSup, :all, cluster: :game_servers)
```

Note: DurableServers always register in the default cluster to ensure global uniqueness. Named clusters are purely for the pub/sub layer.

### Monitor vs Join

- **`monitor/2`**: Receive lifecycle events (`:registered`, `:unregistered`, `:joined`, `:left`) - system-generated
- **`join/3`**: Be discoverable via `members/2` and receive `dispatch/3` messages - application-level

These are independent - joining does not monitor events, and monitoring does not make you discoverable.

## Running Tests

### Unit Tests (with LocalStack)

Start LocalStack for S3-compatible storage:

```bash
docker run -d --name localstack -p 4566:4566 localstack/localstack
```

Run the tests:

```bash
mix test
```

### Integration Tests (with Tigris)

Set the required environment variables for the Tigris integration path:
> *Note*: You can add these to a gitignored .env in this project and they will be loaded
automatically in `test_helper.exs`

```bash
export DURABLE_AWS_ACCESS_KEY_ID=<your-tigris-access-key>
export DURABLE_AWS_SECRET_ACCESS_KEY=<your-tigris-secret-key>
export DURABLE_AWS_ENDPOINT_URL_S3=https://t3.storage.dev
export DURABLE_AWS_ENDPOINT_URL_IAM=https://iam.storage.dev
export DURABLE_AWS_REGION=<your-region>
export DURABLE_BUCKET=<your-bucket-name>
```

Run integration tests (which hit Tigris directly):

```bash
mix test --include integration
```
