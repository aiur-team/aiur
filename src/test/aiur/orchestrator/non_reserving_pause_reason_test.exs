defmodule Aiur.Orchestrator.NonReservingPauseReasonTest do
  use ExUnit.Case, async: true

  alias Aiur.IssueSyncTestSupport
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State

  test "parked reasons share the orchestrator reservation definition" do
    for reason <- [:ci_wait, :max_agent_duration, :usage_limit_exhausted] do
      assert State.non_reserving_pause_reason?(reason)
      assert State.reserved_paused_running_count(%{"1" => %{paused_reason: reason, control_status: :paused}}) == 0
    end

    refute State.non_reserving_pause_reason?(:operator_pause)
    refute State.non_reserving_pause_reason?(:blocker_dependency)
    refute State.non_reserving_pause_reason?(nil)

    assert State.reserved_paused_running_count(%{
             "dependency" => %{paused_reason: :blocker_dependency, control: %{status: :paused}}
           }) == 1

    assert State.reserved_paused_running_count(%{
             "cleared" => %{
               paused_reason: :blocker_dependency,
               pending_auto_resume: %{resume_kind: :cleared_dependency},
               control: %{status: :paused}
             }
           }) == 0
  end

  test "a blocker pause reuses its reservation when the worker resumes" do
    issue = IssueSyncTestSupport.issue("dependency", "in-progress")

    entry = %{
      issue: issue,
      paused_reason: :blocker_dependency,
      control: %{status: :paused}
    }

    state = %State{running: %{issue.id => entry}, max_concurrent_agents: 1}

    assert State.reserved_paused_running_count(state.running) == 1
    assert State.reserved_paused_running_count(%{"busy" => %{control: %{status: :working}}}) == 0
    assert Slots.resume_fleet_slot_available?(state, entry)
  end

  test "cooperative worker pauses keep their fleet reservation" do
    for reason <- [:agent_pause_request, :input_required] do
      entry = %{paused_reason: reason, control: %{status: :paused}}
      assert State.reserved_paused_running_count(%{"worker" => entry}) == 1
    end
  end
end
