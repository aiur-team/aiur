defmodule AiurWeb.StaticAssets do
  @moduledoc false

  @dashboard_css_path Path.expand("../../priv/static/dashboard.css", __DIR__)
  @phoenix_html_js_path Application.app_dir(:phoenix_html, "priv/static/phoenix_html.js")
  @phoenix_js_path Application.app_dir(:phoenix, "priv/static/phoenix.js")
  @phoenix_live_view_js_path Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.js")
  @layout_manifest_path Path.expand("../../priv/static/vendor/elk/0.11.1/manifest.json", __DIR__)

  @external_resource @dashboard_css_path
  @external_resource @phoenix_html_js_path
  @external_resource @phoenix_js_path
  @external_resource @phoenix_live_view_js_path
  @external_resource @layout_manifest_path

  @dashboard_css File.read!(@dashboard_css_path)
  @phoenix_html_js File.read!(@phoenix_html_js_path)
  @phoenix_js File.read!(@phoenix_js_path)
  @phoenix_live_view_js File.read!(@phoenix_live_view_js_path)
  @layout_manifest @layout_manifest_path |> File.read!() |> Jason.decode!()

  @assets %{
    "/dashboard.css" => {"text/css", @dashboard_css},
    "/vendor/phoenix_html/phoenix_html.js" => {"application/javascript", @phoenix_html_js},
    "/vendor/phoenix/phoenix.js" => {"application/javascript", @phoenix_js},
    "/vendor/phoenix_live_view/phoenix_live_view.js" => {"application/javascript", @phoenix_live_view_js}
  }

  @layout_assets Map.new(Map.fetch!(@layout_manifest, "assets"), fn {_name, asset} ->
                   {asset["url"], {asset["contentType"], Path.join("priv/static/vendor/elk/0.11.1", asset["file"])}}
                 end)

  @layout_asset_urls %{
    engine: get_in(@layout_manifest, ["assets", "engine", "url"]),
    worker: get_in(@layout_manifest, ["assets", "worker", "url"]),
    client: get_in(@layout_manifest, ["assets", "client", "url"])
  }

  @spec layout_asset_urls() :: %{engine: String.t(), worker: String.t(), client: String.t()}
  def layout_asset_urls, do: @layout_asset_urls

  @spec fetch(String.t()) :: {:ok, String.t(), binary()} | :error
  def fetch("/aiur-logo.png") do
    :aiur
    |> Application.app_dir("priv/static/aiur-logo.png")
    |> File.read()
    |> case do
      {:ok, body} -> {:ok, "image/png", body}
      {:error, _reason} -> :error
    end
  end

  def fetch(path) when is_binary(path) do
    with :error <- Map.fetch(@assets, path),
         {:ok, {content_type, asset_path}} <- Map.fetch(@layout_assets, path),
         {:ok, body} <- File.read(Application.app_dir(:aiur, asset_path)) do
      {:ok, content_type, body}
    else
      {:ok, {content_type, body}} -> {:ok, content_type, body}
      _ -> :error
    end
  end
end
