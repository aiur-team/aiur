defmodule Aiur.DecisionRoutingQueryTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionQuery, DecisionStore}

  setup do
    dir = Aiur.TestSupport.tmp_root!("decision-routing-query")
    {:ok, store} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{store: store, now: DateTime.utc_now()}
  end

  test "route filters and counts track durable routing, escalation and resolution", %{store: store, now: now} do
    human = request(store, "human", now)
    both = request(store, "both", now)
    executor = request(store, "executor", now)
    legacy = request(store, "legacy", now)
    route(store, human, :with_human, now)
    route(store, both, :with_both, now)
    route(store, executor, :with_executor, now)

    assert ids(store, "needs_you") == Enum.sort([human.decision_id, both.decision_id])
    assert ids(store, "with_executor") == [executor.decision_id]
    assert ids(store, "from_executor") == []
    assert {:ok, counts} = DecisionQuery.counts(store: store)
    assert {counts.needs_you, counts.needs_you_blocking, counts.open, counts.with_executor} == {2, 2, 4, 1}
    assert counts.needs_you_by_ticket == %{"6411" => 2}
    assert {:ok, page} = DecisionQuery.list(%{route: "needs_you", limit: 1}, store: store)
    assert length(page.decisions) == 1
    assert {:ok, next} = DecisionQuery.list(%{route: "needs_you", limit: 1, cursor: page.pagination.next_cursor}, store: store)
    assert Enum.sort(Enum.map(page.decisions ++ next.decisions, & &1.decision_id)) == ids(store, "needs_you")
    refute legacy.decision_id in ids(store, "needs_you")

    at = DateTime.add(now, 60, :second)

    assert {:ok, _} =
             DecisionStore.record_command_fact(
               executor.decision_id,
               :escalated,
               %{cause: :executor_ack_timeout, at: at, detail: "Executor did not acknowledge", actor: %{kind: :system, id: "routing"}}, server: store)

    assert {:ok, counts} = DecisionQuery.counts(store: store)
    assert counts.needs_you == 3
    assert counts.with_executor == 0

    assert {:ok, _} =
             DecisionStore.answer(human.decision_id, %{"idempotency_key" => "answer-human", "expected_version" => 1, "custom_response" => "Proceed"}, [actor: %{kind: :operator, id: "test"}], store)

    assert ids(store, "needs_you") == Enum.sort([both.decision_id, executor.decision_id])
    assert ids(store, "resolved") == [human.decision_id]
    assert {:ok, counts} = DecisionQuery.counts(store: store)
    assert counts.needs_you == 2
    assert counts.needs_you_by_ticket == %{"6411" => 2}
  end

  test "Executor attribution is filterable through retained reads", %{store: store, now: now} do
    decision = request(store, "from-executor", now, requester: %{kind: :executor, executor_id: "exec"})
    route(store, decision, :with_human, now)
    assert ids(store, "from_executor") == [decision.decision_id]
    assert {:ok, counts} = DecisionQuery.counts(store: store)
    assert counts.from_executor == 1
  end

  test "unavailable counts preserve unknown needs-you counts" do
    assert {:ok, counts} = DecisionQuery.counts(store: :missing_routing_test_store)
    assert counts.needs_you == nil
    assert counts.needs_you_by_ticket == nil
    assert counts.health.status == :unavailable
  end

  test "invalid route inputs are rejected", %{store: store} do
    assert {:error, {:invalid_query, {:route, :invalid}}} = DecisionQuery.list(%{route: "guess"}, store: store)
  end

  defp ids(store, route) do
    assert {:ok, page} = DecisionQuery.list(%{route: route}, store: store)
    Enum.sort(Enum.map(page.decisions, & &1.decision_id))
  end

  defp request(store, id, now, extra \\ []) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{"source_id" => id, "question" => "Should #{id} proceed?", "blocking" => true, "reversibility" => "reversible"},
               Keyword.merge([ticket: %{identifier: "6411", title: "Routing", url: nil}, source: %{agent_id: "agent", session_id: "session", event_id: id}, now: now], extra),
               store
             )

    decision
  end

  defp route(store, decision, state, now) do
    policy = %{with_human: :human_only, with_both: :simultaneous, with_executor: :executor_first}[state]
    assert {:ok, _} = DecisionStore.record_command_fact(decision.decision_id, :routed, %{policy: policy, state: state, cause: nil, at: now, actor: %{kind: :system, id: "routing"}}, server: store)
  end
end
