defmodule Aiur.Orchestrator.PrevalidatedDispatchDependencyTest do
  # #7797: after a restart the orphan-claim release put a ticket with an open
  # blocked_by issue back to todo, and the resume path dispatched it unhydrated.
  use Aiur.TestSupport

  alias Aiur.{Issue, Workflow}
  alias Aiur.Orchestrator.{Dispatcher, StartupClaimReconciler, State}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["todo", "in-progress"])
    :ok
  end

  defp cold_issue do
    %Issue{id: "7645", identifier: "7645", title: "t", state: "todo", state_labels: ["todo"], selected_backend: "codex", labels: ["agent:todo"], blocked_by: []}
  end

  defp state, do: %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}
  defp open_blocker, do: %{id: "7643", identifier: "7643", state: "in-progress"}

  test "cold blocked_by data does not dispatch a ticket whose blocker is open" do
    hydrator = fn issue -> {:ok, %{issue | blocked_by: [open_blocker()]}} end

    assert {{:error, :waiting_for_dependencies}, next} = Dispatcher.dispatch_prevalidated_issue(state(), cold_issue(), blocked_by_hydrator: hydrator)
    refute MapSet.member?(next.claimed, "7645")
    assert next.running == %{}
  end

  # #7797 incident: startup release to todo, blocked_by cold, blocker open, then a
  # non-poll dispatch (resume / override recovery / replacement all use do_dispatch_issue).
  test "startup release then a resume-path dispatch with a cold open blocker starts no agent" do
    in_progress = %{cold_issue() | state: "in-progress", state_labels: ["in-progress"], labels: ["agent:in-progress"]}
    parent = self()

    {released_state, [%Issue{state: "todo"} = released]} =
      StartupClaimReconciler.reconcile(state(), [in_progress],
        grace_ms: 0,
        open_pr_fetcher: fn _ -> {:ok, nil} end,
        create_comment_fun: fn _, _ -> :ok end,
        read_boot_marker_fun: fn -> {:ok, "other-boot"} end,
        mark_boot_marker_fun: fn _ -> :ok end,
        update_issue_state_fun: fn _id, "todo", "in-progress" -> :ok end,
        emit_alert_fun: fn topic, _opts -> send(parent, {:alert, topic}) end
      )

    assert_receive {:alert, "ticket.7645.agent.attention.orphan_claim_released"}, 1000
    assert released.blocked_by == []

    hydrator = fn issue -> {:ok, %{issue | blocked_by: [open_blocker()]}} end
    next = Dispatcher.do_dispatch_issue(released_state, released, nil, nil, blocked_by_hydrator: hydrator)

    refute MapSet.member?(next.claimed, "7645")
    assert next.running == %{}
  end

  test "a failed blocked_by read holds dispatch" do
    assert {{:error, :dependency_hydration_failed}, next} =
             Dispatcher.dispatch_prevalidated_issue(state(), cold_issue(), blocked_by_hydrator: fn _ -> {:error, :cache_miss} end)

    refute MapSet.member?(next.claimed, "7645")
  end

  test "do_dispatch_issue records a decline when the blocker read fails" do
    hydrator = fn _ -> {:error, :boom} end
    next = Dispatcher.do_dispatch_issue(state(), cold_issue(), nil, nil, blocked_by_hydrator: hydrator)
    assert next.dispatch_declines["7645"] == :dependency_hydration_failed
    assert next.running == %{}
  end

  test "do_dispatch_issue records a dependency decline for an open blocker" do
    hydrator = fn issue -> {:ok, %{issue | blocked_by: [open_blocker()]}} end
    next = Dispatcher.do_dispatch_issue(state(), cold_issue(), nil, nil, blocked_by_hydrator: hydrator)
    assert next.dispatch_declines["7645"] == :dependency
    assert next.running == %{}
  end
end
