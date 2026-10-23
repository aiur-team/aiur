defmodule Aiur.Extensions.HttpServerTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  @endpoint AiurWeb.Endpoint

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

  test "every logo LOGOS advertises is served" do
    start_test_endpoint(snapshot_timeout_ms: 50)
    source = File.read!(Application.app_dir(:aiur, "priv/static/build-home/logos.js"))
    entries = Regex.scan(~r/(\w+): Object.freeze\(\{ src: "([^"]+)"/, source)
    assert Enum.map(entries, fn [_, key, _] -> key end) == ~w(claude codex deepseek kimi)

    for [_, _, path] <- entries do
      conn = get(build_conn(), path)
      assert response(conn, 200) != ""
      assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "image/")
    end
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    previous_endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint)
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
      restore_endpoint_config(previous_endpoint_config)
    end)

    authorization = {"authorization", "Basic " <> Base.encode64("operator:secret")}

    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      dashboard_writable: true
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()
    assert HttpServer.base_url() == "http://127.0.0.1:#{port}"

    unauthenticated_response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert unauthenticated_response.status == 401

    # Regression guard: router auth still returns 401 if the static directory registration is removed.
    for asset_path <- [
          "/conversation-drawer-hook.js",
          "/conversation-voice-controller.js",
          "/voice-capture.js",
          "/voice-transport.js",
          "/provider-assets/codex-color.svg",
          "/build-home/loader.js",
          "/build-home/logos/kimi-logo.png",
          "/build-home/nope.js",
          "/aiur-style/fonts/SpaceGrotesk-Variable.woff2"
        ] do
      unauthenticated_asset = Req.get!("http://127.0.0.1:#{port}#{asset_path}")
      assert unauthenticated_asset.status == 401
    end

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state", headers: [authorization])
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1, "idle" => 0}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css", headers: [authorization])
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    conversation_drawer_hook = Req.get!("http://127.0.0.1:#{port}/conversation-drawer-hook.js", headers: [authorization])
    assert conversation_drawer_hook.status == 200
    assert conversation_drawer_hook.body =~ "AiurConversationDrawerHook"

    conversation_voice = Req.get!("http://127.0.0.1:#{port}/conversation-voice-controller.js", headers: [authorization])
    assert conversation_voice.status == 200
    assert conversation_voice.body =~ "AiurConversationVoiceController"

    provider_asset = Req.get!("http://127.0.0.1:#{port}/provider-assets/codex-color.svg", headers: [authorization])
    assert provider_asset.status == 200
    assert provider_asset.body =~ "<svg"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js", headers: [authorization])
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [
          authorization,
          {"content-type", "application/x-www-form-urlencoded"},
          {"origin", "http://127.0.0.1:#{port}"},
          {"x-aiur-request", "1"}
        ],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [authorization, {"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405

    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    credential_loss_response =
      Req.get!("http://127.0.0.1:#{port}/api/v1/state", headers: [authorization])

    assert credential_loss_response.status == 401
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  test "http server honors host override when workflow host is unavailable" do
    previous_host_override = Application.get_env(:aiur, :server_host_override)

    Application.put_env(:aiur, :server_host_override, "127.0.0.1")

    on_exit(fn ->
      case previous_host_override do
        nil -> Application.delete_env(:aiur, :server_host_override)
        host -> Application.put_env(:aiur, :server_host_override, host)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      server_host: "192.0.2.123",
      server_port: 0
    )

    start_supervised!({HttpServer, port: 0, dashboard_writable: false})
    assert is_integer(wait_for_bound_port())
  end

  defp restore_endpoint_config(nil), do: Application.delete_env(:aiur, AiurWeb.Endpoint)
  defp restore_endpoint_config(config), do: Application.put_env(:aiur, AiurWeb.Endpoint, config)

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end
end
