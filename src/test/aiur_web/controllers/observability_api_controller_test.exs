defmodule AiurWeb.ObservabilityApiControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.{Claude.HookEvents, DecisionStore, IssueLog}
  alias Aiur.Orchestrator.SnapshotStore

  defmodule ControlOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state), do: {:reply, %{}, state}

    def handle_call({:pause_agent, issue_identifier}, _from, state) do
      notify_call(state, :pause, issue_identifier)
      {:reply, control_result(state, :pause_agent, issue_identifier), state}
    end

    def handle_call({:resume_agent, issue_identifier}, _from, state) do
      notify_call(state, :resume, issue_identifier)
      {:reply, control_result(state, :resume_agent, issue_identifier), state}
    end

    defp notify_call(state, action, issue_identifier) do
      if recipient = Keyword.get(state, :recipient), do: send(recipient, {:control_call, action, issue_identifier})
    end

    defp control_result(state, action, issue_identifier) do
      case Keyword.get(state, action, {:error, :no_running_agent}) do
        fun when is_function(fun, 1) -> fun.(issue_identifier)
        result -> result
      end
    end
  end

  # api_write endpoints require a loopback Origin + the X-Aiur-Request header,
  # and the dashboard_auth plug challenges every request once credentials are
  # configured (test_helper sets them globally), so dashboard routes also carry
  # the configured Basic Auth header.
  defp hook_conn(identifier, payload) do
    :post
    |> conn("/api/v1/#{identifier}/claude-hook", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("origin", "http://127.0.0.1")
    |> put_req_header("x-aiur-request", "1")
    |> authed()
  end

  defp authed(conn) do
    put_req_header(
      conn,
      "authorization",
      "Basic " <> Base.encode64("operator:test-dashboard-secret")
    )
  end

  defp call(conn), do: AiurWeb.Endpoint.call(conn, AiurWeb.Endpoint.init([]))

  defp json_response(conn, status) do
    assert conn.status == status
    Jason.decode!(conn.resp_body)
  end

  # AiurWeb.Endpoint is normally the Aiur.HttpServer supervised child, but
  # Aiur.TestSupport's setup terminates that child and never restarts it. So
  # under full-suite ordering the endpoint's config ETS table can be gone by
  # the time these tests run, and Endpoint.call/2 raises on the missing table.
  # Stand up a throwaway endpoint (server: false, no port bind) whenever none
  # is running, so Endpoint.call/2 always has its config table. When one is
  # already running, reset both its live config and the application config: a
  # prior writable HttpServer test may have left auth required in the shared
  # Endpoint table even after restoring the application environment.
  setup do
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])
    missing = make_ref()

    runtime_auth_required =
      if Process.whereis(AiurWeb.Endpoint) do
        AiurWeb.Endpoint.config(:dashboard_auth_required, missing)
      else
        missing
      end

    runtime_orchestrator =
      if Process.whereis(AiurWeb.Endpoint) do
        AiurWeb.Endpoint.config(:orchestrator, missing)
      else
        missing
      end

    runtime_dashboard_writable =
      if Process.whereis(AiurWeb.Endpoint) do
        AiurWeb.Endpoint.config(:dashboard_writable, missing)
      else
        missing
      end

    test_config =
      Keyword.merge(endpoint_config,
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_auth_required: false
      )

    Application.put_env(:aiur, AiurWeb.Endpoint, test_config)

    Aiur.TestSupport.start_owned_endpoint!()
    AiurWeb.Endpoint.config_change([dashboard_auth_required: false], [])

    on_exit(fn ->
      Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
      restore_runtime_config(:dashboard_auth_required, runtime_auth_required, missing)
      restore_runtime_config(:orchestrator, runtime_orchestrator, missing)
      restore_runtime_config(:dashboard_writable, runtime_dashboard_writable, missing)
    end)

    :ok
  end

  defp restore_runtime_config(key, previous_value, missing) do
    if Process.whereis(AiurWeb.Endpoint) do
      if previous_value == missing do
        :ets.delete(AiurWeb.Endpoint, key)
      else
        Phoenix.Config.put(AiurWeb.Endpoint, key, previous_value)
      end
    end
  end

  defp config_change_if_running(changed) do
    if Process.whereis(AiurWeb.Endpoint) do
      try do
        AiurWeb.Endpoint.config_change(changed, [])
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp control_conn(identifier, action) do
    :post
    |> conn("/api/v1/#{identifier}/#{action}")
    |> put_req_header("origin", "http://127.0.0.1")
    |> put_req_header("x-aiur-request", "1")
    |> authed()
  end

  defp start_control_orchestrator(opts \\ []) do
    name = Module.concat(__MODULE__, "ControlOrchestrator#{System.unique_integer([:positive])}")
    start_supervised!({ControlOrchestrator, Keyword.put(opts, :name, name)})
    name
  end

  defp configure_endpoint(orchestrator, opts \\ []) do
    dashboard_writable = Keyword.get(opts, :dashboard_writable, true)

    Phoenix.Config.put(AiurWeb.Endpoint, :orchestrator, orchestrator)
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, dashboard_writable)
  end

  describe "POST /api/v1/:id/claude-hook" do
    test "dispatches a Stop event to the agent topic and returns 200" do
      :ok = HookEvents.subscribe("MT-EP")

      conn =
        call(
          hook_conn("MT-EP", %{
            "hook_event_name" => "Stop",
            "last_assistant_message" => "PONG",
            "session_id" => "s1",
            "cwd" => "/w"
          })
        )

      assert conn.status == 200
      assert_receive {:claude_hook, "MT-EP", %{event: :stop, message: "PONG"}}, 500
    end

    test "returns 200 even for an unknown/inactive identifier (never errors claude)" do
      conn = call(hook_conn("MT-NOBODY", %{"hook_event_name" => "Stop", "last_assistant_message" => "x"}))
      assert conn.status == 200
    end

    test "rejects without the X-Aiur-Request header" do
      conn =
        :post
        |> conn("/api/v1/MT-EP/claude-hook", Jason.encode!(%{"hook_event_name" => "Stop"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "http://127.0.0.1")
        |> authed()
        |> call()

      assert conn.status == 403
    end
  end

  describe "POST /api/v1/:id/pause and /resume" do
    test "delegates pause and resume and returns their successful results" do
      orchestrator =
        start_control_orchestrator(
          pause_agent: {:ok, 17},
          resume_agent: {:ok, :started},
          recipient: self()
        )

      configure_endpoint(orchestrator)

      assert json_response(call(control_conn("MT-CONTROL", "pause")), 202) == %{
               "action" => "pause",
               "issue_identifier" => "MT-CONTROL",
               "result" => 17
             }

      assert_receive {:control_call, :pause, "MT-CONTROL"}

      assert json_response(call(control_conn("MT-CONTROL", "resume")), 202) == %{
               "action" => "resume",
               "issue_identifier" => "MT-CONTROL",
               "result" => "started"
             }

      assert_receive {:control_call, :resume, "MT-CONTROL"}
    end

    test "returns 409 when pause or resume has no running agent" do
      orchestrator = start_control_orchestrator()
      configure_endpoint(orchestrator)

      for action <- ["pause", "resume"] do
        assert json_response(call(control_conn("MT-MISSING", action)), 409) == %{
                 "error" => %{
                   "code" => "agent_not_running",
                   "message" => "Agent is not currently running"
                 }
               }
      end
    end

    test "returns detailed queued-resume refusals as conflicts" do
      reason =
        {:stale_tracker_state, {:tracker_state_not_resumable, "merging"}, %{cached_state: "todo", tracker_state: "merging", changed_fields: [:state]}}

      orchestrator = start_control_orchestrator(resume_agent: {:error, reason})
      configure_endpoint(orchestrator)

      assert %{"error" => %{"code" => "control_conflict", "message" => message}} =
               json_response(call(control_conn("MT-STALE", "resume")), 409)

      assert message =~ "stale_tracker_state"
      assert message =~ "merging"
    end

    test "keeps tracker refresh failures transient" do
      orchestrator =
        start_control_orchestrator(resume_agent: {:error, {:tracker_refresh_failed, :timeout}})

      configure_endpoint(orchestrator)

      assert %{"error" => %{"code" => "control_failed", "message" => message}} =
               json_response(call(control_conn("MT-OUTAGE", "resume")), 503)

      assert message =~ "tracker_refresh_failed"
    end

    test "refuses both controls when the dashboard is read-only" do
      orchestrator = start_control_orchestrator(pause_agent: {:ok, 17}, resume_agent: {:ok, :resumed})
      configure_endpoint(orchestrator, dashboard_writable: false)

      for action <- ["pause", "resume"] do
        assert json_response(call(control_conn("MT-CONTROL", action)), 403) == %{
                 "error" => "dashboard is read-only"
               }
      end
    end

    test "returns 405 for non-POST methods" do
      orchestrator = start_control_orchestrator(pause_agent: {:ok, 17}, resume_agent: {:ok, :resumed})
      configure_endpoint(orchestrator)

      for action <- ["pause", "resume"] do
        conn =
          :get
          |> conn("/api/v1/MT-CONTROL/#{action}")
          |> put_req_header("origin", "http://127.0.0.1")
          |> put_req_header("x-aiur-request", "1")
          |> authed()
          |> call()

        assert json_response(conn, 405) == %{
                 "error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}
               }
      end
    end
  end

  test "GET /api/v1/state returns the full decision history by default" do
    install_decision_history!(51)

    conn = call(conn(:get, "/api/v1/state") |> authed())

    assert conn.status == 200
    payload = Jason.decode!(conn.resp_body)

    assert payload |> get_in(["decision_history", "entries"]) |> length() == 51
    refute Map.has_key?(payload, "rate_limits")

    case Map.get(payload, "agent_totals") do
      nil -> :ok
      totals -> assert Map.keys(totals) == ["seconds_running"]
    end

    for row <- Map.get(payload, "running", []) do
      refute Map.has_key?(row, "tokens")
    end
  end

  test "GET /api/v1/:issue_identifier/events returns a bounded durable feed" do
    original_log_file = Application.get_env(:aiur, :log_file)
    tmp = Aiur.TestSupport.tmp_root!("aiur-events-api")
    Application.put_env(:aiur, :log_file, Path.join(tmp, "log/aiur.log"))

    on_exit(fn ->
      if original_log_file, do: Application.put_env(:aiur, :log_file, original_log_file), else: Application.delete_env(:aiur, :log_file)
      File.rm_rf!(tmp)
    end)

    identifier = "events-api"
    path = IssueLog.transcript_path(identifier)
    File.mkdir_p!(Path.dirname(path))

    diff_event =
      Jason.encode!(%{
        "role" => "tool",
        "body" => "edit a.ex",
        "timestamp" => "2026-07-30T00:00:00Z",
        "payload" => %{"tool" => "edit", "changes" => [%{"path" => "a.ex", "diff" => "++x = 1\n-y = 2"}]}
      })

    message_event = Jason.encode!(%{"role" => "assistant", "body" => "ready", "timestamp" => "2026-07-30T00:00:01Z", "payload" => nil})

    File.write!(path, diff_event <> "\n" <> message_event <> "\n")

    conn = call(conn(:get, "/api/v1/#{identifier}/events?limit=1") |> authed())
    assert conn.status == 200
    assert %{"events" => [%{"badge" => "AGENT", "body" => "ready"}], "pagination" => %{"limit" => 1}} = Jason.decode!(conn.resp_body)

    all = call(conn(:get, "/api/v1/#{identifier}/events?limit=2") |> authed()) |> json_response(200)

    assert %{
             "events" => [
               %{"badge" => "AGENT", "body" => "ready"},
               %{"type" => "diff", "line" => "+x = 1", "signed_line" => "++x = 1"}
             ]
           } = all

    invalid = call(conn(:get, "/api/v1/#{identifier}/events?cursor=not-a-cursor") |> authed())
    assert invalid.status == 422
    assert Jason.decode!(invalid.resp_body)["error"]["code"] == "invalid_cursor"
  end

  test "GET /api/v1/streamdeck/grid returns the grid projection" do
    orchestrator = start_control_orchestrator()
    configure_endpoint(orchestrator)

    :ok =
      SnapshotStore.publish(orchestrator, %{
        running: [],
        retrying: [],
        idle: []
      })

    conn = call(conn(:get, "/api/v1/streamdeck/grid") |> authed())

    assert conn.status == 200

    assert %{
             "agents" => [],
             "agents_per_page" => 8,
             "columns_per_page" => 4,
             "max_column_offset" => 0,
             "rows_per_column" => 2,
             "snapshot_freshness" => %{"reason" => nil, "status" => "current"},
             "total" => 0,
             "windows" => 0
           } = Jason.decode!(conn.resp_body)
  end

  test "GET /api/v1/streamdeck/grid preserves the pre-first-snapshot error" do
    orchestrator = start_control_orchestrator()
    configure_endpoint(orchestrator)

    conn = call(conn(:get, "/api/v1/streamdeck/grid") |> authed())

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
           }
  end

  test "GET /api/v1/streamdeck/grid uses the sibling read auth pipeline" do
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    on_exit(fn ->
      config_change_if_running(dashboard_auth_required: false)
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    System.put_env("AIUR_DASHBOARD_USERNAME", "streamdeck-user")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "streamdeck-password")

    Application.put_env(
      :aiur,
      AiurWeb.Endpoint,
      Keyword.put(Application.get_env(:aiur, AiurWeb.Endpoint, []), :dashboard_auth_required, true)
    )

    AiurWeb.Endpoint.config_change([dashboard_auth_required: true], [])

    assert call(conn(:get, "/api/v1/streamdeck/grid")).status == 401

    authorized_conn =
      :get
      |> conn("/api/v1/streamdeck/grid")
      |> put_req_header("authorization", "Basic " <> Base.encode64("streamdeck-user:streamdeck-password"))
      |> call()

    assert authorized_conn.status == 200
  end

  defp install_decision_history!(count) do
    original_state = :sys.get_state(DecisionStore)

    on_exit(fn -> restore_decision_store(original_state) end)

    :sys.replace_state(DecisionStore, fn state ->
      Map.put(state, :audit_history, decision_histories(count))
    end)
  end

  defp restore_decision_store(original_state) do
    case Process.whereis(DecisionStore) do
      nil -> :ok
      _pid -> :sys.replace_state(DecisionStore, fn _state -> original_state end)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp decision_histories(count) do
    %{
      "dec-observability" =>
        Enum.map(1..count, fn version ->
          %{
            decision_id: "dec-observability",
            version: version,
            ticket: %{identifier: "1051", title: "Decision history", url: nil},
            source: %{agent_id: "agent-1", session_id: "session-1", event_id: nil},
            question: "Decision version #{version}?",
            created_at: DateTime.add(~U[2026-07-12 12:00:00Z], version, :second)
          }
        end)
    }
  end
end
