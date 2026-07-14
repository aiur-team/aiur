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
      hook_after_create: """
      printf 'created\\n' >> #{after_create_trace}
      git init --quiet -b main
      git config user.email t@example.com
      git config user.name T
      touch initialized
      git add initialized
      git commit --quiet -m initial
      """,
      hook_before_run: "exit 7"
    )

    first = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> AgentRunner.run(issue, test_pid) end)

    on_exit(fn -> if Process.alive?(first.pid), do: Task.shutdown(first, :brutal_kill) end)

    assert_receive {:worker_runtime_info, ^issue_id, %{workspace_path: workspace}}, 5_000
    assert_receive {:worker_control_state, ^issue_id, :paused, %{kind: :before_run_failure}}, 5_000
    assert {:ok, %{phase: :provisioning}} = Ownership.current(identifier)
    {device_inode, 0} = System.cmd("stat", ["-c", "%d:%i", workspace], stderr_to_stdout: true)

    second = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> AgentRunner.run(issue, test_pid) end)

    assert_receive {:workspace_setup_contended, ^issue_id, ^identifier, {:ok, %{phase: :provisioning}}, {:waiting, guardian, generation}}, 5_000
    assert {:ok, :ok} = Task.yield(second, 2_000)
    assert File.read!(after_create_trace) == "created\n"
    assert {^device_inode, 0} = System.cmd("stat", ["-c", "%d:%i", workspace], stderr_to_stdout: true)

    Task.shutdown(first, :brutal_kill)
    assert_receive {:workspace_ownership_available, ^identifier, ^guardian, ^generation}, 5_000
    assert :none = Ownership.current(identifier)
  end

  test "a contending generation cannot replace the checkout seen by a started runner" do
    test_root = Path.join(System.tmp_dir!(), "workspace-generation-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")
    launch_trace = Path.join(test_root, "launch.trace")
    identifier = "GEN-#{System.unique_integer([:positive])}"
    issue_id = "issue-#{identifier}"
    issue = %Issue{id: issue_id, identifier: identifier, state: "todo", labels: ["agent:todo"]}
    test_pid = self()

    File.mkdir_p!(test_root)

    on_exit(fn -> File.rm_rf(test_root) end)

    File.write!(codex_binary, fake_codex_script())
    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      max_turns: 1,
      hook_after_create: """
      git init --quiet -b main
      git config user.email t@example.com
      git config user.name T
      printf checkout > README.md
      git add README.md
      git commit --quiet -m initial
      """
    )

    previous_trace = System.get_env("AIUR_WORKSPACE_LAUNCH_TRACE")
    System.put_env("AIUR_WORKSPACE_LAUNCH_TRACE", launch_trace)

    on_exit(fn ->
      case previous_trace do
        nil -> System.delete_env("AIUR_WORKSPACE_LAUNCH_TRACE")
        value -> System.put_env("AIUR_WORKSPACE_LAUNCH_TRACE", value)
      end
    end)

    first = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> AgentRunner.run(issue, test_pid) end)

    on_exit(fn ->
      if Process.alive?(first.pid), do: Task.shutdown(first, :brutal_kill)
    end)

    assert_receive {:codex_worker_update, ^issue_id, %{event: :session_started}}, 5_000
    assert File.regular?(launch_trace)

    [launched_workspace, launched_inode, process_id] =
      launch_trace |> File.read!() |> String.trim() |> String.split("\t")

    assert File.dir?(launched_workspace)

    second = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> AgentRunner.run(issue, test_pid) end)

    assert_receive {:workspace_setup_contended, ^issue_id, ^identifier, {:ok, _owner}, {:waiting, _guardian, _generation}}, 5_000
    assert {:ok, :ok} = Task.yield(second, 2_000)

    assert {current_inode, 0} =
             System.cmd("stat", ["-c", "%d:%i", launched_workspace], stderr_to_stdout: true)

    assert String.trim(current_inode) == launched_inode

    assert {_output, 0} = System.cmd("kill", ["-USR1", process_id], stderr_to_stdout: true)
    assert {:ok, :ok} = Task.yield(first, 5_000)
  end

  defp fake_codex_script do
    """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        3)
          printf '%s\\t%s\\t%s\\n' "$(pwd -P)" "$(stat -c '%d:%i' .)" "$$" > "$AIUR_WORKSPACE_LAUNCH_TRACE"
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-generation"}}}'
          ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-generation"}}}'
          trap 'printf "%s\\n" "{\\"method\\":\\"turn/completed\\"}"; exit 0' USR1
          read -r _
          ;;
      esac
    done
    """
  end
end
