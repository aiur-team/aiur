defmodule Aiur.Orchestrator.ParkReservationTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{PauseResume, Reconciler, State}

  setup do
    :ok = write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [])
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    :ok
  end

  test "parking writes the marker before releasing the paused reservation and unpark waits for resume" do
    issue = %Issue{id: "2952", identifier: "repo#2952", state: "in-progress", labels: ["agent:in-progress"], paused: true}
    entry = %{issue: issue, identifier: issue.identifier, pid: nil, ref: nil, paused_reason: :operator, control: %{status: :paused}}
    state = %State{running: %{issue.id => entry}}

    assert {:reply, {:ok, :pending}, parked} = PauseResume.park_agent_call(state, issue.identifier)
    assert_received {:memory_tracker_add_label, "2952", "agent:parked"}
    assert parked.running[issue.id].issue.parked
    assert parked.running[issue.id].paused_reason == :operator
    assert parked.running[issue.id].control.status == :deactivated
    assert State.reserved_paused_running_count(parked.running) == 0

    assert {:reply, {:ok, :already_parked}, ^parked} = PauseResume.park_agent_call(parked, issue.identifier)
    refute_received {:memory_tracker_add_label, "2952", "agent:parked"}

    assert {:reply, :ok, unparked} = PauseResume.unpark_agent_call(parked, issue.identifier)
    refute unparked.running[issue.id].issue.parked

    fresh_issue = %{unparked.running[issue.id].issue | labels: ["agent:in-progress"]}
    reconciled = Reconciler.maybe_reactivate_or_refresh(unparked, fresh_issue)
    assert reconciled.running[issue.id].control.status == :deactivated
  end

  test "parks only pause reasons that currently hold fleet capacity" do
    for reason <- [:operator, :agent_pause_request, :input_required] do
      issue = %Issue{id: "#{reason}", identifier: "repo##{reason}", state: "in-progress", paused: true}
      entry = %{issue: issue, identifier: issue.identifier, pid: nil, ref: nil, paused_reason: reason, control: %{status: :paused}}

      assert {:reply, {:ok, :pending}, parked} = PauseResume.park_agent_call(%State{running: %{issue.id => entry}}, issue.identifier)
      assert parked.running[issue.id].control.status == :deactivated
      assert_receive {:memory_tracker_add_label, issue_id, "agent:parked"}, 1000
      assert issue_id == issue.id
    end

    issue = %Issue{id: "duration", identifier: "repo#duration", state: "in-progress", paused: true}
    entry = %{issue: issue, identifier: issue.identifier, pid: nil, ref: nil, paused_reason: :max_agent_duration, control: %{status: :paused}}

    assert {:reply, {:error, :reservation_not_held}, unchanged} =
             PauseResume.park_agent_call(%State{running: %{issue.id => entry}}, issue.identifier)

    assert unchanged.running[issue.id] == entry
    refute_received {:memory_tracker_add_label, "duration", "agent:parked"}
  end
end
