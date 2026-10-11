defmodule Aiur.AgentControlCLIOptimisticTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO
  alias Aiur.AgentControlCLI
  alias Aiur.Orchestrator.{Slots, State}

  test "status renders the optimistic occupancy and effective cap from the daemon snapshot" do
    state = %State{max_concurrent_agents: 8, effective_concurrent_agents: 8, running: Map.new(1..4, &{to_string(&1), %{start_mode: :optimistic}})}
    snapshot = %{statuses: [], capacity: Slots.max_concurrent_agent_status(state), polling: %{tracker_snapshot_fresh?: true, last_dispatch_poll_age_ms: 0, effective_interval_ms: 120_000}}
    freshness = %{status: :current, reason: nil, age_seconds: 0}
    output = capture_io(fn -> AgentControlCLI.status(fleet_view: {:ok, snapshot, freshness}) end)
    assert output =~ "optimistic 4/4"
    narrowed = %{snapshot | capacity: Slots.max_concurrent_agent_status(%{state | effective_concurrent_agents: 1})}
    assert capture_io(fn -> AgentControlCLI.status(fleet_view: {:ok, narrowed, freshness}) end) =~ "optimistic 4/1"
  end
end
