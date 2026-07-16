defmodule AiurWeb.ObservabilityApiControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.Claude.HookEvents
  alias Aiur.DecisionStore

  # api_write endpoints require a loopback Origin + the X-Aiur-Request header.
  defp hook_conn(identifier, payload) do
    :post
    |> conn("/api/v1/#{identifier}/claude-hook", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("origin", "http://127.0.0.1")
    |> put_req_header("x-aiur-request", "1")
  end

  defp call(conn), do: AiurWeb.Endpoint.call(conn, AiurWeb.Endpoint.init([]))

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
    end)

    :ok
  end

  defp restore_runtime_config(key, previous_value, missing) do
    if Process.whereis(AiurWeb.Endpoint) do
      if previous_value == missing do
        AiurWeb.Endpoint.config_change([], [key])
      else
        AiurWeb.Endpoint.config_change([{key, previous_value}], [])
      end
    end
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
