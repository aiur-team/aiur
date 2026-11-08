defmodule AiurWeb.GatewayPauseControllerTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest
  import Plug.Conn
  alias Aiur.Intent.Registers
  alias Aiur.Orchestrator.{Client, GlobalPause}
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Endpoint
  @endpoint Endpoint

  @listed "https://nook.t.ts.net"

  setup do
    config = Application.get_env(:aiur, Endpoint)

    Application.put_env(
      :aiur,
      Endpoint,
      Keyword.merge(config || [], server: false, dashboard_auth_required: false, dashboard_writable: true, dashboard_origins: [@listed], secret_key_base: String.duplicate("s", 64))
    )

    Aiur.TestSupport.start_owned_endpoint!()

    root = Path.join(System.tmp_dir!(), "aiur-gw-pause-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :client_tokens_path)
    Application.put_env(:aiur, :client_tokens_path, Path.join(root, "client-tokens.json"))

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, config)
      if previous, do: Application.put_env(:aiur, :client_tokens_path, previous), else: Application.delete_env(:aiur, :client_tokens_path)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    :ok
  end

  defp token_conn(scope, extra) do
    {:ok, token} = Aiur.ClientTokens.create("pause-#{scope}-#{System.unique_integer([:positive])}", scope)

    Enum.reduce(extra, build_conn() |> put_req_header("content-type", "application/json") |> put_req_header("authorization", "Bearer " <> token), fn {k, v}, c -> put_req_header(c, k, v) end)
  end

  test "the literal gateway routes are not captured as an issue identifier" do
    routes = Phoenix.Router.routes(AiurWeb.Router)

    for {path, action} <- [{"/api/v1/gateway/pause", :pause}, {"/api/v1/gateway/resume", :resume}, {"/api/v1/fleet/pause", :fleet_pause}, {"/api/v1/fleet/resume", :fleet_resume}] do
      route = Enum.find(routes, &(&1.verb == :post and &1.path == path))
      assert {route.plug, route.plug_opts} == {AiurWeb.GatewayPauseController, action}
    end
  end

  test "a signed-out write is a 401 and a missing header is refused" do
    conn = build_conn() |> put_req_header("content-type", "application/json") |> put_req_header("origin", @listed) |> put_req_header("x-aiur-request", "1") |> post("/api/v1/gateway/pause", "{}")
    assert json_response(conn, 401) == %{"error" => "signed_out"}

    conn = token_conn("write", [{"origin", @listed}]) |> post("/api/v1/gateway/pause", "{}")
    assert json_response(conn, 403) == %{"error" => "missing X-Aiur-Request header"}
  end

  test "a read-scoped token cannot pause; an unlisted origin is refused with no CORS headers" do
    conn = token_conn("read", [{"origin", @listed}, {"x-aiur-request", "1"}]) |> post("/api/v1/gateway/pause", "{}")
    assert json_response(conn, 401) == %{"error" => "unauthorized"}

    conn = token_conn("write", [{"origin", "https://evil.example"}, {"x-aiur-request", "1"}]) |> post("/api/v1/gateway/pause", "{}")
    assert json_response(conn, 403) == %{"error" => "origin not allowed"}
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "a listed origin's preflight allows POST with the custom header" do
    conn = build_conn() |> put_req_header("origin", @listed) |> put_req_header("access-control-request-method", "POST") |> options("/api/v1/gateway/pause")
    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == [@listed]
    assert hd(get_resp_header(conn, "access-control-allow-methods")) =~ "POST"
    assert hd(get_resp_header(conn, "access-control-allow-headers")) =~ "x-aiur-request"
  end

  test "a listed origin pauses this gateway and resumes it, echoing the request id" do
    headers = [{"origin", @listed}, {"x-aiur-request", "1"}]

    body = token_conn("write", headers) |> post("/api/v1/gateway/pause", ~s({"request_id": "r-1"})) |> json_response(200)
    assert %{"ok" => true, "globally_paused" => true, "request_id" => "r-1"} = body
    assert {:ok, %{globally_paused: true}} = Client.global_pause_status()

    body = token_conn("write", headers) |> post("/api/v1/gateway/resume", ~s({"request_id": "r-2"})) |> json_response(200)
    assert %{"globally_paused" => false, "request_id" => "r-2"} = body
  end

  test "fleet pause with no shared store still pauses this gateway and says the intent was not stored" do
    # A human resume clears every fleet.pause slot, so the change this writes cannot outlive the test.
    on_exit(fn ->
      Registers.write_fleet_pause(false)
      GlobalPause.sync_fleet_pause()
    end)

    headers = [{"origin", @listed}, {"x-aiur-request", "1"}]
    body = token_conn("write", headers) |> post("/api/v1/fleet/pause", ~s({"request_id": "r-3"})) |> json_response(200)
    assert %{"ok" => true, "intent_written" => false, "globally_paused" => true, "request_id" => "r-3"} = body
  end

  test "writes are blocked while the dashboard is read-only" do
    EndpointStubs.put(dashboard_writable: false)
    conn = token_conn("write", [{"origin", @listed}, {"x-aiur-request", "1"}]) |> post("/api/v1/gateway/pause", "{}")
    assert json_response(conn, 403) == %{"error" => "dashboard is read-only"}
  end
end
