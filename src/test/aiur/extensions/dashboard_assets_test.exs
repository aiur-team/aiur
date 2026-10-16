defmodule Aiur.Extensions.DashboardAssetsTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  @endpoint AiurWeb.Endpoint
  alias Aiur.TestSupport.DashboardFontAssertions

  import Aiur.ExtensionsTestSupport
  alias Aiur.ExtensionsTestSupport.StaticOrchestrator

  setup do
    linear_client_module = Application.get_env(:aiur, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:aiur, :linear_client_module)
      else
        Application.put_env(:aiur, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    DashboardFontAssertions.assert_bootstrap(html)
    assert html =~ "Hooks.BuildHome = window.AiurBuildHome.createLiveViewHook()"
    assert {dashboard_offset, _} = :binary.match(html, "/dashboard.css")
    assert {home_offset, _} = :binary.match(html, "/build-home/home.css")
    assert home_offset > dashboard_offset

    for {asset, content_type} <- [
          {"loader.js", "text/javascript"},
          {"hook.js", "text/javascript"},
          {"logos.js", "text/javascript"},
          {"home.css", "text/css"},
          {"logos/kimi-logo.png", "image/png"},
          {"logos/deepseek-logo.png", "image/png"}
        ] do
      conn = get(build_conn(), "/build-home/#{asset}")
      assert response(conn, 200) != ""
      assert Plug.Conn.get_resp_header(conn, "content-type") == [content_type]
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, max-age=0, must-revalidate"]
    end

    assert response(get(build_conn(), "/build-home/loader.js"), 200) =~ "AiurBuildHome"
    # design-source/assets/, IMPORTED.md etag 1791431544512943.
    for {asset, hash} <- [
          {"/build-home/logos/kimi-logo.png", "b6ca346a6593c2e5094f806a96e3c4b09ebf0ea8f9c4adaa262701040a137fbf"},
          {"/provider-assets/claude-symbol.svg", "be2ee702a76d5ecffa52a7a1c47224e7ad37c13f459cdb25fd9a578dd90287e9"},
          {"/provider-assets/codex-color.svg", "bbae2b981aa4c2c79e8dcf79d56cbdb1ee58a4ebee9b19fb4def152f54da8a34"}
        ] do
      body = response(get(build_conn(), asset), 200)
      body = if String.ends_with?(asset, ".svg"), do: String.trim_trailing(body), else: body
      assert Base.encode16(:crypto.hash(:sha256, body), case: :lower) == hash
    end

    assert <<137, "PNG", 13, 10, 26, 10, 13::32, "IHDR", 240::32, 239::32, 8, 6, _::binary>> =
             response(get(build_conn(), "/build-home/logos/deepseek-logo.png"), 200)

    assert response(get(build_conn(), "/build-home/nope.js"), 404) != ""
    assert_error_sent(400, fn -> get(build_conn(), "/build-home/..%2Fdashboard.css") end)

    assert html =~ "/ticket-context-dialog-hook.js"
    assert html =~ "/conversation-voice-controller.js"
    assert html =~ "/conversation-drawer-hook.js"
    assert html =~ "/time-brush-hook.js"
    assert html =~ "/sortable-table-hook.js"
    assert html =~ "/aiur-dom-svg-layout-loader.js"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css_conn = get(build_conn(), "/dashboard.css")
    dashboard_css = response(dashboard_css_conn, 200)
    assert dashboard_css =~ ":root {"
    refute dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ "html.nav-collapsed .snav-label"
    # The collapsed rail retains its drag handle and route icons.
    assert dashboard_css =~ "html.nav-collapsed .sidenav"
    assert dashboard_css =~ ".live-button[data-live=\"false\"]"
    assert Plug.Conn.get_resp_header(dashboard_css_conn, "cache-control") == ["private, max-age=0, must-revalidate"]

    provider_assets =
      Aiur.CodingAgent.provider_descriptors()
      |> Enum.flat_map(&[&1.logo, &1.token_icon])
      |> Enum.map(&String.replace_prefix(&1, "/provider-assets/", ""))
      |> Enum.uniq()
      |> Enum.sort()

    assert provider_assets == AiurWeb.StaticAssets.provider_asset_paths()

    for provider_asset <- provider_assets do
      provider_asset_conn = get(build_conn(), "/provider-assets/#{provider_asset}")
      assert response(provider_asset_conn, 200) =~ "<svg"
      assert Plug.Conn.get_resp_header(provider_asset_conn, "cache-control") == ["private, max-age=0, must-revalidate"]
    end

    dialog_hook_conn = get(build_conn(), "/ticket-context-dialog-hook.js")
    assert response(dialog_hook_conn, 200) =~ "AiurTicketContextDialogHook"
    assert Plug.Conn.get_resp_header(dialog_hook_conn, "cache-control") == ["private, max-age=0, must-revalidate"]

    conversation_drawer_hook_conn = get(build_conn(), "/conversation-drawer-hook.js")
    assert response(conversation_drawer_hook_conn, 200) =~ "AiurConversationDrawerHook"
    assert Plug.Conn.get_resp_header(conversation_drawer_hook_conn, "content-type") == ["text/javascript"]

    conversation_voice_conn = get(build_conn(), "/conversation-voice-controller.js")
    assert response(conversation_voice_conn, 200) =~ "AiurConversationVoiceController"
    assert Plug.Conn.get_resp_header(conversation_voice_conn, "content-type") == ["text/javascript"]

    time_brush_hook_conn = get(build_conn(), "/time-brush-hook.js")
    assert response(time_brush_hook_conn, 200) =~ "AiurTimeBrushHook"
    assert Plug.Conn.get_resp_header(time_brush_hook_conn, "cache-control") == ["private, max-age=0, must-revalidate"]

    sortable_table_hook_conn = get(build_conn(), "/sortable-table-hook.js")
    assert response(sortable_table_hook_conn, 200) =~ "AiurSortableTableHook"
    assert Plug.Conn.get_resp_header(sortable_table_hook_conn, "cache-control") == ["private, max-age=0, must-revalidate"]

    for hook <- ["build-order-grid-hook.js", "streamdeck-emulator-hook.js", "streamdeck-emulator-knob.js"] do
      hook_conn = get(build_conn(), "/#{hook}")
      assert response(hook_conn, 200) != ""
      assert Plug.Conn.get_resp_header(hook_conn, "cache-control") == ["private, max-age=0, must-revalidate"]
    end

    adapter_conn = get(build_conn(), "/aiur-dom-svg-layout-adapter.js")
    adapter = response(adapter_conn, 200)
    assert adapter =~ "createDomSvgLayoutHook"
    assert Plug.Conn.get_resp_header(adapter_conn, "cache-control") == ["private, max-age=0, must-revalidate"]

    for module <- ["interaction-policy.js", "interaction.js", "lifecycle.js", "measurement.js", "protocol.js", "renderer.js"] do
      conn = get(build_conn(), "/aiur-dom-svg-layout/#{module}")
      assert response(conn, 200) != ""
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, max-age=0, must-revalidate"]
    end

    assert response(get(build_conn(), "/aiur-dom-svg-layout/not-a-module.js"), 404) == "Not Found"

    loader_conn = get(build_conn(), "/aiur-dom-svg-layout-loader.js")
    assert response(loader_conn, 200) =~ "createLiveViewHook"
    assert Plug.Conn.get_resp_header(loader_conn, "cache-control") == ["private, max-age=0, must-revalidate"]

    logo = get(build_conn(), "/aiur-logo.png")
    assert response(logo, 200) == File.read!(Path.expand("../../../../website/public/assets/aiur-logo.png", __DIR__))
    assert Plug.Conn.get_resp_header(logo, "content-type") == ["image/png"]

    github_mark = get(build_conn(), "/images/github-mark.svg")
    assert response(github_mark, 200) =~ "<svg"
    assert Plug.Conn.get_resp_header(github_mark, "cache-control") == ["private, max-age=0, must-revalidate"]

    DashboardFontAssertions.assert_fonts(&get(build_conn(), &1))

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"

    layout_urls = AiurWeb.StaticAssets.layout_asset_urls()

    assert layout_urls.engine =~ ~r/^\/vendor\/layout\/elk-0\.11\.1\/[a-f0-9]{64}\/elk-worker\.min\.js$/
    assert layout_urls.worker =~ ~r/^\/vendor\/layout\/worker-v1\/[a-f0-9]{64}\/aiur-layout-worker\.js$/
    assert layout_urls.client =~ ~r/^\/vendor\/layout\/client-v1\/[a-f0-9]{64}\/aiur-layout-client\.js$/

    for url <- Map.values(layout_urls) do
      conn = get(build_conn(), url)
      assert response(conn, 200) != ""
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/javascript; charset=utf-8"]
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
    end

    assert response(get(build_conn(), "/vendor/layout/worker-v1/not-a-digest/aiur-layout-worker.js"), 404) == "Not Found"

    for private_asset <- ["LICENSE.md", "PROVENANCE.md", "SOURCE.md"] do
      private_asset_url = String.replace(layout_urls.worker, "aiur-layout-worker.js", private_asset)
      assert response(get(build_conn(), private_asset_url), 404) == "Not Found"
    end

    assert html =~ "AgentLogPanel"
    assert html =~ "AiurTicketContextDialogHook"
    assert html =~ "hooks: Hooks"
  end
end
