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
    websocket: [connect_info: [:user_agent, session: @session_options]],
    longpoll: false
  )

  socket("/streamdeck", AiurWeb.StreamdeckSocket,
    websocket: true,
    longpoll: false
  )

  # Dashboard dictation audio. The browser streams PCM here and the server owns
  # the ElevenLabs STT session; auth reuses the LiveView session proof.
  socket("/voice", AiurWeb.VoiceSocket,
    websocket: [connect_info: [session: @session_options], max_frame_size: 400_000],
    longpoll: false
  )

  plug(:authenticate_static_asset)

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

  # The custom body reader caches the raw request bytes for GitHub webhook
  # deliveries. HMAC is computed over exactly what GitHub sent, and re-encoding
  # the parsed map would produce different bytes and a signature that never
  # matches. Every other path keeps the stock reader and the default limit.
  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    body_reader: {AiurWeb.GithubWebhook.BodyReader, :read_body, []},
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(AiurWeb.Router)

  @doc false
  @spec authenticate_static_asset(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def authenticate_static_asset(conn, opts) do
    if AiurWeb.StaticAssets.served_path?(conn.path_info),
      do: AiurWeb.FinancialDataAccess.authenticate_request(conn, opts),
      else: conn
  end
end
