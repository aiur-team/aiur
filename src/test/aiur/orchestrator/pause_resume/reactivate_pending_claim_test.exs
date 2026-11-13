defmodule Aiur.Orchestrator.PauseResume.ReactivatePendingClaimTest do
  # `aiur rework` on a parked worker (Open-Game-Maker #762): the reason is
  # queued on the entry that reactivation hands back, and a rework start writes
  # its guarded `in-progress` claim as an async tracker task. Reading "no pid
  # yet" as a failed start lost the reason and dropped the start.
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.PauseResume.Resume
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.Workflow

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework"]
    )

    Application.put_env(:aiur, :memory_tracker_recipient, self())
    :ok
  end

  test "a reactivated rework ticket whose claim is still being written counts as reactivated and starts when the claim lands" do
    issue = %Issue{id: "762", identifier: "762", title: "762", state: "rework", state_labels: ["rework"], selected_backend: "codex", labels: ["agent:rework"]}
    Application.put_env(:aiur, :memory_tracker_issues, [issue])
    parked = %{pid: nil, ref: nil, identifier: "762", issue: issue, worker_host: nil, completed_provenance: true, control: %{status: :deactivated}}
    parent = self()
    runner = fn dispatched, _recipient, _opts -> send(parent, {:runner_started, dispatched.id}) end

    # Owner mode writes the claim as an async task, as the live daemon does.
    state = %State{snapshot_key: self(), max_concurrent_agents: 2, effective_concurrent_agents: 2, running: %{"762" => parked}, claimed: MapSet.new(["762"])}

    assert {{:ok, :reactivated}, pending} = Resume.reactivate_issue(state, parked, blocked_by_hydrator: &{:ok, &1}, runner: runner)
    assert [%{key: {:rework_claim, "762"}}] = Map.values(pending.tracker_tasks)
    assert get_in(pending.running, ["762", :control, :status]) == :working

    {ref, _job} = Enum.find(pending.tracker_tasks, fn {_ref, job} -> job.key == {:rework_claim, "762"} end)
    assert_receive {^ref, result}, 1_000
    {:handled, _started} = TrackerTasks.result(pending, ref, result)

    assert_receive {:runner_started, "762"}, 1_000
  end
end
