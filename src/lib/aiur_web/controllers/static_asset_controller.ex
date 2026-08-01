defmodule AiurWeb.StaticAssetController do
  @moduledoc """
  Serves the dashboard's embedded CSS and JavaScript assets.
  """

  use Phoenix.Controller, formats: []

  alias AiurWeb.StaticAssets
  alias Plug.Conn

  @spec dashboard_css(Conn.t(), map()) :: Conn.t()
  def dashboard_css(conn, _params), do: serve(conn, "/dashboard.css", revalidate?: true)

  @spec ticket_context_dialog_hook(Conn.t(), map()) :: Conn.t()
  def ticket_context_dialog_hook(conn, _params), do: serve(conn, "/ticket-context-dialog-hook.js", revalidate?: true)

  @spec build_order_grid_hook(Conn.t(), map()) :: Conn.t()
  def build_order_grid_hook(conn, _params), do: serve(conn, "/build-order-grid-hook.js", revalidate?: true)

  @spec time_brush_hook(Conn.t(), map()) :: Conn.t()
  def time_brush_hook(conn, _params), do: serve(conn, "/time-brush-hook.js", revalidate?: true)

  @spec streamdeck_emulator_hook(Conn.t(), map()) :: Conn.t()
  def streamdeck_emulator_hook(conn, _params), do: serve(conn, "/streamdeck-emulator-hook.js", revalidate?: true)

  @spec dom_svg_layout_adapter(Conn.t(), map()) :: Conn.t()
  def dom_svg_layout_adapter(conn, _params), do: serve(conn, "/aiur-dom-svg-layout-adapter.js", revalidate?: true)

  @spec dom_svg_layout_module(Conn.t(), map()) :: Conn.t()
  def dom_svg_layout_module(conn, %{"module" => module}), do: serve(conn, "/aiur-dom-svg-layout/#{module}", revalidate?: true)

  @spec dom_svg_layout_loader(Conn.t(), map()) :: Conn.t()
  def dom_svg_layout_loader(conn, _params), do: serve(conn, "/aiur-dom-svg-layout-loader.js", revalidate?: true)

  @spec aiur_logo(Conn.t(), map()) :: Conn.t()
  def aiur_logo(conn, _params), do: serve(conn, "/aiur-logo.png")

  @spec provider_asset(Conn.t(), map()) :: Conn.t()
  def provider_asset(conn, %{"provider_asset" => asset}), do: serve(conn, "/provider-assets/" <> asset, revalidate?: true)

  @spec bungee_font(Conn.t(), map()) :: Conn.t()
  def bungee_font(conn, _params), do: serve(conn, "/bungee.woff2")

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
    if Keyword.get(options, :revalidate?, false), do: "private, max-age=0, must-revalidate", else: cache_control_with_lifetime(options)
  end

  defp cache_control_with_lifetime(options) do
    visibility = if Keyword.get(options, :private?, false), do: "private", else: "public"
    immutable = if Keyword.get(options, :immutable?, false), do: ", immutable", else: ""
    "#{visibility}, max-age=31536000#{immutable}"
  end
end
