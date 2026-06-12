defmodule AiurWeb.Router do
  @moduledoc """
  Router for Aiur's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :dashboard_auth do
    plug(:dashboard_basic_auth)
  end

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AiurWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # CSRF defense for the bare REST JSON write endpoints. `Plug.CSRFProtection`
  # is the wrong tool here — it depends on a session-stored token, and the
  # API isn't driven by our own LiveView (curl + 3rd-party scripts are
  # legitimate callers as long as they come from the operator's machine).
  # Defense: Origin/Referer must match the dashboard's own origin (or
  # loopback equivalents), AND a custom `X-Aiur-Request: 1` header must
  # be present (browsers attaching this header on a same-origin XHR is
  # straightforward; cross-origin attackers can't set custom headers
  # without CORS preflight succeeding, and we never enable CORS).
  pipeline :api_write do
    plug(:verify_same_origin)
    plug(:require_custom_header)
  end

  scope "/", AiurWeb do
    pipe_through(:dashboard_auth)

    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", AiurWeb do
    pipe_through([:dashboard_auth, :browser])

    live("/", DashboardLive, :index)
  end

  scope "/", AiurWeb do
    pipe_through([:dashboard_auth, :api_write])

    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/:issue_identifier/messages", ObservabilityApiController, :send_message)
    match(:*, "/api/v1/:issue_identifier/messages", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/pane/interrupt", ObservabilityApiController, :pane_interrupt)
    match(:*, "/api/v1/pane/interrupt", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/pane/hide", ObservabilityApiController, :pane_hide)
    match(:*, "/api/v1/pane/hide", ObservabilityApiController, :method_not_allowed)
  end

  scope "/", AiurWeb do
    pipe_through(:dashboard_auth)

    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end

  defp dashboard_basic_auth(conn, _opts) do
    username = System.get_env("AIUR_DASHBOARD_USERNAME")
    password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    if present?(username) and present?(password) do
      Plug.BasicAuth.basic_auth(conn, username: username, password: password, realm: "Aiur")
    else
      conn
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # Origin/Referer allowlist. Accepts requests whose `Origin` (preferred)
  # or `Referer` (fallback for older browsers) starts with the dashboard's
  # own URL, or the loopback equivalents that operators typically use.
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

  defp require_custom_header(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "x-aiur-request") do
      ["1" | _] ->
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
      [origin | _] ->
        origin_matches_allowlist?(origin)

      [] ->
        case Plug.Conn.get_req_header(conn, "referer") do
          [referer | _] -> origin_matches_allowlist?(referer)
          [] -> false
        end
    end
  end

  defp origin_matches_allowlist?(value) when is_binary(value) do
    allowed_origins()
    |> Enum.any?(fn allowed -> String.starts_with?(value, allowed) end)
  end

  defp allowed_origins do
    own = safe_endpoint_url()
    base = ["http://127.0.0.1", "http://localhost", "https://127.0.0.1", "https://localhost"]

    if is_binary(own), do: [own | base], else: base
  end

  defp safe_endpoint_url do
    AiurWeb.Endpoint.url()
  rescue
    _ -> nil
  end
end
