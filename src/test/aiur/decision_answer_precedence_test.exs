defmodule Aiur.DecisionAnswerPrecedenceTest do
  use ExUnit.Case, async: false
  alias Aiur.{Decision, DecisionStore}

  setup do
    dir = Aiur.TestSupport.tmp_root!("answer-precedence-6393")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    store =
      start_supervised!(
        {DecisionStore,
         name: nil,
         state_dir: dir,
         filesystem_sync_fun: fn -> :ok end,
         dispatch_delay_ms: 60_000,
         relay_enabled: fn -> true end,
         relay_notifier: fn _, _ -> :ok end,
         answer_comment_publisher: fn _ -> :ok end}
      )

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{
          question: "Proceed?",
          blocking: true,
          source_id: "precedence",
          authority: "supervisor_allowed",
          reversibility: "reversible",
          options: [%{id: "yes", label: "Proceed"}]
        },
        [ticket: %{identifier: "6393", title: "Precedence", url: nil}, source: %{agent_id: "agent", session_id: "session"}],
        store
      )

    %{store: store, decision: decision, dir: dir}
  end

  for operation <- [:supersede, :revise], winner <- [:operator, :operator_relayed], caller <- [:executor, :operator_relayed], winner == :operator or caller == :executor do
    test "#{operation}: #{caller} cannot replace #{winner}; journal stays unchanged", ctx do
      %{decision: decision, store: store, dir: dir} = ctx
      original = answer!(store, decision, unquote(winner))
      send(store, {:answer_comment_published, decision.decision_id, original.active_action_id})
      assert {:ok, _} = DecisionStore.get(decision.decision_id, store)
      before = File.read!(Path.join(dir, "decisions.ndjson"))
      conflict = if unquote(caller) == :operator_relayed, do: :direct_operator_answer, else: :human_answer
      id = original.active_action_id
      assert {:error, {:conflict, {^conflict, ^id}}} = replace(unquote(operation), store, original, unquote(caller))
      assert File.read!(Path.join(dir, "decisions.ndjson")) == before
      assert {:ok, unchanged} = DecisionStore.get(decision.decision_id, store)
      assert Decision.active_answer(unchanged) == Decision.active_answer(original)
    end
  end

  for {winner, caller} <- [{:executor, :executor}, {:operator_relayed, :operator}, {:operator_relayed, :operator_relayed}] do
    test "#{caller} can supersede #{winner} at equal or higher rank", %{store: store, decision: decision} do
      original = answer!(store, decision, unquote(winner))
      assert {:ok, %{status: :accepted, decision: replaced}} = replace(:supersede, store, original, unquote(caller))
      assert Decision.active_answer(replaced).actor.kind == unquote(caller)
      assert Decision.active_answer(replaced).actor.source == :device
    end
  end

  test "executor cannot replace the active operator revision", %{store: store, decision: decision} do
    original = answer!(store, decision, :executor)
    assert {:ok, %{decision: revised}} = replace(:supersede, store, original, :operator)
    id = revised.active_action_id
    assert {:error, {:conflict, {:human_answer, ^id}}} = replace(:supersede, store, revised, :executor)
  end

  test "source is trusted opts only, defaults to rpc and survives restart", %{store: store, decision: decision, dir: dir} do
    raw = Map.merge(payload(:operator, "first"), %{actor_source: "dashboard_session", actor: %{source: "device"}})
    assert {:ok, %{decision: answered}} = DecisionStore.answer(decision.decision_id, raw, [actor: %{kind: :operator, id: "human", source: :device}], store)
    assert answered.answer.actor.source == :rpc
    assert Aiur.Commands.ConflictSummary.for(answered, %{kind: :executor}).actor_source == :rpc
    assert {:ok, %{decision: revised}} = replace(:supersede, store, answered, :operator)
    assert Decision.active_answer(revised).actor.source == :device
    stop_supervised!(DecisionStore)
    restarted = start_supervised!({DecisionStore, name: nil, state_dir: dir, dispatch_delay_ms: 60_000})
    assert {:ok, durable} = DecisionStore.get(decision.decision_id, restarted)
    assert durable.answer.actor.source == :rpc
    assert Decision.active_answer(durable).actor.source == :device
  end

  test "unknown source opts fall back to rpc", %{store: store, decision: decision} do
    assert {:ok, %{action: action}} = DecisionStore.answer(decision.decision_id, payload(:operator, "unknown"), [actor: %{kind: :operator, id: "human"}, actor_source: :unrecognized], store)
    assert action.actor.source == :rpc
  end

  defp answer!(store, decision, kind) do
    {:ok, %{decision: answered}} = DecisionStore.answer(decision.decision_id, payload(kind, "first"), [actor: actor(kind)], store)
    answered
  end

  defp replace(operation, store, decision, kind) do
    raw =
      payload(kind, "replacement-#{decision.revision_sequence}")
      |> Map.merge(%{expected_action_id: decision.active_action_id, expected_revision_sequence: decision.revision_sequence, rationale: "Correct answer"})

    apply(DecisionStore, operation, [decision.decision_id, raw, [actor: actor(kind), actor_source: :device], store])
  end

  defp actor(kind), do: %{kind: kind, id: "caller"}

  defp payload(kind, key) do
    base = %{expected_version: 1, option_id: "yes", idempotency_key: key}
    if kind == :operator_relayed, do: Map.merge(base, %{operator_quote: "Proceed", relayed_by: "caller"}), else: base
  end
end
