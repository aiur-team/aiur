defmodule Aiur.Orchestrator.StatusReport.RowFactsCapacityTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport.RowFacts

  @held %{
    candidates: [
      %{route: "codex", account: nil, verdict: :allow, reason: :limited, detail: "usage-limited"},
      %{route: "claude", account: "default", verdict: :hold, reason: :reserve, detail: "reading 25% left, reserve 30%"}
    ]
  }

  test "a running row names why dispatch chose its source" do
    selection = %{chosen: %{route: "codex", account: "default", reason: :preferred}, candidates: []}
    assert RowFacts.capacity_choice(%{issue: %Issue{dispatch_selection: selection}}) == "codex/default (preferred)"
    assert RowFacts.capacity_choice(%{issue: %Issue{}}) == nil
  end

  test "a queued row under the fleet provider hold lists every held source" do
    state = %State{capacity_hold: %{signal: :provider, threshold: :no_authorized_source, capacity: @held}}

    assert RowFacts.capacity_waiting(state, :backing_off) ==
             "waiting: no authorized source: codex limited (usage-limited); claude/default Executor reserve (reading 25% left, reserve 30%)"

    # A row waiting for another reason, or a hold without a capacity record, says nothing.
    assert RowFacts.capacity_waiting(state, :waiting_for_dependency) == nil
    assert RowFacts.capacity_waiting(%State{capacity_hold: %{signal: :memory}}, :backing_off) == nil
  end
end
