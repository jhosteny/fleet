defmodule FleetWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :fleet

  @session_options [
    store: :cookie,
    key: "_fleet_demo",
    signing_salt: "fleet-session",
    same_site: "Lax"
  ]
  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])
  plug(Plug.Static, at: "/", from: :fleet, only: ~w(assets favicon.svg))
  plug(Plug.Static, at: "/vendor/phoenix", from: {:phoenix, "priv/static"}, only: ~w(phoenix.mjs))

  plug(Plug.Static,
    at: "/vendor/liveview",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.esm.js)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(FleetWeb.Router)
end
