defmodule Aiur.Commands.AnsweringFacadeTest do
  use ExUnit.Case, async: false
  alias Aiur.Commands.Answering
  alias Aiur.{Decision, DecisionStore}

  setup do
    dir = Aiur.TestSupport.tmp_root!("answering-facade-6398")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    store = start_supervised!({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000, answer_comment_publisher: fn _ -> :ok end})

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{question: "Proceed?", blocking: true, source_id: "facade", authority: "supervisor_allowed", reversibility: "reversible", options: [%{id: "yes", label: "Proceed"}]},
        [ticket: %{identifier: "6398", title: "Facade", url: nil}, source: %{agent_id: "agent", session_id: "session"}],
        store
      )

    %{store: store, decision: decision}
  end

  test "operator acceptance persists device attribution and retries are duplicate", ctx do
    opts = opts(ctx) ++ [client: %{surface: :phone, device_id: "first"}]
    assert %{status: :accepted, delivery: :pending, decision: accepted} = Answering.answer(ctx.decision.decision_id, payload(), opts)
    assert Decision.active_answer(accepted).actor == %{kind: :operator, id: "device:first", source: :device}
    assert %{status: :duplicate, decision: duplicate} = Answering.answer(ctx.decision.decision_id, payload(), opts)
    assert duplicate.active_action_id == accepted.active_action_id
    other_device = Keyword.put(opts, :client, %{surface: :watch, device_id: "second"})
    assert %{status: :duplicate, decision: retried} = Answering.answer(ctx.decision.decision_id, payload(), other_device)
    assert Decision.active_answer(retried).actor.id == "device:first"

    assert %{status: :error, reason: {:conflict, {:idempotency_conflict, _}}} =
             Answering.answer(ctx.decision.decision_id, %{payload() | custom_response: "Changed"}, other_device)
  end

  test "another device receives the actual winner and entry point", ctx do
    first = Keyword.put(opts(ctx), :actor_source, :dashboard_session) ++ [client: %{surface: :dashboard}]
    assert %{status: :accepted} = Answering.answer(ctx.decision.decision_id, payload(), first)
    assert %{status: :already_answered, winner: winner} = Answering.answer(ctx.decision.decision_id, payload("second"), opts(ctx))
    assert winner.actor_id == "dashboard"
    assert winner.actor_source == :dashboard_session
    assert winner.replaceable
  end

  test "operator supersedes executor answer and retries supersede", ctx do
    assert {:ok, _} = DecisionStore.answer(ctx.decision.decision_id, payload(), [actor: %{kind: :executor, id: "executor"}], ctx.store)

    assert %{status: :already_answered, winner: %{replaceable: true, actor_kind: :executor}} =
             Answering.answer(ctx.decision.decision_id, payload("human"), opts(ctx))

    assert %{status: :accepted, decision: replaced} = Answering.supersede(ctx.decision.decision_id, payload("human"), opts(ctx))
    assert Decision.active_answer(replaced).actor.kind == :operator
    assert Decision.active_answer(replaced).custom_response == "Proceed"
    assert %{status: :duplicate} = Answering.supersede(ctx.decision.decision_id, payload("human"), opts(ctx))
  end

  test "supersede answers an unanswered command", ctx do
    assert %{status: :accepted, decision: accepted} = Answering.supersede(ctx.decision.decision_id, payload(), opts(ctx))
    assert accepted.answer.actor.kind == :operator
    assert accepted.revisions == []
  end

  test "non-direct actors cannot use human surfaces or supersede", ctx do
    for kind <- [:executor, :operator_relayed, :supervisor, :agent, :system] do
      opts = Keyword.put(opts(ctx), :actor, %{kind: kind, id: "actor"})
      assert Answering.answer(ctx.decision.decision_id, payload(), opts) == %{status: :not_allowed, reason: :invalid_actor}

      assert Answering.supersede(ctx.decision.decision_id, payload(), opts ++ [client: %{surface: :cli}]) ==
               %{status: :not_allowed, reason: :invalid_actor}
    end

    assert {:ok, %{answer: nil}} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
  end

  test "cli executor can answer while scope errors remain normalized", ctx do
    opts = Keyword.put(opts(ctx), :actor, %{kind: :executor, id: "executor"}) ++ [client: %{surface: :cli}]
    assert %{status: :accepted} = Answering.answer(ctx.decision.decision_id, payload(), opts)

    assert Answering.outcome({:error, {:answer_invalid, {:executor_scope, {:authority, :human_required}}}}, opts) ==
             %{status: :not_allowed, reason: :executor_scope}
  end

  test "source is required before store access", _ctx do
    assert_raise ArgumentError, "actor_source is required", fn ->
      Answering.answer("unknown", payload(), actor: %{kind: :operator, id: "human"}, store: :no_such_store)
    end
  end

  test "store exits including conflict reads normalize to unavailable", ctx do
    opts = Keyword.put(opts(ctx), :store, :no_such_store)
    assert Answering.answer("unknown", payload(), opts) == %{status: :error, reason: :store_unavailable}

    assert Answering.outcome({:error, {:conflict, {:already_decided, "action"}}}, opts ++ [decision_id: "unknown"]) ==
             %{status: :error, reason: :store_unavailable}
  end

  test "stale, withdrawn, policy and generic errors normalize", ctx do
    assert Answering.answer(ctx.decision.decision_id, %{payload() | expected_version: 2}, opts(ctx)) == %{status: :stale, current_version: 1}

    for status <- [:expired, :moot, :resolved, :dismissed] do
      assert Answering.outcome({:error, {:conflict, status}}, []) == %{status: :withdrawn, reason: status}
    end

    assert Answering.outcome({:error, :not_found}, []) == %{status: :error, reason: :not_found}

    for reason <- [:human_answer, :direct_operator_answer] do
      assert Answering.outcome({:error, {:conflict, {reason, "action"}}}, []) == %{status: :not_allowed, reason: reason}
    end
  end

  test "supersede is too late after handoff and delivery", ctx do
    assert %{status: :accepted, decision: decision} = Answering.answer(ctx.decision.decision_id, payload(), opts(ctx))

    item = %{
      id: 1,
      target_issue_identifier: decision.ticket.identifier,
      action_id: decision.active_action_id,
      correlation: %{decision_id: decision.decision_id, decision_version: decision.version, action_id: decision.active_action_id, attempt_id: "attempt"}
    }

    assert {:ok, :accepted} = DecisionStore.validate_delivery(item, ctx.store)

    assert %{status: :too_late, reason: :answer_in_flight, winner: %{in_flight?: true, replaceable: false}} =
             Answering.supersede(decision.decision_id, payload("late"), opts(ctx))

    assert {:ok, :accepted} = DecisionStore.record_delivery(item, ctx.store)

    assert %{status: :too_late, reason: :answer_delivered, winner: %{delivered?: true, replaceable: false}} =
             Answering.supersede(decision.decision_id, payload("later"), opts(ctx))
  end

  test "dismissed commands stay withdrawn when answered through the facade", ctx do
    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{question: "Optional choice?", blocking: false, source_id: "dismissed"},
        [ticket: %{identifier: "6398", title: "Facade", url: nil}, source: %{agent_id: "agent", session_id: "session"}],
        ctx.store
      )

    assert {:ok, _dismissed} = DecisionStore.dismiss(decision.decision_id, [actor: %{kind: :operator, id: "human"}], ctx.store)
    assert Answering.answer(decision.decision_id, payload(), opts(ctx)) == %{status: :withdrawn, reason: :dismissed}
    assert {:ok, %{answer: nil, decision_status: :dismissed}} = DecisionStore.get(decision.decision_id, ctx.store)
  end

  test "too-late mappings preserve winner and delivery evidence", ctx do
    assert %{status: :accepted, decision: decision} = Answering.answer(ctx.decision.decision_id, payload(), opts(ctx))

    for reason <- [:answer_delivered, :answer_in_flight] do
      assert %{status: :too_late, reason: ^reason, winner: %{actor_id: "human"}} =
               Answering.outcome({:error, {:conflict, reason}}, opts(ctx) ++ [decision_id: decision.decision_id])
    end

    for status <- [:consumed, :delivered] do
      assert %{delivery: :delivered} = Answering.outcome({:ok, %{status: :duplicate, decision: %{decision | delivery_status: status}}}, [])
    end

    assert %{delivery: :queued_for_restart} =
             Answering.outcome({:ok, %{status: :accepted, decision: %{decision | pending_for_session?: true}}}, [])
  end

  defp opts(ctx), do: [actor: %{kind: :operator, id: "human"}, actor_source: :device, store: ctx.store]
  defp payload(key \\ "answer"), do: %{expected_version: 1, idempotency_key: key, custom_response: "Proceed", rationale: "Operator choice"}
end
