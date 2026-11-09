defmodule Aiur.Orchestrator.DispatchPolicy.SpendCapTest do
  use ExUnit.Case, async: true

  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.DispatchPolicy.SpendCap
  alias Aiur.TestSupport.GroupedScopes, as: GS

  test "an exhausted ticket and an unavailable cap store both fail dispatch closed" do
    issue = %Issue{id: "node-5693", identifier: "5693", title: "cap", state: "todo", tracker_identity: GS.identity(5693)}

    assert SpendCap.decision(issue, fn %TrackerIdentity{} -> {:skip, :spend_cap_exhausted} end) ==
             {:skip, :spend_cap_exhausted}

    assert SpendCap.decision(issue, fn %TrackerIdentity{} -> {:skip, :spend_cap_unavailable} end) ==
             {:skip, :spend_cap_unavailable}

    assert :spend_cap_exhausted in DispatchPolicy.dispatch_decline_reasons()
    assert :spend_cap_unavailable in DispatchPolicy.dispatch_decline_reasons()
  end

  test "legacy issues without a joinable tracker identity preserve existing dispatch behavior" do
    issue = %Issue{id: "legacy", identifier: "5693", title: "legacy", state: "todo"}
    assert SpendCap.decision(issue, fn _ -> flunk("legacy identity must not be guessed") end) == :dispatch
  end

  test "budget-exhausted is terminal even when operators omit it from configured terminal states" do
    assert DispatchPolicy.terminal_issue_state?("budget-exhausted", MapSet.new())
    assert DispatchPolicy.terminal_issue_state?("BUDGET-EXHAUSTED", MapSet.new())
  end
end
