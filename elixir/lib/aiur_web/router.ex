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
    pipe_through(:dashboard_auth)

    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/:issue_identifier/messages", ObservabilityApiController, :send_message)
    match(:*, "/api/v1/:issue_identifier/messages", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
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
end
