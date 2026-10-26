defmodule AiurWeb.DecisionAnswerPrecedenceTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.{Decision, DecisionApi, DecisionStore}
  alias AiurWeb.DecisionApiController

  @actor %{kind: :supervisor, id: "supervising-agent"}
  @policy %{allowed_kinds: ["architecture"], allow_non_reversible: false}

  setup_all do: :ok = Aiur.TestSupport.ensure_runtime_children_running()

  setup do
    dir = Aiur.TestSupport.tmp_root!("answer-precedence-api")
    store = start_supervised!({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end})
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{"blocking" => true, "source_id" => "api-precedence", "question" => "Choose a path?", "kind" => "architecture", "authority" => "supervisor_allowed", "reversibility" => "reversible"},
        [ticket: %{identifier: "6393", title: "Precedence", url: "https://example.test/6393"}, source: %{agent_id: "agent-1", session_id: "session-1", event_id: nil}],
        store
      )

    %{store: store, decision: decision}
  end

  test "409 already_decided carries the actual operator winner", %{store: store, decision: decision} do
    assert {:ok, %{action: answer}} =
             DecisionStore.answer(decision.decision_id, answer_payload("operator"), [actor: %{kind: :operator, id: "human-1"}, actor_source: :dashboard_session], store)

    response = DecisionApiController.decide(api_conn(store), %{"decision_id" => decision.decision_id} |> Map.merge(supervisor_payload()))
    body = Jason.decode!(response.resp_body)

    assert response.status == 409
    assert body["error"]["code"] == "decision_conflict"
    assert body["winner"]["actor_kind"] == "operator"
    assert body["winner"]["actor_id"] == "human-1"
    assert body["winner"]["actor_source"] == "dashboard_session"
    assert body["winner"]["summary"] == "Use the safe path"
    assert body["winner"]["accepted_at"] == DateTime.to_iso8601(answer.accepted_at)
    assert body["winner"]["replaceable"] == false
  end

  test "supervisor API revision cannot replace an operator answer", %{store: store, decision: decision} do
    assert {:ok, %{action: original}} =
             DecisionStore.answer(decision.decision_id, answer_payload("operator"), [actor: %{kind: :operator, id: "human-1"}], store)

    payload =
      supervisor_payload()
      |> Map.put("expected_action_id", original.action_id)
      |> Map.put("expected_revision_sequence", 0)

    assert {:error, {:conflict, {:human_answer, action_id}}} =
             DecisionApi.revise(decision.decision_id, payload, actor: @actor, policy: @policy, store: store)

    assert action_id == original.action_id
    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert Decision.active_answer(current) == original
  end

  test "API answers and revisions record supervisor_api as the trusted source", %{store: store, decision: decision} do
    opts = [actor: @actor, policy: @policy, store: store, actor_source: :dashboard_session]
    assert {:ok, _answered} = DecisionApi.decide(decision.decision_id, supervisor_payload(), opts)
    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert Decision.active_answer(current).actor.source == :supervisor_api

    payload =
      supervisor_payload()
      |> Map.put("idempotency_key", "revision")
      |> Map.put("expected_action_id", current.active_action_id)
      |> Map.put("expected_revision_sequence", 0)
      |> Map.put("custom_response", "Use the revised path")

    assert {:ok, _revised} = DecisionApi.revise(decision.decision_id, payload, opts)
    assert {:ok, revised} = DecisionStore.get(decision.decision_id, store)
    assert Decision.active_answer(revised).actor.source == :supervisor_api
  end

  defmodule UnavailableWinnerApi do
    def decide(_id, _payload, _opts), do: {:error, {:conflict, {:already_decided, "answer-1"}}}
  end

  # Future regression guard: the pre-existing generic conflict handler also returns 409.
  test "future regression guard: winner read failure preserves 409 without a winner" do
    response =
      api_conn(:unavailable_store)
      |> put_private(:decision_api, UnavailableWinnerApi)
      |> DecisionApiController.decide(%{"decision_id" => "decision-1"})

    assert response.status == 409
    assert Jason.decode!(response.resp_body) == %{"error" => %{"code" => "decision_conflict", "message" => "Decision state changed; refresh and retry"}}
  end

  defp api_conn(store) do
    conn(:post, "/")
    |> assign(:decision_actor, @actor)
    |> put_private(:decision_api_opts, store: store, policy: @policy)
  end

  defp answer_payload(key) do
    %{"expected_version" => 1, "idempotency_key" => key, "custom_response" => "Use the safe path", "rationale" => "Known evidence"}
  end

  defp supervisor_payload do
    answer_payload("supervisor")
    |> Map.merge(%{"confidence" => 90, "alternatives_considered" => ["Wait"], "reversibility_belief" => "reversible"})
  end
end
