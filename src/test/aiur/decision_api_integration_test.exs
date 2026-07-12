defmodule Aiur.DecisionApiIntegrationTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.{DecisionEvent, DecisionStore}
  alias AiurWeb.Endpoint

  @token String.duplicate("t", 32)
  @actor %{kind: :supervisor, id: "supervising-agent"}
  @policy %{allowed_kinds: ["architecture"], allow_non_reversible: false}
  @ticket %{identifier: "984", title: "OCC-7", url: "https://github.com/its-everdred/aiur/issues/984"}
  @source %{agent_id: "agent-984", session_id: "session-984", event_id: nil}

  setup do
    original_dir = Application.get_env(:aiur, :decision_state_dir)
    original_token = System.get_env("AIUR_SUPERVISOR_TOKEN")
    dir = Path.join(System.tmp_dir!(), "aiur-decision-api-integration-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :decision_state_dir, dir)
    System.put_env("AIUR_SUPERVISOR_TOKEN", @token)
    ensure_endpoint_running()

    parent = self()

    dispatcher = fn decision, opts ->
      send(parent, {:dispatch_observed, DecisionStore.audit_history(decision.decision_id, opts[:store])})
      {:ok, %{status: :accepted, item: %{id: 984}}}
    end

    {:ok, store} =
      DecisionStore.start_link(
        name: nil,
        filesystem_sync_fun: fn -> :ok end,
        dispatcher: dispatcher,
        dispatch_delay_ms: 0
      )

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)
      restore_env("AIUR_SUPERVISOR_TOKEN", original_token)

      case original_dir do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir, store: store}
  end

  test "authenticated enrichment and delegated answer share one durable lifecycle", %{dir: dir, store: store} do
    assert {:ok, %{decision: requested}} =
             DecisionStore.request(
               %{
                 "source_id" => "http-integration",
                 "question" => "Which architecture should proceed?",
                 "blocking" => true,
                 "kind" => "architecture",
                 "authority" => "supervisor_allowed",
                 "reversibility" => "reversible",
                 "options" => [%{"id" => "ship", "label" => "Ship"}]
               },
               [ticket: @ticket, source: @source, now: ~U[2026-07-12 10:00:00Z]],
               store
             )

    list = request(:get, "/api/v1/decisions", nil, store)
    assert list.status == 200
    assert Enum.any?(Jason.decode!(list.resp_body)["decisions"], &(&1["decision_id"] == requested.decision_id))

    enrich =
      request(
        :post,
        "/api/v1/decisions/#{requested.decision_id}/enrich",
        %{
          "expected_version" => 1,
          "context" => %{"short_summary" => "One canonical lifecycle"}
        },
        store
      )

    assert enrich.status == 202
    assert Jason.decode!(enrich.resp_body)["decision"]["version"] == 2

    secret = "ghp_" <> String.duplicate("A", 36)

    decision_payload = %{
      "idempotency_key" => "http-supervisor-answer",
      "expected_version" => 2,
      "option_id" => "ship",
      "rationale" => "Proceed after checking #{secret}",
      "confidence" => 93,
      "alternatives_considered" => ["Wait for another review"],
      "reversibility_belief" => "reversible"
    }

    decided =
      request(
        :post,
        "/api/v1/decisions/#{requested.decision_id}/decide",
        decision_payload,
        store
      )

    assert decided.status == 202
    decided_body = Jason.decode!(decided.resp_body)
    refute decided.resp_body =~ secret
    assert decided_body["status"] == "accepted"
    assert decided_body["action"]["actor"] == %{"kind" => "supervisor", "id" => "supervising-agent"}
    assert decided_body["action"]["supervisor_basis"]["confidence"] == 93

    assert_receive {:dispatch_observed, {:ok, audit}}, 1_000
    assert Enum.map(audit, &audit_type/1) == [:requested, :enriched, :answer_recorded]

    replay =
      request(
        :post,
        "/api/v1/decisions/#{requested.decision_id}/decide",
        decision_payload,
        store
      )

    assert replay.status == 200
    assert Jason.decode!(replay.resp_body)["status"] == "duplicate"

    assert {:ok, final_audit} = DecisionStore.audit_history(requested.decision_id, store)
    assert Enum.count(final_audit, &match?(%DecisionEvent{type: :answer_recorded}, &1)) == 1

    persisted = File.read!(Path.join(dir, "decisions.ndjson"))
    refute persisted =~ @token
    refute persisted =~ secret
    assert persisted =~ "[REDACTED:ghp]"
  end

  test "authenticated revision reaches only the injected OCC-8 boundary", %{store: store} do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "source_id" => "revision-integration",
                 "question" => "Which architecture should proceed?",
                 "blocking" => true,
                 "kind" => "architecture",
                 "authority" => "supervisor_allowed",
                 "reversibility" => "reversible"
               },
               [ticket: @ticket, source: @source],
               store
             )

    parent = self()

    revision_service = fn decision_id, payload, opts ->
      send(parent, {:revision_service_called, decision_id, payload, opts})
      {:ok, %{"status" => "recorded", "revision_action_id" => "rev_http"}}
    end

    payload = %{
      "expected_version" => 1,
      "expected_action_id" => "act_original",
      "expected_revision_sequence" => 0,
      "idempotency_key" => "http-revision",
      "custom_response" => "Corrected direction",
      "reason" => "New evidence"
    }

    response =
      request(
        :post,
        "/api/v1/decisions/#{decision.decision_id}/revise",
        payload,
        store,
        revision_service: revision_service
      )

    assert response.status == 202
    assert Jason.decode!(response.resp_body)["status"] == "recorded"
    assert_receive {:revision_service_called, decision_id, ^payload, opts}
    assert decision_id == decision.decision_id
    assert opts[:actor] == @actor
    assert opts[:authority] == :supervisor_allowed

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.map(audit, &audit_type/1) == [:requested]
  end

  defp request(method, path, body, store, extra_opts \\ []) do
    conn =
      if is_nil(body) do
        conn(method, path)
      else
        method
        |> conn(path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      end

    api_opts =
      [store: store, policy: @policy]
      |> Keyword.merge(extra_opts)

    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> maybe_put_mutation_headers(method)
    |> put_private(:decision_api_opts, api_opts)
    |> put_private(:dashboard_writable, true)
    |> Endpoint.call(Endpoint.init([]))
  end

  defp maybe_put_mutation_headers(conn, method) when method in [:post, :put, :patch, :delete] do
    conn
    |> put_req_header("origin", "http://localhost")
    |> put_req_header("x-aiur-request", "1")
  end

  defp maybe_put_mutation_headers(conn, _method), do: conn

  defp ensure_endpoint_running do
    if is_nil(Process.whereis(Endpoint)) do
      endpoint_config = Application.get_env(:aiur, Endpoint, [])

      Application.put_env(
        :aiur,
        Endpoint,
        Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64))
      )

      start_supervised!({Endpoint, []})
      on_exit(fn -> Application.put_env(:aiur, Endpoint, endpoint_config) end)
    end
  end

  defp audit_type(%DecisionEvent{type: type}), do: type
  defp audit_type(%Aiur.Decision{}), do: :requested

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
