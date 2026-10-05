defmodule Fleet.Application do
  use Application

  def start(_type, _args) do
    worker? = Application.get_env(:fleet, :worker, false)

    children =
      if worker? do
        [Fleet.Worker]
      else
        [
          {Phoenix.PubSub, name: Fleet.PubSub},
          {Task.Supervisor, name: Fleet.Tasks},
          Fleet.Store,
          Fleet.Telemetry,
          Fleet.Cluster,
          FleetWeb.Endpoint
        ]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Fleet.Supervisor)
  end

  def config_change(changed, _new, removed), do: FleetWeb.Endpoint.config_change(changed, removed)
end
