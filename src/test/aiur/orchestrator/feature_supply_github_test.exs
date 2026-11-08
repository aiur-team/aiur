defmodule Aiur.Orchestrator.FeatureSupplyGitHubTest do
  use Aiur.DispatcherBlockedByCostSupport
  alias Aiur.Orchestrator.FeatureSupplySnapshot

  test "missing dependency cache never proves ready and preserves known todo declines without reads" do
    stub_github(fn _ -> flunk("supply observations must never read GitHub") end)
    state = %State{max_concurrent_agents: 3, effective_concurrent_agents: 3}
    feature = %{candidate("14") | labels: ["feature:test"]}
    paused = %{candidate("15") | labels: ["feature:test", "sym:paused"], paused: true}
    decision = %{candidate("16") | labels: ["feature:test"]}
    state = %{state | blocked_ticket_ids: MapSet.new([decision.id])}
    sample = FeatureSupplySnapshot.build(state, [feature, paused, decision])
    assert sample.feature_ready == 0
    assert sample.declines == %{"dependency_unknown" => 1, "paused" => 1, "blocked_on_decision" => 1}
    assert sample.blockers == []
    assert blocked_by_reads() == []
    refute_received {:github, _}
  end
end
