defmodule Aiur.Orchestrator.RetryPollClaimTest do
  # OGM #1422 and #1215: a retry pops its entry, then reads the tracker. While
  # that read was in flight (37s during a GitHub budget hold), the dispatch
  # poll saw a claim with no runtime and no retry entry, released it as
  # orphaned, and the read's completion no longer matched the claim it
  # expected, so the retry and its worker were lost.
  use Aiur.TestSupport

  alias Aiur.{Issue, Workflow}
  alias Aiur.Orchestrator.Dispatcher.Launch
  alias Aiur.Orchestrator.{DispatchPolicy, State, TrackerTasks}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["todo", "in-progress", "rework"])
    :ok
  end

  test "a claim whose retry read is in flight is not released as orphaned" do
    issue = %Issue{id: "1422", identifier: "1422", title: "retry", state: "in-progress", state_labels: ["in-progress"], selected_backend: "codex", labels: ["agent:in-progress"]}
    parent = self()
    claimed = %State{max_concurrent_agents: 4, effective_concurrent_agents: 4, claimed: MapSet.new([issue.id])}

    polling =
      TrackerTasks.start(
        claimed,
        {:retry_poll, issue.id},
        fn ->
          send(parent, {:retry_read_started, self()})
          receive do: (:finish_read -> {:ok, issue})
        end,
        fn current, _result -> current end
      )

    assert_receive {:retry_read_started, read_pid}, 1_000

    {recovered, decision} = Launch.recover_orphaned_claim(polling, issue, DispatchPolicy.active_state_set(), DispatchPolicy.terminal_state_set())

    assert decision == {:skip, :claimed_without_runtime}
    assert MapSet.member?(recovered.claimed, issue.id)

    # Once no tracker job owns the claim, the same claim is released as before.
    {released, _decision} = Launch.recover_orphaned_claim(claimed, issue, DispatchPolicy.active_state_set(), DispatchPolicy.terminal_state_set())
    refute MapSet.member?(released.claimed, issue.id)

    send(read_pid, :finish_read)
  end
end
