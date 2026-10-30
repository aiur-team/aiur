defmodule Aiur.DecisionCorrectiveRetargetTest do
  use ExUnit.Case, async: false

  alias Aiur.{Commands, DecisionPubSub, DecisionStore}
  alias Aiur.DecisionStore.{Dispatch, Retry}
  alias Aiur.Orchestrator.Dispatcher.AnsweredDecisions

  test "a corrective link replaces an original terminal outcome, resolves its follow-up and replays as dispatchable" do
    ctx = fixture({:no_longer_applicable, {:terminal, "done"}})
    send(ctx.store, {:dispatch_action, Dispatch.dispatch_fence(ctx.decision), false})
    action = ctx.decision.active_action_id
    assert_receive {:effective_dispatch, "42"}, 2_000
    terminal = await(ctx.store, ctx.decision.decision_id, &(&1.revision_result == :no_longer_applicable and is_map(&1.revision_follow_ups[action])))
    assert terminal.revision_follow_ups[action].handled_at == nil
    refute Retry.dispatchable?(terminal, false)

    release_lookup(ctx)
    assert_receive {:follow_up_resolved, ^action}, 2_000
    linked = await(ctx.store, terminal.decision_id, &match?(%{handled_at: %DateTime{}}, &1.revision_follow_ups[action]))
    assert linked.revision_result == :recorded
    assert linked.revision_outcomes[action].result == :recorded
    assert linked.delivery_status == :pending
    refute linked.pending_for_session?
    assert Retry.dispatchable?(linked, false)
    assert [%{action_id: ^action, answer: "correction"}] = AnsweredDecisions.for_ticket("43", ctx.store, 1_000)
    assert [] == AnsweredDecisions.for_ticket("42", ctx.store, 1_000)
    assert {:ok, history} = DecisionStore.audit_history(linked.decision_id, ctx.store)
    assert Enum.any?(history, &(&1.type == :revision_no_longer_applicable))
    assert Enum.any?(history, &(&1.type == :follow_up_handled))

    stop_supervised!(DecisionStore)
    store = start_supervised!({DecisionStore, ctx.opts})
    assert {:ok, replayed} = DecisionStore.get(linked.decision_id, store)
    assert replayed.revision_result == :recorded
    assert replayed.revision_follow_ups[action].handled_at == linked.revision_follow_ups[action].handled_at
    assert Retry.dispatchable?(replayed, false)
    send(store, {:dispatch_action, Dispatch.dispatch_fence(replayed), false})
    assert_receive {:effective_dispatch, "43"}, 2_000
    queued = await(store, linked.decision_id, &(&1.delivery_status == :queued))
    assert queued.revision_result == :dispatched
  end

  test "a corrective link clears an original worker's pending-session hold" do
    ctx = fixture({:error, :no_running_agent})
    send(ctx.store, {:dispatch_action, Dispatch.dispatch_fence(ctx.decision), false})
    assert_receive {:effective_dispatch, "42"}, 2_000
    pending = await(ctx.store, ctx.decision.decision_id, & &1.pending_for_session?)
    refute Retry.dispatchable?(pending, false)
    release_lookup(ctx)
    linked = await(ctx.store, pending.decision_id, &(Commands.override_target_ticket(&1).identifier == "43"))
    refute linked.pending_for_session?
    assert linked.revision_result == :recorded
    assert Retry.dispatchable?(linked, false)
  end

  defp fixture(old_target_result) do
    dir = Aiur.TestSupport.tmp_root!("corrective-retarget")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    owner = self()
    ready = start_supervised!({Agent, fn -> false end})
    :ok = DecisionPubSub.subscribe()

    opts = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      answer_comment_publisher: fn _ -> :ok end,
      revision_follow_up_projector: fn _, _ -> :ok end,
      revision_follow_up_resolver: fn _, action ->
        send(owner, {:follow_up_resolved, action})
        :ok
      end,
      dispatcher: fn decision, _opts ->
        target = Commands.override_target_ticket(decision).identifier
        send(owner, {:effective_dispatch, target})
        if target == "42", do: old_target_result, else: {:ok, %{status: :accepted, item: %{id: 1}}}
      end,
      corrective_override_reconciler: fn _decision, record ->
        if Agent.get(ready, & &1) and is_nil(Map.get(record, :corrective_ticket)) do
          ticket = %{identifier: "43", title: "Correction", url: "https://example.test/issues/43"}
          {:ok, [{:override_corrective_ticket, %{action_id: record.action_id, ticket: ticket, pr_number: 77, merge_commit_sha: "merged"}}]}
        else
          {:ok, []}
        end
      end
    ]

    store = start_supervised!({DecisionStore, opts})
    request_opts = [ticket: %{identifier: "42"}, source: %{agent_id: "worker", session_id: "session"}]
    {:ok, %{decision: original}} = Commands.request(%{source_id: "retarget", question: "Which direction?", blocking: false}, request_opts, store)
    actor = [actor: %{kind: :operator, id: "human"}]
    {:ok, _} = Commands.answer(original.decision_id, payload("original"), actor, store)
    context = %{pr: :unknown, worker: :unknown, capacity: :available}
    {:ok, %{decision: decision}} = Commands.override(original.decision_id, payload("correction"), actor ++ [override_context: context], store)
    %{store: store, opts: opts, ready: ready, decision: decision}
  end

  defp release_lookup(ctx) do
    Agent.update(ctx.ready, fn _ -> true end)
    send(ctx.store, :reconcile_corrective_overrides)
  end

  defp await(store, id, predicate) do
    {:ok, decision} = DecisionStore.get(id, store)

    if predicate.(decision) do
      decision
    else
      assert_receive {:decision_changed, ^id, _version}, 2_000
      await(store, id, predicate)
    end
  end

  defp payload(text), do: %{expected_version: 1, custom_response: text, rationale: "Changed direction", idempotency_key: text}
end
