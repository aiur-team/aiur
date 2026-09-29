defmodule Aiur.Workspace.OwnershipRunnerTest do
  use Aiur.TestSupport

  alias Aiur.AlertLedger
  alias Aiur.Workspace.{HostLock, Ownership}
  alias Aiur.Workspace.Ownership.Store

  test "two recovering tickets claim in the same attempt after prior providers finish reaping" do
    root = Aiur.TestSupport.tmp_root!("workspace-recovery")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(root, "workspaces"),
      hook_after_create: """
      git init --quiet -b main
      git config user.email t@example.com
      git config user.name T
      touch initialized
      git add initialized
      git commit --quiet -m initial
      """,
      hook_before_run: "exit 7"
    )

    tickets = for index <- 1..2, do: "RECOVERY-#{System.unique_integer([:positive])}-#{index}"

    reapers =
      for ticket <- tickets do
        parent = self()
        group = System.unique_integer([:positive])
        {:ok, alive} = Agent.start_link(fn -> true end)
        on_exit(fn -> Aiur.TestSupport.safe_stop(alive) end)

        owner =
          spawn(fn ->
            {:ok, lease} =
              Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
                group_alive_fun: fn candidate -> candidate == group and Agent.get(alive, & &1) end,
                process_identity_fun: fn pid -> {:ok, {:test_process, pid}} end,
                reap_fun: fn ^group ->
                  send(parent, {:reap_started, ticket, self()})

                  receive do
                    :finish_reap -> Agent.update(alive, fn _ -> false end)
                  end

                  {:ok, :reaped}
                end
              )

            {:ok, lease} = Ownership.activate(lease)
            :ok = Ownership.track_process_group(lease, group)
            send(parent, {:lease_ready, ticket})
            Process.sleep(:infinity)
          end)

        assert_receive {:lease_ready, ^ticket}, 2_000
        Process.exit(owner, :kill)
        assert_receive {:reap_started, ^ticket, reaper}, 2_000
        on_exit(fn -> send(reaper, :finish_reap) end)
        assert {:ok, %{phase: :reaping}} = Ownership.current(ticket)
        {ticket, reaper}
      end

    runners =
      for ticket <- tickets do
        issue = %Issue{id: "issue-#{ticket}", identifier: ticket, state: "todo", labels: ["agent:todo"]}
        recipient = self()
        task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> AgentRunner.run(issue, recipient) end)
        on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
        {ticket, task}
      end

    refute_receive {:workspace_setup_contended, _, _, _, _}, 100

    Enum.each(reapers, fn {_ticket, reaper} -> send(reaper, :finish_reap) end)

    for {ticket, _task} <- runners do
      issue_id = "issue-#{ticket}"
      assert_receive {:worker_control_state, ^issue_id, :paused, %{kind: :before_run_failure}}, 5_000
      refute Enum.any?(AlertLedger.read(AlertLedger.path()), &(&1["topic"] == "ticket.#{ticket}.workspace.live_session"))
    end

    refute_receive {:workspace_setup_contended, _, _, _, _}
  end

  test "a competing runner cannot replace the checkout owned by a paused provisioning generation" do
    test_root = Aiur.TestSupport.tmp_root!("workspace-ownership")
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

    assert_receive {
                     :workspace_setup_contended,
                     ^issue_id,
                     ^identifier,
                     {:ok, %{phase: :provisioning}},
                     {:waiting, guardian, generation}
                   },
                   5_000

    # Existing policy guard: a genuinely live provisioning owner still raises
    # the operator warning. This is not coverage of the reaping retry itself.
    assert Enum.any?(AlertLedger.read(AlertLedger.path()), fn alert ->
             alert["topic"] == "ticket.#{identifier}.workspace.live_session" and alert["needs_attention"] == true
           end)

    assert {:ok, :ok} = Task.yield(second, 2_000)
    assert File.read!(after_create_trace) == "created\n"
    assert {^device_inode, 0} = System.cmd("stat", ["-c", "%d:%i", workspace], stderr_to_stdout: true)

    Task.shutdown(first, :brutal_kill)
    assert_receive {:workspace_ownership_available, ^identifier, ^guardian, ^generation}, 5_000
    assert :none = Ownership.current(identifier)
  end

  test "a contending generation cannot replace the checkout seen by a started runner" do
    test_root = Aiur.TestSupport.tmp_root!("workspace-generation")
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

    [launched_workspace, launched_inode, _process_id] =
      launch_trace |> File.read!() |> String.trim() |> String.split("\t")

    assert File.dir?(launched_workspace)
    assert {:ok, %{host_lock: %{path: lock_path, holder: %{owner_id: owner_id}}}} = Store.get(identifier)
    assert lock_path == HostLock.lock_path(Path.join(workspace_root, identifier))
    assert is_binary(owner_id)

    second = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> AgentRunner.run(issue, test_pid) end)

    assert_receive {
                     :workspace_setup_contended,
                     ^issue_id,
                     ^identifier,
                     {:ok, _owner},
                     {:waiting, _guardian, _generation}
                   },
                   5_000

    assert {:ok, :ok} = Task.yield(second, 2_000)

    assert {current_inode, 0} =
             System.cmd("stat", ["-c", "%d:%i", launched_workspace], stderr_to_stdout: true)

    assert String.trim(current_inode) == launched_inode

    # An orchestrator replacement kills the runner task, bypassing its `after`
    # block. The guardian must reap the tracked provider before releasing both
    # ownership and the same-daemon host lock, or a retry is stranded behind
    # the still-live BEAM pid.
    Task.shutdown(first, :brutal_kill)

    assert_eventually(fn ->
      HostLock.holder(launched_workspace) == :none and Ownership.current(identifier) == :none
    end)
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

  defp assert_eventually(fun, attempts \\ 80)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")
end
