defmodule Aiur.Orchestrator.OptimisticGuardTest do
  use ExUnit.Case, async: true
  alias Aiur.Orchestrator.OptimisticGuard
  @now 1_000_000

  test "closure waits for grace and then parks with one warning" do
    actions = decide(record(), closed())
    refute park?(actions)
    assert {:update_blocker, "11", "10", %{suspect_since_ms: @now, suspect_cause: "pr_closed_unmerged"}} = hd(actions)
    actions = decide(record(%{"suspect_since_ms" => @now - 600_000, "suspect_cause" => "pr_closed_unmerged"}), closed())
    assert {:park, "11", "10", :pr_closed_unmerged} in actions
    assert {:attention, :optimistic_blocker_failed, "11", %{blocker: "10", cause: :pr_closed_unmerged, action: :paused_parked, severity: "warning"}} in actions
  end

  test "replacement or reopened PR resets suspicion and updates identity" do
    row = record(%{"suspect_since_ms" => @now - 660_000, "suspect_cause" => "pr_closed_unmerged", "pr_number" => 100})
    observation = Map.merge(healthy(), %{pr_number: 200, pr_head_ref: "refs/heads/aiur/10-new", pr_head_sha: "replacement"})
    assert [{:update_blocker, "11", "10", facts}, {:resolve, :optimistic_blocker_failed, "11"}] = decide(row, observation)
    assert facts.pr_number == 200
    assert facts.last_head_sha == "replacement"
    assert facts.last_head_ref == "refs/heads/aiur/10-new"
    assert facts.suspect_since_ms == nil
    assert facts.suspect_cause == nil
  end

  test "a missed reopen still gives a later closure its own grace" do
    row = record(%{"suspect_since_ms" => @now - 900_000, "suspect_cause" => "pr_closed_unmerged"})
    closed_at = @now - 1_000
    assert [{:update_blocker, "11", "10", %{suspect_since_ms: ^closed_at}}] = decide(row, Map.put(closed(), :pr_closed_at_ms, closed_at))
  end

  test "cancelled issue and removed edge park immediately; completed issue stays healthy" do
    for reason <- ["not_planned", "duplicate"] do
      assert park?(decide(record(), Map.merge(closed(), %{issue_open?: false, state_reason: reason})))
    end

    assert {:park, "11", "10", :edge_removed} in decide(record(), Map.put(healthy(), :edges, %{"11" => MapSet.new()}))
    actions = decide(record(), Map.merge(closed(), %{issue_open?: false, state_reason: "completed"}))
    refute park?(actions)
    assert {:resolve, :optimistic_blocker_failed, "11"} in actions

    removed_after_complete = Map.merge(healthy(), %{edges: %{"11" => MapSet.new()}, issue_open?: false, state_reason: "completed"})
    refute park?(decide(record(), removed_after_complete))

    removed_after_merge = Map.merge(healthy(), %{edges: %{"11" => MapSet.new()}, pr_merged: true, pr_state: "closed"})
    actions = decide(record(), removed_after_merge)
    refute park?(actions)
    assert {:merged_notice, "11", "10"} in actions
  end

  test "nonterminal trouble waits, informs without parking, and recovery resolves" do
    for {label, cause} <- [{"agent:error", :agent_error}, {"agent:paused", :paused}, {"agent:parked", :parked}, {"agent:todo", :todo}] do
      observation = Map.put(healthy(), :labels, [label])
      refute attention?(decide(record(), observation))
      row = record(%{"suspect_since_ms" => @now - 660_000, "suspect_cause" => to_string(cause)})
      actions = decide(row, observation)
      assert {:attention, :optimistic_blocker_failed, "11", %{blocker: "10", cause: cause, action: :none, severity: "info"}} in actions
      refute park?(actions)
      assert {:resolve, :optimistic_blocker_failed, "11"} in decide(row, healthy())
    end
  end

  test "merged confirmation and sparse closures cannot park" do
    actions = decide(record(), Map.put(closed(), :pr_merged, true))
    refute park?(actions)
    assert {:merged_notice, "11", "10"} in actions
    actions = decide(record(), Map.put(closed(), :pr_merged, nil))
    refute park?(actions)
    refute Enum.any?(actions, &match?({:resolve, _, _}, &1))
  end

  test "unknown, stale, future and unconfirmed observations fail closed" do
    assert {:park, "11", "10", :edge_removed} in decide(record(), Map.put(healthy(), :edge_present?, false))

    for observation <- [nil, Map.put(closed(), :confirmed?, false), Map.put(closed(), :observed_at_ms, @now - 120_001), Map.put(closed(), :observed_at_ms, @now + 1)] do
      assert decide(record(), observation) == []
    end
  end

  test "finished dependent attention names park without pause" do
    actions = decide(record(), Map.put(healthy(), :edge_present?, false), running_dependents: MapSet.new())
    assert {:attention, :optimistic_blocker_failed, "11", %{blocker: "10", cause: :edge_removed, action: :parked, severity: "warning"}} in actions
  end

  test "completed park stays held while incomplete park retries its durable intent" do
    row = Map.put(record(%{"park_cause" => "edge_removed", "park_complete" => true}), "status", "parked")
    assert decide(row, nil) == []
    assert decide(row, healthy()) == []
    incomplete = put_in(row, ["blockers", Access.at(0), "park_complete"], false)
    assert decide(incomplete, nil) == [{:park, "11", "10", "edge_removed"}]
  end

  test "multiple failed blockers yield one park and one attention" do
    row = Map.update!(record(), "blockers", &(&1 ++ [%{"id" => "12"}]))
    observation = Map.put(healthy(), :edge_present?, false)
    actions = OptimisticGuard.decide([row], %{"10" => observation, "12" => observation}, @now)
    assert Enum.count(actions, &match?({:park, _, _, _}, &1)) == 1
    assert Enum.count(actions, &match?({:attention, _, _, _}, &1)) == 1
  end

  test "churn informs at threshold without parking, zero disables" do
    row = put_in(record(), ["counters", "integrations_conflict"], 3)
    actions = OptimisticGuard.decide([row], %{"10" => healthy()}, @now, grace_ms: 0)
    assert {:attention, :optimistic_blocker_failed, "11", %{blocker: "10", cause: :churn, action: :none, severity: "info"}} in actions
    refute park?(actions)
    refute attention?(decide(row, healthy(), churn_threshold: 0))
    refute attention?(decide(row, healthy(), churn_threshold: 4))
  end

  test "resolved conflicts do not emit churn after the blocker recovers" do
    row = put_in(record(%{"merged_at_ms" => @now}), ["counters", "integrations_conflict"], 3)
    actions = decide(row, Map.put(healthy(), :pr_state, :merged))
    refute Enum.any?(actions, &match?({:attention, :optimistic_blocker_failed, _, _}, &1))
    assert {:merged_notice, "11", "10"} in actions
  end

  test "approval on a mergeable head clears conflicts already resolved" do
    row = Map.put(record(), "integration_reports", conflict_reports(3))
    observation = Map.merge(healthy(), %{pr_approved?: true, pr_mergeable?: true, pr_head_sha: "approved-head", pr_approval_checked_conflicts: 3})

    first = OptimisticGuard.decide([row], %{"10" => observation}, @now, grace_ms: 0)
    row = apply_updates(row, first)

    {actions, _row} =
      Enum.reduce(1..2, {first, row}, fn _, {_, current} ->
        actions = OptimisticGuard.decide([current], %{"10" => observation}, @now, grace_ms: 0)
        {actions, apply_updates(current, actions)}
      end)

    assert {:update_blocker, "11", "10", facts} = hd(first)
    assert facts.approval_head_sha == "approved-head"
    assert facts.conflicts_at_approval == 3
    refute Enum.any?(actions, &match?({:attention, :optimistic_blocker_failed, "11", %{cause: :churn}}, &1))
  end

  test "conflicts after approval on the same head still raise churn" do
    row = record(%{"approval_head_sha" => "approved-head", "approval_active" => true, "conflicts_at_approval" => 3})
    row = Map.put(row, "integration_reports", conflict_reports(6))
    observation = Map.merge(healthy(), %{pr_approved?: true, pr_mergeable?: false, pr_head_sha: "approved-head", pr_approval_checked_conflicts: 3})

    actions = OptimisticGuard.decide([row], %{"10" => observation}, @now, grace_ms: 0)

    assert Enum.any?(actions, &match?({:attention, :optimistic_blocker_failed, "11", %{blocker: "10", cause: :churn}}, &1))
  end

  test "edge membership is dependent-specific and an unknown edge cannot park" do
    row = record()
    other = Map.put(row, "ticket", "13")
    observation = Map.put(healthy(), :edges, %{"11" => MapSet.new(), "13" => MapSet.new(["10"])})
    actions = OptimisticGuard.decide([row, other], %{"10" => observation}, @now)
    assert {:park, "11", "10", :edge_removed} in actions
    refute Enum.any?(actions, &match?({:park, "13", _, _}, &1))
    refute park?(decide(row, Map.put(healthy(), :edges, %{"11" => :unknown})))
  end

  test "closed PR failure takes precedence over an agent error" do
    row = record(%{"suspect_since_ms" => @now - 660_000, "suspect_cause" => "pr_closed_unmerged"})
    assert {:park, "11", "10", :pr_closed_unmerged} in decide(row, Map.put(closed(), :labels, ["agent:error"]))
  end

  test "Executor acknowledgment holds failure until healthy recovery enables future parking" do
    row = record(%{"failure_acknowledged" => true, "suspect_since_ms" => @now - 660_000, "suspect_cause" => "pr_closed_unmerged"})

    for {observation, cause} <- [{closed(), "pr_closed_unmerged"}, {Map.put(healthy(), :edge_present?, false), nil}, {Map.put(healthy(), :labels, ["agent:error"]), "agent_error"}] do
      actions = decide(put_in(row, ["blockers", Access.at(0), "suspect_cause"], cause), observation)
      refute park?(actions)
      refute attention?(actions)
      assert [{:update_blocker, "11", "10", facts}] = actions
      refute Map.has_key?(facts, :failure_acknowledged)
    end

    assert [{:update_blocker, "11", "10", recovery}, {:resolve, :optimistic_blocker_failed, "11"}] = decide(row, healthy())
    assert recovery.failure_acknowledged == false
    recovery = Map.new(recovery, fn {key, value} -> {to_string(key), value} end)
    recovered = Map.update!(row, "blockers", fn [blocker] -> [Map.merge(blocker, recovery)] end)
    assert {:park, "11", "10", :edge_removed} in decide(recovered, Map.put(healthy(), :edge_present?, false))
  end

  test "closed records are ignored" do
    assert {:park, "11", "10", :edge_removed} in decide(record(), Map.put(healthy(), :edge_present?, false))
    assert decide(Map.put(record(), "status", "closed"), Map.put(healthy(), :edge_present?, false)) == []
  end

  defp park?(actions), do: Enum.any?(actions, &match?({:park, _, _, _}, &1))
  defp conflict_reports(count), do: for(n <- 1..count, do: %{"blocker" => "10", "conflict" => true, "sha" => String.pad_leading(Integer.to_string(n), 40, "0")})

  defp apply_updates(row, actions) do
    Enum.reduce(actions, row, &apply_update/2)
  end

  defp apply_update({:update_blocker, _, id, facts}, current), do: Map.update!(current, "blockers", &Enum.map(&1, fn blocker -> merge_update(blocker, id, facts) end))
  defp apply_update(_, current), do: current
  defp merge_update(%{"id" => id} = blocker, id, facts), do: Map.merge(blocker, stringify(facts))
  defp merge_update(blocker, _id, _facts), do: blocker
  defp stringify(facts), do: Map.new(facts, fn {key, value} -> {to_string(key), value} end)

  defp attention?(actions), do: Enum.any?(actions, &match?({:attention, _, _, _}, &1))
  defp decide(row, observation, opts \\ []), do: OptimisticGuard.decide([row], %{"10" => observation}, @now, opts)
  defp record(facts \\ %{}), do: %{"ticket" => "11", "status" => "running", "blockers" => [Map.merge(%{"id" => "10"}, facts)], "counters" => %{"integrations_conflict" => 0}}
  defp healthy, do: %{confirmed?: true, observed_at_ms: @now, issue_open?: true, labels: [], edge_present?: true, pr_state: :open, any_open_pr?: true, pr_merged: false}
  defp closed, do: %{healthy() | pr_state: :closed, any_open_pr?: false}
end
