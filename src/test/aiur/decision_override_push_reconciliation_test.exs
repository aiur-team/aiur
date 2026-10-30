defmodule Aiur.DecisionOverridePushReconciliationTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionStore, DecisionStore.OverridePushes}

  @pr %{number: 77, merged?: false, head_sha: "before", head_ref: "work"}

  setup do
    dir = Aiur.TestSupport.tmp_root!("override-push-reconciliation")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    opts = [name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000, reconcile_delay_ms: 60_000, answer_comment_publisher: fn _ -> :ok end]
    store = start_supervised!({DecisionStore, opts})

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{source_id: "push-reconciliation", question: "Proceed?", blocking: false},
        [ticket: %{identifier: "6908", title: "Override", url: nil}, source: %{agent_id: "worker", session_id: "session"}],
        store
      )

    {:ok, %{decision: answered}} = DecisionStore.answer(decision.decision_id, payload("original"), [actor: %{kind: :operator, id: "human"}], store)
    deliver(store, answered)
    %{store: store, answered: answered, opts: opts}
  end

  test "delayed cache convergence records push evidence for a delivered override and survives replay", ctx do
    decision = override_and_deliver(ctx, @pr)
    assert :ok = reconcile(decision, :unknown)
    assert_receive {:cache_read, :unknown}, 2_000
    assert {:ok, %{overrides: [%{state: :delivered}]}} = DecisionStore.get(decision.decision_id, ctx.store)

    stop_supervised!(DecisionStore)
    restarted = start_supervised!({DecisionStore, ctx.opts})
    assert {:ok, %{overrides: [%{state: :delivered}]} = replayed} = DecisionStore.get(decision.decision_id, restarted)
    pr = %{@pr | head_sha: "after"} |> Map.put(:head_updated_at, DateTime.to_iso8601(after_delivery(replayed)))
    reconcile_and_settle(restarted, replayed, pr)
    assert {:ok, %{overrides: [%{state: :delivered, evidence: %{head_sha: "after"}}]}} = DecisionStore.get(decision.decision_id, restarted)

    stop_supervised!(DecisionStore)
    replayed_again = start_supervised!({DecisionStore, ctx.opts})
    assert {:ok, %{overrides: [%{state: :delivered, evidence: %{head_sha: "after"}}]}} = DecisionStore.get(decision.decision_id, replayed_again)
  end

  test "a PR unknown at routing can be proven by a later head update on its ticket", ctx do
    decision = override_and_deliver(ctx, :unknown)
    pr = Map.put(@pr, :head_updated_at, after_delivery(decision))
    reconcile_and_settle(ctx.store, decision, pr)
    assert {:ok, %{overrides: [%{state: :delivered, pr_number: nil, evidence: %{pr_number: 77}}]}} = DecisionStore.get(decision.decision_id, ctx.store)
  end

  test "late observation and later review updates cannot date a pre-delivery push", ctx do
    decision = override_and_deliver(ctx, @pr)
    [%{delivered_at: delivered}] = decision.overrides
    pr = %{@pr | head_sha: "after"} |> Map.merge(%{head_updated_at: DateTime.add(delivered, -1, :second), version: DateTime.to_iso8601(DateTime.add(delivered, 10, :second))})
    reconcile_and_settle(ctx.store, decision, pr)
    assert {:ok, %{overrides: [%{state: :delivered}]}} = DecisionStore.get(decision.decision_id, ctx.store)

    reconcile_and_settle(ctx.store, decision, Map.delete(pr, :head_updated_at))
    assert {:ok, %{overrides: [%{state: :delivered}]}} = DecisionStore.get(decision.decision_id, ctx.store)
  end

  defp override_and_deliver(ctx, pr) do
    context = %{pr: pr, worker: :active, capacity: :full}
    {:ok, %{decision: revised}} = DecisionStore.override(ctx.answered.decision_id, payload("override"), [actor: %{kind: :operator, id: "human"}, override_context: context], ctx.store)
    deliver(ctx.store, revised)
    {:ok, delivered} = DecisionStore.get(revised.decision_id, ctx.store)
    delivered
  end

  defp deliver(store, decision) do
    item = %{
      id: decision.revision_sequence + 1,
      target_issue_identifier: "6908",
      action_id: decision.active_action_id,
      correlation: %{decision_id: decision.decision_id, decision_version: 1, action_id: decision.active_action_id, attempt_id: "attempt-#{decision.revision_sequence}"}
    }

    assert {:ok, :accepted} = DecisionStore.validate_delivery(item, store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(item, store)
  end

  defp reconcile(decision, pr) do
    owner = self()

    OverridePushes.reconcile(%{
      current: %{decision.decision_id => decision},
      override_context_reader: fn _ticket ->
        send(owner, {:cache_read, pr})
        %{pr: pr}
      end
    })
  end

  defp reconcile_and_settle(store, decision, pr) do
    assert :ok = reconcile(decision, pr)
    assert_receive {:cache_read, ^pr}, 2_000
    assert_receive {:override_push_observed, _, _, _, _, _} = result, 2_000
    send(store, result)
  end

  defp after_delivery(decision) do
    [%{delivered_at: at}] = decision.overrides
    DateTime.add(at, 1, :second)
  end

  defp payload(token), do: %{expected_version: 1, custom_response: token, rationale: "Changed direction", idempotency_key: token}
end
