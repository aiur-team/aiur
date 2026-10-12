defmodule Aiur.OptimisticStart.DispatchPreparationTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.SubscriptionStore
  alias Aiur.Issue
  alias Aiur.Orchestrator.{AutoSubscriptions, OptimisticDispatch, State}

  @sha String.duplicate("a", 40)

  setup do
    :ok = Aiur.TestSupport.ensure_subscription_store_supervisor_running()
    dependent = to_string(System.unique_integer([:positive]))
    blocker = to_string(System.unique_integer([:positive]))

    on_exit(fn ->
      SubscriptionStore.stop(dependent)
      SubscriptionStore.stop(blocker)
    end)

    issue = %Issue{id: dependent, identifier: dependent, state: "todo", blocked_by: [%{identifier: blocker, state: "in-progress"}]}
    evidence = [%{identifier: blocker, pr_number: 99, head_ref: "aiur/#{blocker}-work", head_sha: @sha}]
    %{issue: issue, blocker: blocker, evidence: evidence}
  end

  test "real subscriptions and direct blockers exist when preparation returns", ctx do
    assert {:ok, prepared} = OptimisticDispatch.prepare(ctx.issue, ctx.evidence, [])
    assert prepared.optimistic_start.primary == ctx.blocker
    topics = SubscriptionStore.snapshot(ctx.issue.identifier).subscribed_to
    assert Enum.any?(topics, &(&1["topic"] == "ticket.#{ctx.blocker}.branch.push" and &1["reason"] == "blocker:auto"))
    assert AutoSubscriptions.direct_blockers_for(%State{}, ctx.issue.identifier) == [ctx.blocker]
  end

  test "optimistic subscription failure refuses preparation", ctx do
    subscriber = fn _dependent, _blocker -> {:error, :store_failed} end
    assert {:error, :optimistic_subscription_failed} = OptimisticDispatch.prepare(ctx.issue, ctx.evidence, blocker_subscriber: subscriber)
  end

  test "ordinary subscription failure still returns the issue", ctx do
    subscriber = fn _dependent, _blocker -> {:error, :store_failed} end
    assert {:ok, issue} = OptimisticDispatch.prepare(ctx.issue, [], blocker_subscriber: subscriber)
    assert issue.optimistic_start == nil
  end

  test "missing head evidence refuses optimistic preparation", ctx do
    evidence = Enum.map(ctx.evidence, &%{&1 | head_sha: nil})
    assert {:error, :optimistic_ref_unavailable} = OptimisticDispatch.prepare(ctx.issue, evidence, blocker_ref_lookup: fn _ -> nil end)
  end

  test "terminal blockers are not bound", ctx do
    issue = %{ctx.issue | blocked_by: [%{identifier: ctx.blocker, state: "Done"}]}
    subscriber = fn _, _ -> flunk("terminal blocker must not be bound") end
    assert {:ok, ^issue} = OptimisticDispatch.prepare(issue, [], blocker_subscriber: subscriber)
  end
end
