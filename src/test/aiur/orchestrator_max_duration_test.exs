defmodule Aiur.OrchestratorMaxDurationTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator

  describe "overrunning_entry?/3 (max_agent_duration safety net)" do
    test "fires only for actively-running agents past the cap" do
      now = DateTime.utc_now()
      old = DateTime.add(now, -120, :second)
      recent = DateTime.add(now, -10, :second)

      # active agent running 120s against a 60s cap -> kill
      assert Orchestrator.overrunning_entry?(%{started_at: old}, now, 60)

      # active agent only 10s in -> keep
      refute Orchestrator.overrunning_entry?(%{started_at: recent}, now, 60)

      # paused agents are intentionally idle (blocked) -> never killed,
      # even when their start is old (running_seconds is frozen on pause).
      refute Orchestrator.overrunning_entry?(
               %{started_at: old, control: %{status: :paused}},
               now,
               60
             )

      # deactivated agents have no live task to kill -> excluded
      refute Orchestrator.overrunning_entry?(
               %{started_at: old, control: %{status: :deactivated}},
               now,
               60
             )

      # missing started_at -> running_seconds 0 -> not overrunning
      refute Orchestrator.overrunning_entry?(%{}, now, 60)
    end
  end
end
