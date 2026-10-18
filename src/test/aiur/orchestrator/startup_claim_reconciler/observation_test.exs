defmodule Aiur.Orchestrator.StartupClaimReconciler.ObservationTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.StartupClaimReconciler.Observation
  alias Aiur.Orchestrator.State

  test "an Executor-owned in-progress issue is not observed as an orphan after restart" do
    held = %Issue{
      id: "held",
      identifier: "owner/repo#5077",
      state: "in-progress",
      executor_owner: "codex"
    }

    observed = Observation.observe(%State{}, [held], now_ms: 10, ownership_fun: fn _ -> :none end)

    assert observed.orphaned_claim_since == %{}
    assert Observation.dispatch_candidates(observed, [held]) == [held]
  end
end
