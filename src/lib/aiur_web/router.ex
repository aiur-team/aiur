defmodule AiurWeb.Router do
  @moduledoc """
  Router for Aiur's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :dashboard_auth do
    plug(:dashboard_basic_auth)
  end

  pipeline :dashboard_auth_required do
    plug(:dashboard_basic_auth, required?: true)
  end

  pipeline :supervisor_auth do
    plug(AiurWeb.SupervisorAuth)
  end

  # GitHub webhook deliveries carry no bearer token and no browser session:
  # they authenticate by HMAC signature over the raw body, so they need their
  # own pipeline rather than the dashboard or supervisor auth pipelines.
  pipeline :github_webhook do
    plug(AiurWeb.GithubWebhook.Auth)
  end

  pipeline :browser do
    plug(:fetch_session)
    plug(AiurWeb.FinancialDataAccess, :persist_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AiurWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :secure_document do
    plug(:put_secure_browser_headers)
  end

  # CSRF defense for the bare REST JSON write endpoints. `Plug.CSRFProtection`
  # is the wrong tool here — it depends on a session-stored token, and the
  # API isn't driven by our own LiveView (curl + 3rd-party scripts are
  # legitimate callers as long as they come from the Executor’s machine).
  # Defense: Origin/Referer must match the dashboard's own origin (or
  # loopback equivalents), AND a custom `X-Aiur-Request: 1` header must
  # be present (browsers attaching this header on a same-origin XHR is
  # straightforward; cross-origin attackers can't set custom headers
  # without CORS preflight succeeding, and we never enable CORS).
  pipeline :api_write do
    plug(:verify_same_origin)
    plug(:require_custom_header)
  end

  # Read-only gate for the dashboard's agent-write endpoints (Executor chat,
  # refresh). Disabled by default until a deliberate dashboard parity pass —
  # see issue #371. Re-enable via `observability.dashboard_writable` config.
  # The TUI's pane endpoints and the RC claude-hook are intentionally NOT
  # behind this gate (see the route scopes below).
  pipeline :require_writable do
    plug(:require_dashboard_writable)
  end

  # Keep the webhook receiver ahead of every other scope: the dashboard's
  # trailing `/*path` catch-all would otherwise claim this path and answer with
  # a Basic-Auth challenge instead of a signature check. The literal path is
  # asserted against `AiurWeb.GithubWebhook.path/0` in the router tests, since
  # the endpoint's body reader keys raw-body caching off that same value.
  scope "/", AiurWeb do
    pipe_through(:github_webhook)

    # `log: false` suppresses Phoenix's default dispatch log, which would
    # otherwise write the entire decoded webhook payload into the debug log.
    post("/api/v1/github/webhook", GithubWebhookController, :create, log: false)
  end

  # Supervisor Decision mutations retain the dashboard's existing write
  # defenses in addition to their dedicated machine credential. Keep these
  # specific routes before `/api/v1/:issue_identifier` so `decisions` cannot
  # be interpreted as an issue identifier.
  scope "/", AiurWeb do
    pipe_through([:supervisor_auth, :api_write, :require_writable])

    post("/api/v1/decisions/:decision_id/enrich", DecisionApiController, :enrich)
    post("/api/v1/decisions/:decision_id/decide", DecisionApiController, :decide)
    post("/api/v1/decisions/:decision_id/revise", DecisionApiController, :revise)
  end

  # Read operations require the same supervisor identity but remain available
  # while the dashboard is observe-only and need no browser mutation headers.
  scope "/", AiurWeb do
    pipe_through(:supervisor_auth)

    get("/api/v1/decisions", DecisionApiController, :index)
    get("/api/v1/decisions/:decision_id", DecisionApiController, :show)
  end

  # Authenticated method/shape catches keep unsupported Decision requests from
  # falling through into the dashboard Basic-Auth issue API.
  scope "/", AiurWeb do
    pipe_through(:supervisor_auth)

    match(:*, "/api/v1/decisions", DecisionApiController, :method_not_allowed)
    match(:*, "/api/v1/decisions/:decision_id/enrich", DecisionApiController, :method_not_allowed)
    match(:*, "/api/v1/decisions/:decision_id/decide", DecisionApiController, :method_not_allowed)
    match(:*, "/api/v1/decisions/:decision_id/revise", DecisionApiController, :method_not_allowed)
    match(:*, "/api/v1/decisions/:decision_id", DecisionApiController, :method_not_allowed)
    match(:*, "/api/v1/decisions/:decision_id/*path", DecisionApiController, :not_found)
  end

  scope "/", AiurWeb do
    pipe_through(:dashboard_auth)

    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/ticket-context-dialog-hook.js", StaticAssetController, :ticket_context_dialog_hook)
    get("/build-order-grid-hook.js", StaticAssetController, :build_order_grid_hook)
    get("/time-brush-hook.js", StaticAssetController, :time_brush_hook)
    get("/streamdeck-emulator-hook.js", StaticAssetController, :streamdeck_emulator_hook)
    get("/aiur-dom-svg-layout-adapter.js", StaticAssetController, :dom_svg_layout_adapter)
    get("/aiur-dom-svg-layout-loader.js", StaticAssetController, :dom_svg_layout_loader)
    get("/aiur-dom-svg-layout/:module", StaticAssetController, :dom_svg_layout_module)
    get("/aiur-logo.png", StaticAssetController, :aiur_logo)
    get("/bungee.woff2", StaticAssetController, :bungee_font)
    get("/provider-assets/*provider_asset", StaticAssetController, :provider_asset)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
    get("/vendor/layout/:version/:digest/:asset", StaticAssetController, :layout_asset)
  end

  scope "/", AiurWeb do
    pipe_through([:dashboard_auth, :browser])

    live_session :dashboard, on_mount: AiurWeb.FinancialDataAccess do
      live("/", DashboardLive, :index)
      live("/decisions", DashboardLive, :decisions)
      live("/decisions/:decision_id", DashboardLive, :decision)
      live("/build-orders", BuildOrderLive, :build_orders)
      live("/build-orders/:root_number", BuildOrderLive, :build_order)
      live("/analytics", AnalyticsLive, :analytics)
      live("/streamdeck", StreamdeckLive, :streamdeck)
    end
  end

  # Agent-write endpoints driven from the browser/API. Gated read-only by
  # default (`:require_writable`) until the dashboard parity pass.
  scope "/", AiurWeb do
    pipe_through([:dashboard_auth, :api_write, :require_writable])

    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/:issue_identifier/messages", ObservabilityApiController, :send_message)
    match(:*, "/api/v1/:issue_identifier/messages", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/:issue_identifier/pause", ObservabilityApiController, :pause)
    match(:*, "/api/v1/:issue_identifier/pause", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/:issue_identifier/resume", ObservabilityApiController, :resume)
    match(:*, "/api/v1/:issue_identifier/resume", ObservabilityApiController, :method_not_allowed)
  end

  # Machine-to-machine write surfaces that are NOT browser-facing and must keep
  # working in read-only mode: the TUI's tmux pane key bindings (interrupt/hide,
  # see aiur.tmux.conf) and the RC claude lifecycle-hook sink (#367).
  scope "/", AiurWeb do
    pipe_through([:dashboard_auth, :api_write])

    post("/api/v1/pane/interrupt", ObservabilityApiController, :pane_interrupt)
    match(:*, "/api/v1/pane/interrupt", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/pane/hide", ObservabilityApiController, :pane_hide)
    match(:*, "/api/v1/pane/hide", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/:issue_identifier/claude-hook", ObservabilityApiController, :claude_hook)
    match(:*, "/api/v1/:issue_identifier/claude-hook", ObservabilityApiController, :method_not_allowed)
  end

  scope "/", AiurWeb do
    pipe_through(:dashboard_auth_required)

    post("/api/v1/streamdeck/token", StreamdeckSessionController, :create)
  end

  scope "/", AiurWeb do
    pipe_through(:dashboard_auth)

    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/streamdeck/grid", ObservabilityApiController, :streamdeck_grid)
    get("/api/v1/:issue_identifier/events", ObservabilityApiController, :events)
    match(:*, "/api/v1/:issue_identifier/events", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/streamdeck/grid", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end

  @doc false
  @spec dashboard_basic_auth(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def dashboard_basic_auth(conn, opts), do: AiurWeb.FinancialDataAccess.authenticate_request(conn, opts)

  # Origin/Referer allowlist. Parses exact origins and accepts the configured
  # dashboard host or loopback equivalents Executors typically use.
  defp verify_same_origin(conn, _opts) do
    if origin_allowed?(conn) do
      conn
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(403, ~s({"error":"origin not allowed"}))
      |> Plug.Conn.halt()
    end
  end

  # Rejects agent-write requests while the dashboard is read-only. Sources the
  # flag from the endpoint config (set by `Aiur.HttpServer`, overridable in
  # tests) and fails closed: a missing/false value keeps the dashboard
  # observe-only.
  defp require_dashboard_writable(conn, _opts) do
    if dashboard_writable?() do
      conn
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(403, ~s({"error":"dashboard is read-only"}))
      |> Plug.Conn.halt()
    end
  end

  defp dashboard_writable? do
    AiurWeb.Endpoint.config(:dashboard_writable) == true
  rescue
    _ -> false
  end

  defp require_custom_header(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "x-aiur-request") do
      ["1"] ->
        conn

      _ ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, ~s({"error":"missing X-Aiur-Request header"}))
        |> Plug.Conn.halt()
    end
  end

  defp origin_allowed?(conn) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [origin] ->
        origin_matches_allowlist?(origin, conn, false)

      [] ->
        case Plug.Conn.get_req_header(conn, "referer") do
          [referer] -> origin_matches_allowlist?(referer, conn, true)
          [] -> false
          _ambiguous -> false
        end

      _ambiguous ->
        false
    end
  end

  defp origin_matches_allowlist?(value, conn, allow_path?) when is_binary(value) do
    case parse_web_origin(value, allow_path?) do
      {:ok, origin} -> origin in allowed_origins(conn)
      :error -> false
    end
  end

  defp allowed_origins(conn) do
    endpoint_origin = safe_endpoint_origin()

    [trusted_request_origin(conn, endpoint_origin), endpoint_origin, {"http", "localhost", 80}, {"https", "localhost", 443}]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&expand_loopback_aliases/1)
    |> Enum.uniq()
  end

  defp trusted_request_origin(conn, endpoint_origin) do
    case request_origin(conn) do
      {_scheme, host, _port} = origin ->
        if loopback_host?(host) or same_endpoint_host?(origin, endpoint_origin), do: origin

      nil ->
        nil
    end
  end

  defp same_endpoint_host?({scheme, host, _port}, {scheme, host, _endpoint_port}), do: true
  defp same_endpoint_host?(_request_origin, _endpoint_origin), do: false

  defp request_origin(%Plug.Conn{scheme: scheme, host: host, port: port})
       when scheme in [:http, :https] and is_binary(host) and is_integer(port) do
    {Atom.to_string(scheme), String.downcase(host), port}
  end

  defp request_origin(_conn), do: nil

  defp safe_endpoint_origin do
    AiurWeb.Endpoint.url()
    |> parse_web_origin(false)
    |> case do
      {:ok, origin} -> origin
      :error -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_web_origin(value, allow_path?) do
    uri = URI.parse(value)

    with scheme when scheme in ["http", "https"] <- normalize_scheme(uri.scheme),
         host when is_binary(host) and host != "" <- normalize_host(uri.host),
         true <- is_nil(uri.userinfo),
         true <- allow_path? or uri.path in [nil, ""],
         true <- allow_path? or is_nil(uri.query),
         true <- is_nil(uri.fragment),
         port when is_integer(port) and port in 1..65_535 <- effective_port(uri, scheme) do
      {:ok, {scheme, host, port}}
    else
      _invalid -> :error
    end
  rescue
    _invalid -> :error
  end

  defp normalize_scheme(scheme) when is_binary(scheme), do: String.downcase(scheme)
  defp normalize_scheme(_scheme), do: nil

  defp normalize_host(host) when is_binary(host), do: String.downcase(host)
  defp normalize_host(_host), do: nil

  defp effective_port(%URI{port: port}, _scheme) when is_integer(port), do: port
  defp effective_port(%URI{}, "http"), do: 80
  defp effective_port(%URI{}, "https"), do: 443

  defp expand_loopback_aliases({scheme, host, port} = origin) do
    if loopback_host?(host) do
      Enum.map(["localhost", "127.0.0.1", "::1"], &{scheme, &1, port})
    else
      [origin]
    end
  end

  defp loopback_host?(host), do: host in ["localhost", "127.0.0.1", "::1"]
end
