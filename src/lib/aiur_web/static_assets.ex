defmodule AiurWeb.StaticAssets do
  @moduledoc false

  @dashboard_css_path Path.expand("../../priv/static/dashboard.css", __DIR__)
  @dom_svg_layout_adapter_path Path.expand("../../priv/static/aiur-dom-svg-layout-adapter.js", __DIR__)
  @phoenix_html_js_path Application.app_dir(:phoenix_html, "priv/static/phoenix_html.js")
  @phoenix_js_path Application.app_dir(:phoenix, "priv/static/phoenix.js")
  @phoenix_live_view_js_path Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.js")
  @layout_vendor_path "priv/static/vendor/elk/0.11.1"

  @layout_asset_definitions %{
    engine: %{name: "engine", revision: "elk-0.11.1", file: "elk-worker.min.js"},
    worker: %{name: "worker", revision: "worker-v1", file: "aiur-layout-worker.js"},
    client: %{name: "client", revision: "client-v1", file: "aiur-layout-client.js"}
  }

  @dom_svg_layout_modules %{
    "/aiur-dom-svg-layout-loader.js" => "priv/static/aiur-dom-svg-layout-loader.js",
    "/aiur-dom-svg-layout/lifecycle.js" => "priv/static/aiur-dom-svg-layout/lifecycle.js",
    "/aiur-dom-svg-layout/measurement.js" => "priv/static/aiur-dom-svg-layout/measurement.js",
    "/aiur-dom-svg-layout/protocol.js" => "priv/static/aiur-dom-svg-layout/protocol.js",
    "/aiur-dom-svg-layout/renderer.js" => "priv/static/aiur-dom-svg-layout/renderer.js"
  }

  @runtime_static_assets %{
    "/ticket-context-dialog-hook.js" => {"application/javascript", "priv/static/ticket-context-dialog-hook.js"}
  }

  @external_resource @dashboard_css_path
  @external_resource @dom_svg_layout_adapter_path
  @external_resource @phoenix_html_js_path
  @external_resource @phoenix_js_path
  @external_resource @phoenix_live_view_js_path

  @dashboard_css File.read!(@dashboard_css_path)
  @dom_svg_layout_adapter File.read!(@dom_svg_layout_adapter_path)
  @phoenix_html_js File.read!(@phoenix_html_js_path)
  @phoenix_js File.read!(@phoenix_js_path)
  @phoenix_live_view_js File.read!(@phoenix_live_view_js_path)

  @assets %{
    "/dashboard.css" => {"text/css", @dashboard_css},
    "/aiur-dom-svg-layout-adapter.js" => {"application/javascript", @dom_svg_layout_adapter},
    "/vendor/phoenix_html/phoenix_html.js" => {"application/javascript", @phoenix_html_js},
    "/vendor/phoenix/phoenix.js" => {"application/javascript", @phoenix_js},
    "/vendor/phoenix_live_view/phoenix_live_view.js" => {"application/javascript", @phoenix_live_view_js}
  }

  @spec layout_asset_urls() :: %{engine: String.t(), worker: String.t(), client: String.t()}
  def layout_asset_urls do
    case layout_assets() do
      {:ok, assets} ->
        Map.new(@layout_asset_definitions, fn {key, %{name: name}} ->
          {key, get_in(assets, [name, "url"])}
        end)

      :error ->
        %{engine: "", worker: "", client: ""}
    end
  end

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
    case Map.fetch(@runtime_static_assets, path) do
      {:ok, {content_type, asset_path}} -> read_static_asset(content_type, asset_path)
      :error -> fetch_dom_svg_layout_module(path)
    end
  end

  defp fetch_dom_svg_layout_module(path) do
    case Map.fetch(@dom_svg_layout_modules, path) do
      {:ok, asset_path} -> read_static_asset("application/javascript", asset_path)
      :error -> fetch_embedded_or_layout_asset(path)
    end
  end

  defp read_static_asset(content_type, asset_path) do
    case File.read(Application.app_dir(:aiur, asset_path)) do
      {:ok, body} -> {:ok, content_type, body}
      {:error, _reason} -> :error
    end
  end

  defp fetch_embedded_or_layout_asset(path) do
    with :error <- Map.fetch(@assets, path),
         {:ok, {content_type, asset_path, expected_size, expected_sha256}} <- layout_asset(path),
         {:ok, body} <- File.read(Application.app_dir(:aiur, asset_path)),
         true <- byte_size(body) == expected_size,
         true <- sha256(body) == expected_sha256 do
      {:ok, content_type, body}
    else
      {:ok, {content_type, body}} -> {:ok, content_type, body}
      _ -> :error
    end
  end

  defp layout_asset(path) do
    with {:ok, assets} <- layout_assets(),
         {_name, asset} <- Enum.find(assets, fn {_name, asset} -> asset["url"] == path end) do
      {:ok,
       {
         asset["contentType"],
         Path.join(@layout_vendor_path, asset["file"]),
         asset["bytes"],
         asset["sha256"]
       }}
    else
      _ -> :error
    end
  end

  defp layout_assets do
    with {:ok, manifest} <- read_layout_manifest(),
         assets when is_map(assets) <- Map.get(manifest, "assets"),
         true <- manifest["schema"] == 1,
         true <- MapSet.equal?(MapSet.new(Map.keys(assets)), MapSet.new(Enum.map(@layout_asset_definitions, fn {_key, %{name: name}} -> name end))),
         {:ok, verified_assets} <- verify_layout_assets(assets),
         true <- get_in(verified_assets, ["worker", "engineUrl"]) == get_in(verified_assets, ["engine", "url"]) do
      {:ok, verified_assets}
    else
      _ -> :error
    end
  end

  defp read_layout_manifest do
    :aiur
    |> Application.app_dir(Path.join(@layout_vendor_path, "manifest.json"))
    |> File.read()
    |> case do
      {:ok, body} -> Jason.decode(body)
      {:error, _reason} -> :error
    end
  end

  defp verify_layout_assets(assets) do
    @layout_asset_definitions
    |> Enum.reduce_while({:ok, %{}}, fn {_key, definition}, {:ok, verified_assets} ->
      asset = Map.get(assets, definition.name)

      if valid_layout_asset?(asset, definition) do
        {:cont, {:ok, Map.put(verified_assets, definition.name, asset)}}
      else
        {:halt, :error}
      end
    end)
  end

  defp valid_layout_asset?(asset, definition) when is_map(asset) do
    Enum.all?([
      expected_asset_keys?(asset, definition),
      matches_asset_file?(asset, definition),
      valid_asset_metadata?(asset),
      content_addressed_asset_url?(asset, definition),
      valid_worker_engine_url?(asset, definition)
    ])
  end

  defp valid_layout_asset?(_asset, _definition), do: false

  defp expected_asset_keys?(asset, %{name: "worker"}) do
    MapSet.equal?(MapSet.new(Map.keys(asset)), MapSet.new(["engineUrl", "file", "sha256", "bytes", "contentType", "url"]))
  end

  defp expected_asset_keys?(asset, _definition) do
    MapSet.equal?(MapSet.new(Map.keys(asset)), MapSet.new(["file", "sha256", "bytes", "contentType", "url"]))
  end

  defp matches_asset_file?(asset, %{file: file}), do: asset["file"] == file

  defp valid_asset_metadata?(asset) do
    asset["contentType"] == "application/javascript" and
      is_integer(asset["bytes"]) and asset["bytes"] > 0 and
      is_binary(asset["sha256"]) and Regex.match?(~r/^[a-f0-9]{64}$/, asset["sha256"])
  end

  defp content_addressed_asset_url?(asset, %{revision: revision, file: file}) do
    asset["url"] == "/vendor/layout/#{revision}/#{asset["sha256"]}/#{file}"
  end

  defp valid_worker_engine_url?(asset, %{name: "worker"}), do: is_binary(asset["engineUrl"])
  defp valid_worker_engine_url?(_asset, _definition), do: true

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
