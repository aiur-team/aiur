defmodule Aiur.Extensions.ReadOnlyApiTest do
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

  test "read-only dashboard blocks agent-write endpoints but keeps reads working" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ReadOnlyOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      dashboard_writable: false
    )

    # Reads still work.
    assert %{"counts" => _} = json_response(get(build_conn(), "/api/v1/state"), 200)

    # Agent-write endpoints are gated read-only (after the CSRF bypass headers,
    # so we're proving the read-only gate, not the same-origin gate).
    refresh_conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> post("/api/v1/refresh", %{})

    assert json_response(refresh_conn, 403) == %{"error" => "dashboard is read-only"}

    messages_conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> post("/api/v1/MT-HTTP/messages", %{"text" => "hello"})

    assert json_response(messages_conn, 403) == %{"error" => "dashboard is read-only"}
  end

  test "read-only dashboard keeps the machine-to-machine claude-hook working" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :ClaudeHookOrchestrator),
      snapshot_timeout_ms: 5,
      dashboard_writable: false
    )

    hook_conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> post("/api/v1/MT-RO/claude-hook", %{"hook_event_name" => "Stop"})

    assert json_response(hook_conn, 200) == %{"ok" => true}
  end
end
