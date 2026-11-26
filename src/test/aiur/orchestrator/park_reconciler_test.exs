defmodule Aiur.Orchestrator.ParkReconcilerTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{Reconciler, State}

  test "does not automatically reactivate a released parked reservation" do
    issue = %Issue{id: "issue-parked", identifier: "issue-parked", state: "in-progress"}
    entry = %{pid: nil, ref: nil, identifier: issue.identifier, issue: issue, operator_parked: true, control: %{status: :deactivated}}
    state = %State{running: %{issue.id => entry}, max_concurrent_agents: 10}

    result = Reconciler.maybe_reactivate_or_refresh(state, issue)

    assert get_in(result.running[issue.id], [:control, :status]) == :deactivated
    assert result.running[issue.id].pid == nil
    assert result.running[issue.id].issue == issue
  end
end
