defmodule Aiur.DecisionApiIntegrationTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.{Decision, DecisionEvent, DecisionStore}
  alias AiurWeb.Endpoint

  @token String.duplicate("t", 32)
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
    configure_endpoint(dashboard_writable: true)

    parent = self()

    dispatcher = fn decision, opts ->
      action = Decision.active_answer(decision)

      send(
        parent,
        {:dispatch_observed, action.action_id, DecisionStore.audit_history(decision.decision_id, opts[:store])}
      )

      {:ok, %{status: :accepted, item: %{id: 984}}}
    end

    {:ok, store} =
      DecisionStore.start_link(
        name: nil,
        state_dir: dir,
        filesystem_sync_fun: fn -> :ok end,
        dispatcher: dispatcher,
        dispatch_delay_ms: 0
      )

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)
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

    assert_receive {:dispatch_observed, action_id, {:ok, audit}}, 1_000
    assert action_id == decided_body["action"]["action_id"]
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

  test "authenticated revision uses OCC-8 persistence, correlation, and trusted supervisor basis", %{store: store} do
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

    assert {:ok, %{action: original}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "expected_version" => 1,
                 "idempotency_key" => "revision-original",
                 "custom_response" => "Original direction",
                 "rationale" => "Initial evidence"
               },
               [actor: %{kind: :operator, id: "operator-1"}],
               store
             )

    assert_receive {:dispatch_observed, original_action_id, {:ok, original_audit}}, 1_000
    assert original_action_id == original.action_id
    assert Enum.map(original_audit, &audit_type/1) == [:requested, :answer_recorded]

    payload = %{
      "expected_version" => 1,
      "expected_action_id" => original.action_id,
      "expected_revision_sequence" => 0,
      "idempotency_key" => "http-revision",
      "custom_response" => "Corrected direction",
      "rationale" => "New evidence",
      "confidence" => 89,
      "alternatives_considered" => ["Keep the original direction"],
      "reversibility_belief" => "reversible"
    }

    response =
      request(
        :post,
        "/api/v1/decisions/#{decision.decision_id}/revise",
        payload,
        store
      )

    assert response.status == 202
    body = Jason.decode!(response.resp_body)
    assert body["status"] == "accepted"
    assert body["revision_result"] == "recorded"
    assert body["action"]["prior_action_id"] == original.action_id
    assert body["action"]["answer"]["actor"] == %{"kind" => "supervisor", "id" => "supervising-agent"}
    assert body["action"]["answer"]["supervisor_basis"]["confidence"] == 89

    revision_action_id = body["action"]["action_id"]

    assert_receive {:dispatch_observed, ^revision_action_id, {:ok, revision_audit}}, 1_000
    assert :revision_recorded in Enum.map(revision_audit, &audit_type/1)

    replay =
      request(
        :post,
        "/api/v1/decisions/#{decision.decision_id}/revise",
        payload,
        store
      )

    assert replay.status == 200
    assert Jason.decode!(replay.resp_body)["status"] == "duplicate"

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(audit, &match?(%DecisionEvent{type: :revision_recorded}, &1)) == 1
  end

  defp request(method, path, body, store) do
    conn =
      if is_nil(body) do
        conn(method, path)
      else
        method
        |> conn(path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> maybe_put_mutation_headers(method)
    |> put_private(:decision_api_opts, store: store, policy: @policy)
    |> Endpoint.call(Endpoint.init([]))
  end

  defp maybe_put_mutation_headers(conn, method) when method in [:post, :put, :patch, :delete] do
    conn
    |> put_req_header("origin", "http://localhost")
    |> put_req_header("x-aiur-request", "1")
  end

  defp maybe_put_mutation_headers(conn, _method), do: conn

  # This test always starts and owns its own `AiurWeb.Endpoint`, so it never
  # depends on another test's process. `start_supervised/1` (not `!`) returns
  # `{:error, {:already_started, pid}}` when a prior test's `start_supervised!`
  # endpoint is still registered while its ExUnit supervisor tears it down
  # (#2288): the registered name can outlive the endpoint's config ETS table
  # for a short window, and relying on that pid would hit a missing table
  # mid-test (`Endpoint.call/2` raising `ArgumentError`). Instead of betting on
  # a wall-clock grace window, wait deterministically for the dying endpoint's
  # DOWN (guaranteed to arrive — it is mid-teardown) and then start our own.
  defp ensure_endpoint_running do
    endpoint_config = Application.get_env(:aiur, Endpoint, [])

    Application.put_env(
      :aiur,
      Endpoint,
      Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64))
    )

    {:ok, _pid} = start_owned_endpoint()

    on_exit(fn -> Application.put_env(:aiur, Endpoint, endpoint_config) end)
    true
  end

  defp start_owned_endpoint do
    case start_supervised({Endpoint, []}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> start_owned_endpoint()
        end

      {:error, reason} ->
        raise "failed to start AiurWeb.Endpoint under the test supervisor: #{inspect(reason)}"
    end
  end

  defp configure_endpoint(changed) do
    Endpoint.config_change(%{Endpoint => changed}, [])
  end

  defp audit_type(%DecisionEvent{type: type}), do: type
  defp audit_type(%Aiur.Decision{}), do: :requested

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
