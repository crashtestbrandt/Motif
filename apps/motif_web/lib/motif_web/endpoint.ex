defmodule MotifWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :motif_web

  @session_options [
    store: :cookie,
    key: "_motif_web_key",
    signing_salt: "motif-web-session-salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  # Serve the LiveView and Phoenix JS shipped inside their packages, so we
  # don't need an asset pipeline for the prototype.
  plug Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false,
    only: ~w(phoenix.min.js phoenix.js)

  plug Plug.Static,
    at: "/assets/live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false,
    only: ~w(phoenix_live_view.min.js phoenix_live_view.js)

  plug Plug.Static,
    at: "/",
    from: :motif_web,
    gzip: false,
    only: ~w(favicon.ico robots.txt)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug MotifWeb.Router
end
