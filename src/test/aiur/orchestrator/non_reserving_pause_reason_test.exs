defmodule Aiur.Orchestrator.NonReservingPauseReasonTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.State

  test "parked reasons share the orchestrator reservation definition" do
    for reason <- [:ci_wait, :max_agent_duration, :usage_limit_exhausted] do
      assert State.non_reserving_pause_reason?(reason)
      assert State.reserved_paused_running_count(%{"1" => %{paused_reason: reason, control_status: :paused}}) == 0
    end

    refute State.non_reserving_pause_reason?(:operator_pause)
    assert State.non_reserving_pause_reason?(:blocker_dependency)
    refute State.non_reserving_pause_reason?(nil)

    assert State.reserved_paused_running_count(%{"dependency" => %{paused_reason: :blocker_dependency, control: %{status: :paused}}}) == 0
  end

  test "cooperative worker pauses keep their fleet reservation" do
    for reason <- [:agent_pause_request, :input_required] do
      entry = %{paused_reason: reason, control: %{status: :paused}}
      assert State.reserved_paused_running_count(%{"worker" => entry}) == 1
    end
  end
end
