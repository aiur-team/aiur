defmodule AiurWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint for Aiur's optional observability UI and API.
  """

  use Phoenix.Endpoint, otp_app: :aiur

  @session_options [
    store: :cookie,
    key: "_aiur_key",
    signing_salt: "aiur-session"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  socket("/streamdeck", AiurWeb.StreamdeckSocket,
    websocket: true,
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: :aiur,
    gzip: false,
    only: AiurWeb.StaticAssets.revalidated_static_paths(),
    cache_control_for_etags: "private, max-age=0, must-revalidate",
    cache_control_for_vsn_requests: "private, max-age=0, must-revalidate"
  )

  plug(Plug.Static,
    at: "/",
    from: :aiur,
    gzip: false,
    only: AiurWeb.StaticAssets.long_lived_static_paths(),
    cache_control_for_etags: "public, max-age=31536000",
    cache_control_for_vsn_requests: "public, max-age=31536000"
  )

  plug(Plug.Static,
    at: "/provider-assets",
    from: :aiur,
    gzip: false,
    only: AiurWeb.StaticAssets.provider_asset_paths(),
    cache_control_for_etags: "private, max-age=0, must-revalidate",
    cache_control_for_vsn_requests: "private, max-age=0, must-revalidate"
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
  plug(AiurWeb.Router)
end
