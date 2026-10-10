defmodule Aiur.Orchestrator.DependencyGateTest do
  use Aiur.TestSupport

  alias Aiur.BuildQueue.Hints
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.StartTrigger.ProgressStore

  setup do
    :ets.new(Hints.table_name(), [:named_table, :set])
    id = "3765-#{System.unique_integer([:positive])}"
    %{blocker_id: id, terminal: DispatchPolicy.terminal_state_set()}
  end

  test "default dispatch preserves terminal states and fails closed for unreadable or working blockers", ctx do
    for state <- ["Done", "Cancelled", "Duplicate", "Closed", "not_planned"] do
      candidate = dependent(ctx.blocker_id, state)
      refute DispatchPolicy.todo_issue_held_by_dependency?(candidate, ctx.terminal)
      assert DispatchPolicy.optimistic_blockers(candidate) == []
    end

    for state <- [nil, "in-progress", "error"] do
      assert DispatchPolicy.todo_issue_held_by_dependency?(dependent(ctx.blocker_id, state), ctx.terminal)
    end
  end

  test "recorded merge releases an open blocker under the default trigger", ctx do
    record(ctx.blocker_id, :pr_merged)
    candidate = dependent(ctx.blocker_id, "human-review")
    refute DispatchPolicy.todo_issue_held_by_dependency?(candidate, ctx.terminal)
    assert DispatchPolicy.optimistic_blockers(candidate) == []
  end

  test "pr_opened releases ci-wait and names only optimistic blockers", ctx do
    candidate = dependent(ctx.blocker_id, "ci-wait")
    :ets.insert(Hints.table_name(), {candidate.id, {0, 0}, false, :pr_opened})
    refute DispatchPolicy.todo_issue_held_by_dependency?(candidate, ctx.terminal)
    assert DispatchPolicy.optimistic_blockers(candidate) == [ctx.blocker_id]
    refute DispatchPolicy.describe_dependency_hold(candidate, ctx.terminal) =~ ctx.blocker_id

    for state <- [nil, "in-progress", "error"] do
      assert DispatchPolicy.todo_issue_held_by_dependency?(dependent(ctx.blocker_id, state), ctx.terminal)
    end

    pending = %{candidate | blocked_by: candidate.blocked_by ++ [%{id: "pending", state: "in-progress"}]}
    assert DispatchPolicy.todo_issue_held_by_dependency?(pending, ctx.terminal)
    assert DispatchPolicy.holding_blockers(pending, ctx.terminal) == [%{id: "pending", state: "in-progress"}]
  end

  test "closed-unmerged progress holds even when the hydrated label implies an opened PR", ctx do
    candidate = dependent(ctx.blocker_id, "ci-wait")
    :ets.insert(Hints.table_name(), {candidate.id, {0, 0}, false, :pr_opened})
    record(ctx.blocker_id, nil, true)
    assert DispatchPolicy.todo_issue_held_by_dependency?(candidate, ctx.terminal)
    assert DispatchPolicy.optimistic_blockers(candidate) == []
  end

  test "recorded CI progress survives a label regression but cannot override unreadable state", ctx do
    candidate = dependent(ctx.blocker_id, "in-progress")
    :ets.insert(Hints.table_name(), {candidate.id, {0, 0}, false, :pr_ci_green})
    record(ctx.blocker_id, :pr_ci_green)
    refute DispatchPolicy.todo_issue_held_by_dependency?(candidate, ctx.terminal)
    assert DispatchPolicy.todo_issue_held_by_dependency?(dependent(ctx.blocker_id, nil), ctx.terminal)
  end

  describe "optimistic evidence freshness" do
    @day_ms 24 * 60 * 60 * 1000

    test "a day-old progress row holds, the same fresh row releases", ctx do
      candidate = dependent(ctx.blocker_id, "in-progress")
      :ets.insert(Hints.table_name(), {candidate.id, {0, 0}, false, :pr_ci_green})

      record(ctx.blocker_id, :pr_ci_green, false, System.system_time(:millisecond) - @day_ms)
      assert DispatchPolicy.todo_issue_held_by_dependency?(candidate, ctx.terminal)
      assert DispatchPolicy.optimistic_blockers(candidate) == []

      record(ctx.blocker_id, :pr_ci_green)
      refute DispatchPolicy.todo_issue_held_by_dependency?(candidate, ctx.terminal)
    end

    test "a day-old hydrated label holds, the same fresh label releases", ctx do
      :ets.insert(Hints.table_name(), {"3765-dependent", {0, 0}, false, :pr_opened})
      old = System.system_time(:millisecond) - @day_ms
      stale = [%{id: ctx.blocker_id, state: "ci-wait", observed_at_ms: old}]
      assert DispatchPolicy.todo_issue_held_by_dependency?(%{dependent(ctx.blocker_id, "ci-wait") | blocked_by: stale}, ctx.terminal)

      fresh = [%{id: ctx.blocker_id, state: "ci-wait", observed_at_ms: System.system_time(:millisecond)}]
      refute DispatchPolicy.todo_issue_held_by_dependency?(%{dependent(ctx.blocker_id, "ci-wait") | blocked_by: fresh}, ctx.terminal)
    end

    test "final evidence does not age out", ctx do
      record(ctx.blocker_id, :pr_merged, false, System.system_time(:millisecond) - @day_ms)
      refute DispatchPolicy.todo_issue_held_by_dependency?(dependent(ctx.blocker_id, "human-review"), ctx.terminal)
    end
  end

  defp dependent(id, state), do: %Issue{id: "3765-dependent", identifier: "repo#3765-dependent", title: "dependent", state: "todo", blocked_by: [%{id: id, identifier: id, state: state}]}

  defp record(id, stage, closed? \\ false, at \\ System.system_time(:millisecond)) do
    ProgressStore.record(id, %{pr_number: 99, stage: stage, closed_unmerged?: closed?, observed_at_ms: at, source: :test})
    :sys.get_state(ProgressStore)
  end
end
