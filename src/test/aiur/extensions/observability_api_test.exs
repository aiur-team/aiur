defmodule Aiur.Extensions.ObservabilityApiTest do
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

  test "phoenix observability api preserves state, issue, and refresh responses" do
    last_failure_at = ~U[2026-09-29 12:00:00Z]
    snapshot = update_in(static_snapshot(), [:retrying], fn [retrying] -> [Map.put(retrying, :last_failure_at, last_failure_at)] end)

    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

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

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)
    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)
    assert_occ_sections(state_payload)
    assert %{"snapshot_freshness" => %{"status" => "current", "freshness_window_ms" => 600_000}, "observations" => nil, "daemon_started_at" => nil} = state_payload

    assert state_payload |> without_occ_sections() |> Map.drop(~w(snapshot_freshness observations daemon_started_at)) == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1, "idle" => 0},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "tag" => nil,
                 "title" => nil,
                 "url" => nil,
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "repl_attach_command" => nil,
                 "turn_count" => 7,
                 "runtime_seconds" => 0,
                 "work_state" => "working",
                 "pause_reason" => nil,
                 "tracker_paused" => false,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "live_conversation" => nil,
                 "queue_depth" => 1,
                 "capabilities" => %{
                   "accepts_operator_messages" => true,
                   "can_interrupt" => false,
                   "accepted_delivery_policies" => ["checkpoint"],
                   "safe_checkpoints" => ["notification", "tool_result"],
                   "queue_depth" => 1
                 },
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "stale_for_seconds" => nil,
                 "waiting_reason" => "active",
                 "waiting" => nil,
                 "open_decision_count" => 0,
                 "open_decision_count_health" => "unknown",
                 "ci" => nil,
                 "review" => "not_started"
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "last_failure_at" => DateTime.to_iso8601(last_failure_at),
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "state" => nil,
                 "tag" => nil,
                 "title" => nil,
                 "url" => nil,
                 "runtime_seconds" => 0,
                 "work_state" => "retrying",
                 "tracker_paused" => false,
                 "waiting_reason" => "backing_off",
                 "waiting" => nil,
                 "open_decision_count" => 0,
                 "open_decision_count_health" => "unknown",
                 "ci" => nil,
                 "review" => "not_started"
               }
             ],
             "idle" => [],
             "agent_totals" => %{"seconds_running" => 42.5},
             "polling" => %{
               "checking?" => false,
               "effective_interval_ms" => 600_000,
               "idle_backoff" => %{"active?" => true, "factor" => 5.0},
               "next_poll_in_ms" => 480_000,
               "poll_interval_ms" => 120_000
             },
             # The global pause switch rides on every payload: a quiet fleet reads apart from a held one.
             "globally_paused" => false
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "queue_depth" => 1,
               "capabilities" => %{
                 "accepts_operator_messages" => true,
                 "can_interrupt" => false,
                 "accepted_delivery_policies" => ["checkpoint"],
                 "safe_checkpoints" => ["notification", "tool_result"],
                 "queue_depth" => 1
               },
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "live_conversation" => nil,
               "last_event_at" => nil,
               "stale_for_seconds" => nil,
               "waiting_reason" => "active",
               "open_decision_count" => 0,
               "open_decision_count_health" => "unknown",
               "ci" => nil,
               "review" => "not_started"
             },
             "retry" => nil,
             "capabilities" => %{
               "accepts_operator_messages" => true,
               "can_interrupt" => false,
               "accepted_delivery_policies" => ["checkpoint"],
               "safe_checkpoints" => ["notification", "tool_result"],
               "queue_depth" => 1
             },
             "queue" => %{"depth" => 1},
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> post("/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> post("/api/v1/MT-HTTP/messages", %{"text" => "hello"})

    assert json_response(conn, 202) == %{"issue_identifier" => "MT-HTTP", "request_id" => 1}
  end

  # #2717. The daemon may still queue a message after the API call timed out,
  # so a timeout is reported as an unknown outcome that is safe to retry.
  test "message api reports a timed-out send as an unknown outcome" do
    original_timeout = Application.get_env(:aiur, :operator_message_call_timeout_ms)
    Application.put_env(:aiur, :operator_message_call_timeout_ms, 50)

    on_exit(fn ->
      if original_timeout,
        do: Application.put_env(:aiur, :operator_message_call_timeout_ms, original_timeout),
        else: Application.delete_env(:aiur, :operator_message_call_timeout_ms)
    end)

    orchestrator_name = Module.concat(__MODULE__, :SlowSendOrchestrator)

    slow_send = fn _issue_identifier ->
      Process.sleep(300)
      {:ok, 9}
    end

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: static_snapshot(), send_operator_message: slow_send})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> post("/api/v1/MT-HTTP/messages", %{"text" => "hello", "message_id" => "client-1"})

    assert json_response(conn, 202) == %{
             "outcome" => "unknown",
             "request_id" => nil,
             "message_id" => "client-1",
             "issue_identifier" => "MT-HTTP",
             "retry_safe" => true
           }
  end
end
