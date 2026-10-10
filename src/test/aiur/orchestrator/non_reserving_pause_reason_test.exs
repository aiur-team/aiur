defmodule Aiur.Orchestrator.NonReservingPauseReasonTest do
  use ExUnit.Case, async: true
  alias Aiur.Orchestrator.State

  test "parked reasons share the orchestrator reservation definition" do
    for reason <- [:ci_wait, :blocker_dependency, :max_agent_duration, :usage_limit_exhausted] do
      assert State.non_reserving_pause_reason?(reason)
      assert State.reserved_paused_running_count(%{"1" => %{paused_reason: reason, control_status: :paused}}) == 0
    end

    refute State.non_reserving_pause_reason?(:operator_pause)
    refute State.non_reserving_pause_reason?(nil)
  end
end
