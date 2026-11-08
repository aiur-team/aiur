defmodule Aiur.Orchestrator.PrevalidatedDispatchDependencyTest do
  # #7797: after a restart the orphan-claim release put a ticket with an open
  # blocked_by issue back to todo, and the resume path dispatched it unhydrated.
  use Aiur.TestSupport

  alias Aiur.{Issue, Workflow}
  alias Aiur.Orchestrator.{Dispatcher, State}

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

  test "a failed blocked_by read holds dispatch" do
    assert {{:error, :dependency_hydration_failed}, next} =
             Dispatcher.dispatch_prevalidated_issue(state(), cold_issue(), blocked_by_hydrator: fn _ -> {:error, :cache_miss} end)

    refute MapSet.member?(next.claimed, "7645")
  end
end
