defmodule AiurWeb.StaticAssetController do
  @moduledoc """
  Serves the dashboard's embedded CSS and JavaScript assets.
  """

  use Phoenix.Controller, formats: []

  alias AiurWeb.StaticAssets
  alias Plug.Conn

  @spec dashboard_css(Conn.t(), map()) :: Conn.t()
  def dashboard_css(conn, _params), do: serve(conn, "/dashboard.css")

  @spec aiur_logo(Conn.t(), map()) :: Conn.t()
  def aiur_logo(conn, _params), do: serve(conn, "/aiur-logo.png")

  @spec phoenix_html_js(Conn.t(), map()) :: Conn.t()
  def phoenix_html_js(conn, _params), do: serve(conn, "/vendor/phoenix_html/phoenix_html.js")

  @spec phoenix_js(Conn.t(), map()) :: Conn.t()
  def phoenix_js(conn, _params), do: serve(conn, "/vendor/phoenix/phoenix.js")

  @spec phoenix_live_view_js(Conn.t(), map()) :: Conn.t()
  def phoenix_live_view_js(conn, _params), do: serve(conn, "/vendor/phoenix_live_view/phoenix_live_view.js")

  @spec layout_asset(Conn.t(), map()) :: Conn.t()
  def layout_asset(conn, %{"version" => version, "digest" => digest, "asset" => asset}) do
    serve(conn, "/vendor/layout/#{version}/#{digest}/#{asset}", immutable?: true, private?: true)
  end

  defp serve(conn, path, options \\ []) do
    case StaticAssets.fetch(path) do
      {:ok, content_type, body} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", cache_control(options))
        |> send_resp(200, body)

      :error ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp cache_control(options) do
    visibility = if Keyword.get(options, :private?, false), do: "private", else: "public"
    immutable = if Keyword.get(options, :immutable?, false), do: ", immutable", else: ""
    "#{visibility}, max-age=31536000#{immutable}"
  end
end
