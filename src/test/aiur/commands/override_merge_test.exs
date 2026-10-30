defmodule Aiur.Commands.OverrideMergeTest do
  use ExUnit.Case, async: true
  alias Aiur.Commands.{OverrideMerge, Overrides}
  alias Aiur.Decision

  @at ~U[2026-10-27 12:00:00Z]

  test "merge before delivery, before push, and queue merge all retain corrective work" do
    for delivered? <- [false, true], head <- ["before", "old-other"] do
      decision = decision(delivered?)
      assert {:ok, updated} = merge(decision, head, DateTime.add(@at, -1))
      assert [%{route: :corrective_ticket, state: state, merge_reason: "PR merged before the change"}] = updated.overrides
      assert state == if(delivered?, do: :delivered, else: :queued)
      assert {:error, :override_push_mismatch} = push(updated)
    end
  end

  test "push and acknowledgement remain delivery evidence until their commit is in the merged head" do
    decision = decision(true)
    assert {:ok, pushed} = push(decision)
    assert [%{state: :delivered, evidence: %{kind: :push}}] = pushed.overrides
    acknowledged = Overrides.observe(pushed, %{type: :acknowledged, data: %{action_id: "override"}, occurred_at: @at})
    assert [%{state: :delivered}] = acknowledged.overrides
    assert {:ok, implemented} = merge(acknowledged, "after", DateTime.add(@at, 1))
    assert [%{state: :implemented, evidence: %{kind: :merge, head_sha: "after"}}] = implemented.overrides
  end

  test "push/merge interleavings settle once and reject the competing version" do
    for order <- [:push_first, :merge_first], contains? <- [true, false] do
      decision = decision(true)
      decision = if order == :push_first, do: elem(push(decision), 1), else: decision
      head = if contains?, do: "after", else: "before"
      assert {:ok, winner} = merge(decision, head, DateTime.add(@at, 1))
      assert [%{state: state, route: route, merge_version: 2}] = winner.overrides
      assert state == if(contains?, do: :implemented, else: :delivered)
      assert route == if(contains?, do: :active_worker, else: :corrective_ticket)
      assert {:error, :stale} = merge(winner, head, DateTime.add(@at, 1))
      assert {:error, :override_push_mismatch} = push(winner)
      assert {:error, :stale} = Overrides.resume_fact(winner, %{type: :override_resume_state, data: %{action_id: "override", route: :resume_pending, reason: :resume_failed, attempts: 1}})
    end
  end

  test "missing dates, unchanged heads and a commit before delivery cannot claim implementation" do
    for {head, at} <- [{"after", nil}, {"before", DateTime.add(@at, 1)}, {"after", @at}] do
      assert {:ok, updated} = merge(decision(true), head, at)
      assert [%{route: :corrective_ticket, implemented_at: nil}] = updated.overrides
    end
  end

  test "merge fact normalizes JSON and rejects malformed versions or dates" do
    data = %{action_id: "override", expected_version: 1, pr_number: 77, head_sha: "after", committed_at: @at}
    assert {:ok, ^data} = data |> Aiur.JSONSafe.normalize() |> OverrideMerge.normalize()

    for invalid <- [%{data | expected_version: 0}, %{data | committed_at: "bad"}] do
      assert {:error, :invalid_override_merge} = OverrideMerge.normalize(invalid)
    end
  end

  defp decision(delivered?) do
    metadata = %{pr_number: 77, pr_merged: false, pr_head_sha: "before", pr_head_ref: "work", route: :active_worker}
    decision = struct(Decision, decision_status: :decided, decision_id: "command", active_action_id: "override", ticket: %{identifier: "6912"})
    decision = Overrides.observe(decision, %{type: :revision_recorded, occurred_at: @at, data: %{override: metadata, action_id: "override", prior_action_id: "original"}})
    if delivered?, do: Overrides.observe(decision, %{type: :delivered, data: %{action_id: "override"}, occurred_at: @at}), else: decision
  end

  defp merge(decision, head, at), do: OverrideMerge.apply(decision, %{occurred_at: @at, data: %{action_id: "override", expected_version: 1, pr_number: 77, head_sha: head, committed_at: at}})
  defp push(decision), do: Overrides.implemented(decision, %{data: %{action_id: "override", at: DateTime.add(@at, 1), head_sha: "after", pr_number: 77}})
end
