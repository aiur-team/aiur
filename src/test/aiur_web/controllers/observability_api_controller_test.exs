defmodule AiurWeb.ObservabilityApiControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.Claude.HookEvents
  alias Aiur.DecisionStore

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

  # api_write endpoints require a loopback Origin + the X-Aiur-Request header.
  defp hook_conn(identifier, payload) do
    :post
    |> conn("/api/v1/#{identifier}/claude-hook", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("origin", "http://127.0.0.1")
    |> put_req_header("x-aiur-request", "1")
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

    if is_nil(Process.whereis(AiurWeb.Endpoint)) do
      start_supervised!({AiurWeb.Endpoint, []})
    else
      AiurWeb.Endpoint.config_change([dashboard_auth_required: false], [])
    end

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

  defp control_conn(identifier, action) do
    :post
    |> conn("/api/v1/#{identifier}/#{action}")
    |> put_req_header("origin", "http://127.0.0.1")
    |> put_req_header("x-aiur-request", "1")
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
          |> call()

        assert json_response(conn, 405) == %{
                 "error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}
               }
      end
    end
  end

  test "GET /api/v1/state returns the full decision history by default" do
    install_decision_history!(51)

    conn = call(conn(:get, "/api/v1/state"))

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

  test "GET /api/v1/streamdeck/grid returns the grid projection" do
    conn = call(conn(:get, "/api/v1/streamdeck/grid"))

    assert conn.status == 200

    payload = Jason.decode!(conn.resp_body)

    assert is_list(payload["agents"])
    assert is_integer(payload["total"])
    assert payload["columns_per_page"] == 4
    assert payload["rows_per_column"] == 2
    assert payload["agents_per_page"] == 8
  end

  test "GET /api/v1/streamdeck/grid uses the sibling read auth pipeline" do
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    on_exit(fn ->
      AiurWeb.Endpoint.config_change([dashboard_auth_required: false], [])
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    System.put_env("AIUR_DASHBOARD_USERNAME", "streamdeck-user")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "streamdeck-password")
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
