defmodule Aiur.Orchestrator.ParkReservationTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{Parking, PauseResume, Reconciler, Slots, State}

  setup do
    test_pid = self()
    :ok = write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [])
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    on_exit(fn -> Aiur.TestSupport.stop_test_runners(test_pid) end)
    :ok
  end

  test "parking keeps the issue fenced until an explicit resume" do
    issue = %Issue{id: "2952", identifier: "repo#2952", state: "in-progress", labels: ["agent:in-progress"], paused: true}
    entry = %{issue: issue, identifier: issue.identifier, pid: nil, ref: nil, paused_reason: :operator, control: %{status: :paused}}
    state = %State{max_concurrent_agents: 1, running: %{issue.id => entry}}

    assert Slots.available_slots(state) == 0

    assert {:reply, {:ok, :pending}, parked} = Parking.park_agent_call(state, issue.identifier)
    assert_received {:memory_tracker_add_label, "repo#2952", "agent:parked"}
    assert parked.running[issue.id].issue.parked
    assert parked.running[issue.id].paused_reason == :operator
    assert parked.running[issue.id].control.status == :deactivated
    assert State.reserved_paused_running_count(parked.running) == 0
    assert Slots.available_slots(parked) == 1

    assert {:reply, {:ok, :already_parked}, ^parked} = Parking.park_agent_call(parked, issue.identifier)
    refute_received {:memory_tracker_add_label, "repo#2952", "agent:parked"}

    fresh_issue = %{parked.running[issue.id].issue | labels: ["agent:in-progress"]}
    reconciled = Reconciler.maybe_reactivate_or_refresh(parked, fresh_issue)
    assert reconciled.running[issue.id].control.status == :deactivated
    assert reconciled.running[issue.id].issue.parked

    assert {{:ok, :reactivated}, resumed} = PauseResume.resume_issue(parked, issue.identifier)
    assert_received {:memory_tracker_remove_label, "repo#2952", "agent:parked"}
    refute resumed.running[issue.id].issue.parked
  end

  test "resume refuses to race a pending park marker write" do
    issue = %Issue{id: "2952", identifier: "repo#2952", state: "in-progress", paused: true}
    entry = %{issue: issue, identifier: issue.identifier, pid: nil, ref: nil, control: %{status: :paused}}
    task_ref = make_ref()
    state = %State{running: %{issue.id => entry}, tracker_tasks: %{task_ref => %{key: {:park_issue, issue.id}}}}

    assert {:reply, {:error, :park_pending}, ^state} =
             PauseResume.tracker_control_call(state, :resume, issue.identifier)

    refute_received {:memory_tracker_remove_label, "repo#2952", "agent:parked"}
  end

  test "an Executor pause on a ci-wait ticket does not hold a fleet slot" do
    paused = %{pid: nil, ref: nil, paused_reason: :operator, control: %{status: :paused}}
    ci_wait = %Issue{id: "4672", identifier: "repo#4672", state: "ci-wait", paused: true}
    rework = %Issue{id: "4471", identifier: "repo#4471", state: "rework", paused: true}

    running = %{
      ci_wait.id => Map.merge(paused, %{issue: ci_wait, identifier: ci_wait.identifier}),
      rework.id => Map.merge(paused, %{issue: rework, identifier: rework.identifier})
    }

    state = %State{max_concurrent_agents: 2, running: running}

    assert State.reserved_paused_running_count(state.running) == 1
    assert Slots.available_slots(state) == 1
    assert {:reply, {:error, :reservation_not_held}, ^state} = Parking.park_agent_call(state, ci_wait.identifier)
  end

  test "resuming a non-reserving ci-wait pause counts other reserved pauses against the cap" do
    paused = %{pid: nil, ref: nil, paused_reason: :operator, control: %{status: :paused}}
    working = %{pid: nil, ref: nil, control: %{status: :working}}
    ci_wait = %Issue{id: "4672", identifier: "repo#4672", state: "ci-wait", paused: true}
    rework = %Issue{id: "4471", identifier: "repo#4471", state: "rework", paused: true}

    active =
      Map.new(["a1", "a2"], fn id ->
        {id, Map.put(working, :issue, %Issue{id: id, identifier: "repo##{id}", state: "in-progress"})}
      end)

    running =
      Map.merge(active, %{
        ci_wait.id => Map.merge(paused, %{issue: ci_wait, identifier: ci_wait.identifier}),
        rework.id => Map.merge(paused, %{issue: rework, identifier: rework.identifier})
      })

    state = %State{max_concurrent_agents: 3, running: running}

    assert Slots.used_slots(state) == 3
    entry = running[ci_wait.id]
    assert PauseResume.resume_paused_issue_preflight(state, entry) == {:error, :max_concurrent_agents_reached}

    assert {{:error, :max_concurrent_agents_reached}, ^state} =
             PauseResume.ControlRequest.submit_resume_control_request(state, entry, :operator)

    # The reserving pause itself still resumes into the slot it holds.
    assert PauseResume.resume_paused_issue_preflight(state, running[rework.id]) == :ok
  end

  test "parks only pause reasons that currently hold fleet capacity" do
    for reason <- [:operator, :agent_pause_request, :input_required] do
      issue = %Issue{id: "#{reason}", identifier: "repo##{reason}", state: "in-progress", paused: true}
      entry = %{issue: issue, identifier: issue.identifier, pid: nil, ref: nil, paused_reason: reason, control: %{status: :paused}}

      assert {:reply, {:ok, :pending}, parked} = Parking.park_agent_call(%State{running: %{issue.id => entry}}, issue.identifier)
      assert parked.running[issue.id].control.status == :deactivated
      assert_receive {:memory_tracker_add_label, issue_id, "agent:parked"}, 1000
      assert issue_id == issue.identifier
    end

    issue = %Issue{id: "duration", identifier: "repo#duration", state: "in-progress", paused: true}
    entry = %{issue: issue, identifier: issue.identifier, pid: nil, ref: nil, paused_reason: :max_agent_duration, control: %{status: :paused}}

    assert {:reply, {:error, :reservation_not_held}, unchanged} =
             Parking.park_agent_call(%State{running: %{issue.id => entry}}, issue.identifier)

    assert unchanged.running[issue.id] == entry
    refute_received {:memory_tracker_add_label, "duration", "agent:parked"}
  end
end
