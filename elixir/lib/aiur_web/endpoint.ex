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
