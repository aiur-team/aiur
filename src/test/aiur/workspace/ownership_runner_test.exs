defmodule Aiur.Workspace.OwnershipRunnerTest do
  use Aiur.TestSupport

  alias Aiur.Workspace.Ownership

  test "a competing runner cannot replace the checkout owned by a paused provisioning generation" do
    test_root = Path.join(System.tmp_dir!(), "workspace-ownership-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    after_create_trace = Path.join(test_root, "after-create.trace")
    identifier = "OWN-#{System.unique_integer([:positive])}"
    issue_id = "issue-#{identifier}"
    issue = %Issue{id: issue_id, identifier: identifier, state: "todo", labels: ["agent:todo"]}

    File.mkdir_p!(test_root)

    on_exit(fn -> File.rm_rf(test_root) end)

    test_pid = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: "printf 'created\\n' >> #{after_create_trace}; git init --quiet",
      hook_before_run: "exit 7"
    )

    first = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> AgentRunner.run(issue, test_pid) end)

    on_exit(fn -> if Process.alive?(first.pid), do: Task.shutdown(first, :brutal_kill) end)

    assert_receive {:worker_runtime_info, ^issue_id, %{workspace_path: workspace}}, 2_000
    assert_receive {:worker_control_state, ^issue_id, :paused, %{kind: :before_run_failure}}, 2_000
    assert {:ok, %{phase: :provisioning}} = Ownership.current(identifier)
    {device_inode, 0} = System.cmd("stat", ["-c", "%d:%i", workspace], stderr_to_stdout: true)

    second = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> AgentRunner.run(issue) end)

    assert {:ok, :ok} = Task.yield(second, 2_000)
    assert File.read!(after_create_trace) == "created\n"
    assert {^device_inode, 0} = System.cmd("stat", ["-c", "%d:%i", workspace], stderr_to_stdout: true)

    Task.shutdown(first, :brutal_kill)
    _registry_state = :sys.get_state(Aiur.Workspace.Ownership.Registry)
    assert :none = Ownership.current(identifier)
  end
end
