import Config

config :fleet,
  start_cluster: config_env() != :test,
  robot_count: 300,
  data_dir:
    if(config_env() == :test,
      do: Path.join(System.tmp_dir!(), "fleet-test-#{System.pid()}"),
      else: Path.expand("../data", __DIR__)
    )

config :fleet, FleetWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: FleetWeb.ErrorHTML, json: FleetWeb.ErrorJSON], layout: false],
  secret_key_base: "fleet-demo-local-only-secret-" <> String.duplicate("0123456789", 8),
  live_view: [signing_salt: "fleet-live"],
  pubsub_server: Fleet.PubSub,
  server: config_env() != :test,
  check_origin: ["//localhost:4000", "//127.0.0.1:4000"]

config :phoenix, :json_library, Jason
config :logger, level: :warning
