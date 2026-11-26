defmodule Aiur.DecisionOverridePushReconciliationTest do
  use ExUnit.Case, async: false

  alias Aiur.DecisionStore

  @pr %{number: 77, merged?: false, head_sha: "before", head_ref: "work"}

  setup do
    dir = Aiur.TestSupport.tmp_root!("override-push-reconciliation")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    observations = start_supervised!({Agent, fn -> @pr end})
    owner = self()

    opts = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      answer_comment_publisher: fn _ -> :ok end,
      corrective_override_reconciler: fn _, record ->
        send(owner, {:corrective_observation, record.evidence})
        {:ok, []}
      end,
      override_merge_reader: fn pr -> {:ok, pr} end,
      override_context_reader: fn _ ->
        pr = Agent.get(observations, & &1)
        send(owner, {:cache_read, pr})
        %{pr: pr}
      end
    ]

    store = start_supervised!({DecisionStore, opts})

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{source_id: "push-reconciliation", question: "Proceed?", blocking: false},
        [ticket: %{identifier: "6908", title: "Override", url: nil}, source: %{agent_id: "worker", session_id: "session"}],
        store
      )

    {:ok, %{decision: answered}} = DecisionStore.answer(decision.decision_id, payload("original"), [actor: %{kind: :operator, id: "human"}], store)
    deliver(store, answered)
    %{store: store, answered: answered, opts: opts, observations: observations}
  end

  test "delayed cache convergence records push evidence for a delivered override and survives replay", ctx do
    decision = override_and_deliver(ctx, @pr)
    send(ctx.store, {:event, push_event("after")})
    assert_receive {:cache_read, @pr}, 2_000
    assert {:ok, %{overrides: [%{state: :delivered}]}} = DecisionStore.get(decision.decision_id, ctx.store)
    key = {decision.decision_id, decision.active_action_id}
    assert :sys.get_state(ctx.store).override_pending_pushes[key] == %{sha: "after", ref: "refs/heads/work"}
    pr = %{@pr | head_sha: "after"} |> Map.put(:head_updated_at, DateTime.to_iso8601(after_delivery(decision)))
    Agent.update(ctx.observations, fn _ -> pr end)
    send(ctx.store, :reconcile_override_pushes)
    await_evidence(ctx.store, decision, "after")
    assert :sys.get_state(ctx.store).override_pending_pushes == %{}

    stop_supervised!(DecisionStore)
    replayed_again = start_supervised!({DecisionStore, ctx.opts})
    assert {:ok, %{overrides: [%{state: :delivered, evidence: %{head_sha: "after"}}]}} = DecisionStore.get(decision.decision_id, replayed_again)
  end

  test "a PR unknown at routing can be proven by a later head update on its ticket", ctx do
    decision = override_and_deliver(ctx, :unknown)
    pr = Map.put(@pr, :head_updated_at, after_delivery(decision))
    Agent.update(ctx.observations, fn _ -> pr end)
    send(ctx.store, {:event, push_event("before")})
    await_evidence(ctx.store, decision, "before")
    assert {:ok, %{overrides: [%{state: :delivered, pr_number: nil, evidence: %{pr_number: 77}}]}} = DecisionStore.get(decision.decision_id, ctx.store)
  end

  test "late observation and later review updates cannot date a pre-delivery push", ctx do
    decision = override_and_deliver(ctx, @pr)
    [%{delivered_at: delivered}] = decision.overrides
    pr = %{@pr | head_sha: "after"} |> Map.merge(%{head_updated_at: DateTime.add(delivered, -1, :second), version: DateTime.to_iso8601(DateTime.add(delivered, 10, :second))})
    Agent.update(ctx.observations, fn _ -> pr end)
    send(ctx.store, {:event, push_event("after")})
    assert {:ok, _} = DecisionStore.get(decision.decision_id, ctx.store)
    Aiur.DispatcherTestSupport.wait_until(fn -> :sys.get_state(ctx.store).override_pending_pushes == %{} end)
    assert {:ok, %{overrides: [%{state: :delivered}]}} = DecisionStore.get(decision.decision_id, ctx.store)

    missing_date = Map.delete(pr, :head_updated_at)
    Agent.update(ctx.observations, fn _ -> missing_date end)
    send(ctx.store, {:event, push_event("after")})
    assert_receive {:cache_read, ^missing_date}, 2_000
    assert {:ok, %{overrides: [%{state: :delivered}]}} = DecisionStore.get(decision.decision_id, ctx.store)
  end

  test "an uncorrelated lookup response cannot record push evidence", ctx do
    decision = override_and_deliver(ctx, @pr)
    pr = %{@pr | head_sha: "after"} |> Map.put(:head_updated_at, after_delivery(decision))
    result = {:override_push_observed, [{decision.decision_id, decision.active_action_id, 1}], "after", "refs/heads/work", after_delivery(decision), pr}
    send(ctx.store, result)
    assert {:ok, %{overrides: [%{evidence: nil}]}} = DecisionStore.get(decision.decision_id, ctx.store)
    Agent.update(ctx.observations, fn _ -> pr end)
    send(ctx.store, {:event, push_event("other")})
    send(ctx.store, result)
    assert {:ok, %{overrides: [%{evidence: nil}]}} = DecisionStore.get(decision.decision_id, ctx.store)
  end

  test "a matching explicit signal records its push before reconciling an already merged held head", ctx do
    decision = override_and_deliver(ctx, @pr)
    pr = @pr |> Map.merge(%{head_sha: "after", merged?: true, head_updated_at: after_delivery(decision)})
    Agent.update(ctx.observations, fn _ -> pr end)
    send(ctx.store, {:event, push_event("after")})
    assert_receive {:corrective_observation, %{kind: :push, head_sha: "after"}}, 2_000
    await_evidence(ctx.store, decision, "after")
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

  defp after_delivery(decision) do
    [%{delivered_at: at}] = decision.overrides
    DateTime.add(at, 1, :second)
  end

  defp push_event(sha), do: %{topic: "ticket.6908.branch.push", source: :system, payload: %{sha: sha, ref: "refs/heads/work"}}

  defp await_evidence(store, decision, sha),
    do:
      Aiur.DispatcherTestSupport.wait_until(fn ->
        {:ok, current} = DecisionStore.get(decision.decision_id, store)
        match?([%{evidence: %{head_sha: ^sha}}], current.overrides)
      end)

  defp payload(token), do: %{expected_version: 1, custom_response: token, rationale: "Changed direction", idempotency_key: token}
end
