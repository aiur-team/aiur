defmodule Aiur.Orchestrator.DispatchOutcomeTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.{CapacityBinding, DispatchOutcome, Slots, State}

  test "dashboard selection label renders its sample age and stale marker" do
    now = DateTime.utc_now()
    hold = %{reasons: [:unknown], candidates: 1, measured_at: DateTime.add(now, -600, :second)}
    binding = CapacityBinding.binding(%{available: 12, dispatch_selection_hold: hold}, %{}, now)
    assert {:dispatch_selection, %{stale_sample?: true}} = binding
    assert CapacityBinding.sample_age_seconds(hold, now) == 600
    label = CapacityBinding.short_label(binding)
    assert label =~ ~r/sampled=\d+s ago STALE/
    assert label =~ "unknown"
  end

  test "unexplained empty selection preserves unknown instead of inventing an upstream cause" do
    issue = %Issue{id: "unknown-2980", identifier: "repo#2980", title: "Ready", state: "todo"}
    state = %State{max_concurrent_agents: 12, effective_concurrent_agents: 12, blocked_ticket_ids: MapSet.new()}
    owner = self()
    recorded = DispatchOutcome.record(state, state, [issue], &send(owner, {:diagnostic, &1}))
    assert recorded.dispatch_selection_hold.reasons == [:unknown]
    assert_receive {:diagnostic, message}, 1_000
    assert message =~ "despite free slots"
    assert {:dispatch_selection, %{reasons: [:unknown]}} = CapacityBinding.binding(Slots.max_concurrent_agent_status(recorded))
    assert DispatchOutcome.record(recorded, recorded, [], fn _ -> :ok end).dispatch_selection_hold == nil
  end
end
