defmodule Aiur.Orchestrator.AgentTeardownTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Labels
  alias Aiur.{Issue, Tracker, Workflow}
  alias Aiur.Orchestrator.{AgentTeardown, State}

  test "teardown helpers tolerate absent process identifiers" do
    assert AgentTeardown.terminate_task(nil) == :ok
  end

  test "terminal teardown clears transient reason labels and preserves blocked and body-fix" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    labels = Labels.reason_modifier_labels("agent")
    Application.put_env(:aiur, :memory_tracker_issues, [%Issue{id: "7", identifier: "7", state: "done", labels: labels}])

    state = %State{running: %{"7" => %{identifier: "7", issue: %Issue{id: "7", identifier: "7", labels: labels}}}}

    assert %State{} = AgentTeardown.terminate_running_issue(state, "7", false)
    assert {:ok, [%Issue{labels: labels}]} = Tracker.fetch_issue_states_by_ids(["7"])
    assert Enum.sort(labels) == ["agent:blocked", "agent:body-fix"]
  end

  test "teardown with no transient reason labels performs no label writes" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [%Issue{id: "8", identifier: "8", state: "done", labels: ["agent:blocked"]}])

    assert %State{tracker_tasks: tasks} = AgentTeardown.terminate_running_issue(%State{}, "8", false)
    refute Enum.any?(tasks, fn {_ref, job} -> job.key == {:runtime_reason_labels, "8"} end)
    assert {:ok, [%Issue{labels: ["agent:blocked"]}]} = Tracker.fetch_issue_states_by_ids(["8"])
  end
end
