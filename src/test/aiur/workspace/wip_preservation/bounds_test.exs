defmodule Aiur.Workspace.WipPreservation.BoundsTest do
  # #2743: a dirty workspace must never lose its uncommitted work to the
  # stale-leftover recreate (#577) or to a workspace removal.
  use Aiur.TestSupport

  import Aiur.WipPreservationFixtures

  alias Aiur.Orchestrator.{AgentTeardown, WorkspaceCleanup}
  alias Aiur.Workspace.{Layout, Ownership, Provisioner, Refresh, Remove, WipPreservation}
  alias Aiur.Workspace.WipPreservation.Retention

  setup :runtime_state_dir!

  describe "save bounds" do
    test "untracked content over the size bounds is skipped with its size, and the delete proceeds", %{test_root: test_root} do
      workspace =
        cloned_workspace!(test_root, "CAP-1", workspace_wip: [max_bytes: 3_000, max_file_bytes: 2_000, max_dir_files: 5])

      File.write!(Path.join(workspace, "a-fill.txt"), String.duplicate("a", 1_600))
      File.write!(Path.join(workspace, "b-fill.txt"), String.duplicate("b", 1_600))
      File.write!(Path.join(workspace, "big.bin"), String.duplicate("z", 2_500))
      File.write!(Path.join(workspace, "c-small.txt"), "small\n")
      File.mkdir_p!(Path.join(workspace, "many"))
      for n <- 1..6, do: File.write!(Path.join(workspace, "many/f#{n}.txt"), "x")
      nested = Path.join(workspace, "nested")
      File.mkdir_p!(nested)
      git!(["-C", nested, "init", "--quiet"])
      File.write!(Path.join(nested, "inner.txt"), "inner\n")

      assert {:ok, _} = Remove.remove(workspace, nil)
      refute File.exists?(workspace)

      assert [manifest] = Enum.filter(manifests("CAP-1"), &(&1["action"] == "remove the workspace"))
      assert manifest["untracked_files"] == ["a-fill.txt", "c-small.txt"]
      skipped = Map.new(manifest["skipped_untracked"], &{&1["path"], &1})

      assert %{"reason" => "file_too_large", "size_bytes" => 2_500} = skipped["big.bin"]
      assert %{"reason" => "save_size_cap", "size_bytes" => 1_600} = skipped["b-fill.txt"]
      assert %{"reason" => "too_many_files", "file_count" => 5, "size_is_lower_bound" => true} = skipped["many/"]
      assert %{"reason" => "nested_repository"} = skipped["nested/"]
      assert skipped["nested/"]["size_bytes"] > 0
    end

    @tag timeout: 60_000
    test "a hung save command times out: the recreate keeps the workspace and holds the ticket", %{test_root: test_root} do
      identifier = "WIP-HANG-#{System.unique_integer([:positive])}"
      {workspace, trace_root} = dirty_refresh_fixture!(test_root, identifier, workspace_wip: [command_timeout_ms: 500])
      File.write!(Path.join(workspace, "README.md"), "unsaved agent edit\n")
      before = snapshot(workspace)
      fake_git!(test_root, :hang)

      started = System.monotonic_time(:millisecond)

      assert {:error, {:wip_preservation_failed, ^workspace, {:command_timeout, _git, _args, 500}}} =
               Workspace.run_before_run_hook(workspace, todo_issue(identifier))

      assert System.monotonic_time(:millisecond) - started < 10_000
      assert trace_count(trace_path(trace_root, todo_issue(identifier))) == 1
      assert snapshot(workspace) == before
    end

    @tag timeout: 60_000
    test "a closed ticket's save that times out leaves a manifest-only save, deletes the workspace and alerts", %{
      test_root: test_root
    } do
      workspace = cloned_workspace!(test_root, "HANG-T", workspace_wip: [command_timeout_ms: 500])
      File.write!(Path.join(workspace, "README.md"), "changed\n")
      fake_git!(test_root, :hang)
      subscribe!("ticket.HANG-T.workspace.wip_preservation_incomplete")

      assert {:ok, _} = Remove.remove(workspace, nil, ticket: "HANG-T", terminal?: true)
      refute File.exists?(workspace)

      assert [%{"complete" => false, "failure" => failure, "restore_commands" => []}] = manifests("HANG-T")
      assert failure =~ "command_timeout"
      assert_receive {:event, %{topic: "ticket.HANG-T.workspace.wip_preservation_incomplete"} = event}, 1_000
      assert event["message"] =~ "timed out"
    end

    test "a terminal cleanup runs off the caller and reports when it is done", %{test_root: test_root} do
      identifier = "ASYNC-#{System.unique_integer([:positive])}"
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(test_root, "workspaces"))
      {:ok, workspace} = Layout.workspace_path_for_issue(identifier, nil)
      clone_at!(test_root, workspace)
      File.write!(Path.join(workspace, "README.md"), "changed\n")
      fake_git!(test_root, {:delay, 2})

      started = System.monotonic_time(:millisecond)
      assert :ok = WorkspaceCleanup.cleanup_terminal_issue_artifacts(identifier, nil)
      assert System.monotonic_time(:millisecond) - started < 1_500
      assert File.exists?(workspace)

      assert_receive {:workspace_cleanup_finished, ^identifier, :ok}, 20_000
      refute File.exists?(workspace)
      assert [%{"complete" => true}] = manifests(identifier)
    end

    # The cleanup runs in a task, so a reopened ticket can be dispatched while
    # the save runs. The new run's lease must stop the delete.
    test "a terminal cleanup keeps the workspace when a new run claims it during the save", %{test_root: test_root} do
      identifier = "RACE-#{System.unique_integer([:positive])}"
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(test_root, "workspaces"))
      {:ok, workspace} = Layout.workspace_path_for_issue(identifier, nil)
      clone_at!(test_root, workspace)
      File.write!(Path.join(workspace, "README.md"), "changed\n")
      fake_git!(test_root, {:delay, 2})

      assert :ok = WorkspaceCleanup.cleanup_terminal_issue_artifacts(identifier, nil)
      assert_eventually(fn -> File.exists?(Path.join(test_root, "ls-files-entered")) end)
      assert {:ok, lease} = Ownership.claim(identifier)
      on_exit(fn -> Ownership.release(lease) end)
      File.write!(Path.join(workspace, "new-run.txt"), "new run\n")

      assert_receive {:workspace_cleanup_finished, ^identifier, {:skipped, :live_lease}}, 20_000
      assert File.read!(Path.join(workspace, "new-run.txt")) == "new run\n"
      assert [%{"complete" => true}] = manifests(identifier)
      assert [_notice] = WipPreservation.pending_notices(workspace, identifier)
    end

    test "a skipped delete does not emit a preserved alert", %{test_root: test_root} do
      identifier = "SKIP-#{System.unique_integer([:positive])}"
      workspace = cloned_workspace!(test_root, identifier)
      File.write!(Path.join(workspace, "README.md"), "changed\n")
      subscribe!("ticket.#{identifier}.workspace.wip_preserved")

      assert {:skipped, :live_lease} =
               WipPreservation.guard_destroy(workspace, identifier, "remove the workspace", fn -> {:skipped, :live_lease} end)

      refute_receive {:event, %{topic: "ticket." <> _}}, 300
      assert File.read!(Path.join(workspace, "README.md")) == "changed\n"
    end

    test "a crash in one terminal cleanup entry does not stop the next one", %{test_root: test_root} do
      identifier = "AFTER-CRASH-#{System.unique_integer([:positive])}"
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(test_root, "workspaces"))
      {:ok, workspace} = Layout.workspace_path_for_issue(identifier, nil)
      clone_at!(test_root, workspace)

      # A non-binary workspace identifier makes the first entry fail.
      assert :ok = WorkspaceCleanup.start_terminal_workspace_cleanups([{"CRASH", :not_a_leaf, nil}, {identifier, identifier, nil}])
      assert_receive {:workspace_cleanup_finished, :not_a_leaf, {:error, _message}}, 10_000
      assert_receive {:workspace_cleanup_finished, ^identifier, :ok}, 10_000
      refute File.exists?(workspace)
    end

    test "an exception, an exit or a throw in a cleanup entry becomes an error result" do
      assert {:error, "boom"} = WorkspaceCleanup.contain("T", "T", fn -> raise "boom" end)
      assert {:error, "exit: :boom"} = WorkspaceCleanup.contain("T", "T", fn -> exit(:boom) end)
      assert {:error, "throw: :boom"} = WorkspaceCleanup.contain("T", "T", fn -> throw(:boom) end)
      assert :ok = WorkspaceCleanup.contain("T", "T", fn -> :ok end)
    end

    @tag timeout: 60_000
    test "a timed-out save command is killed with its child processes", %{test_root: test_root} do
      workspace = cloned_workspace!(test_root, "GROUP-KILL", workspace_wip: [command_timeout_ms: 500])
      File.write!(Path.join(workspace, "README.md"), "changed\n")
      pid_file = Path.join(test_root, "child.pid")
      real_git = System.find_executable("git")
      git = Path.join(test_root, "forking-git")

      File.write!(git, """
      #!/bin/sh
      case " $* " in
        *" ls-files "*) sleep 30 & echo $! > #{shell_quote(pid_file)}; wait ;;
      esac
      exec #{shell_quote(real_git)} "$@"
      """)

      File.chmod!(git, 0o755)
      Application.put_env(:aiur, :wip_preservation_git, git)
      on_exit(fn -> Application.delete_env(:aiur, :wip_preservation_git) end)

      assert {:error, {:wip_preservation_failed, ^workspace, {:command_timeout, _git, _args, 500}}, ""} = Remove.remove(workspace, nil)
      child = pid_file |> File.read!() |> String.trim()
      assert_eventually(fn -> not File.exists?("/proc/#{child}") or zombie?(child) end)
    end
  end

  describe "retention bounds" do
    test "the age limit and the global cap prune closed tickets' saves first and never an open ticket's newest save", %{
      test_root: test_root
    } do
      closed = cloned_workspace!(test_root, "RET-CLOSED")
      open = clone_at!(test_root, Path.join([test_root, "workspaces", "RET-OPEN"]))
      open2 = clone_at!(test_root, Path.join([test_root, "workspaces", "RET-OPEN2"]))

      [c1, c2] = for n <- 1..2, do: save!(closed, "closed #{n}")
      [o1, o2] = for n <- 1..2, do: save!(open, "open #{n}")
      [p1, p2] = for n <- 1..2, do: save!(open2, "open2 #{n}")
      :ok = WipPreservation.expire_notices("RET-CLOSED")

      # Both open saves are past the age limit; only the newest is protected.
      o1 = age!(o1, 40)
      o2 = age!(o2, 30)

      root = c1 |> Path.dirname() |> Path.dirname()
      total = Enum.sum(Enum.map([c1, c2, o2, p1, p2], &dir_bytes/1))
      limits = %{retention_bytes: total - dir_bytes(c1), retention_days: 14}

      :ok = Retention.prune(root, limits, &WipPreservation.current_generation/1)

      refute File.exists?(o1), "an expired older save of an open ticket is pruned"
      assert File.dir?(o2), "the newest save of an open ticket is never pruned, even past the age limit"
      refute File.exists?(c1), "the oldest closed-ticket save goes first under the cap"
      assert File.dir?(c2)
      assert File.dir?(p1), "an open ticket's older save goes only after every closed-ticket save"
      assert File.dir?(p2)
    end
  end

  describe "permissions" do
    test "the save directories are 0700 and their files 0600", %{test_root: test_root, state_dir: state_dir} do
      workspace = cloned_workspace!(test_root, "PERM-1")
      File.write!(Path.join(workspace, "local.txt"), "never pushed\n")
      git!(["-C", workspace, "add", "local.txt"])
      git!(["-C", workspace, "commit", "--quiet", "-m", "local"])
      File.write!(Path.join(workspace, "README.md"), "changed\n")
      File.write!(Path.join(workspace, ".env"), "SECRET=1\n")

      assert {:ok, _} = Remove.remove(workspace, nil)
      [artifact | _later_artifacts] = Enum.filter(WipPreservation.pending_notices(workspace), &(&1["action"] == "remove the workspace"))
      dir = artifact["artifact_dir"]

      for path <- [Path.join(state_dir, "wip-preserved"), Path.dirname(dir), dir], do: assert(mode(path) == 0o700, path)
      files = File.ls!(dir)
      assert "untracked.tar" in files and "unpushed-commits.bundle" in files and "tracked.patch" in files
      for file <- files, do: assert(mode(Path.join(dir, file)) == 0o600, file)
    end
  end

  describe "notices" do
    test "a notice belongs to its ticket and expires when the ticket closes before its next turn", %{test_root: test_root} do
      workspace = cloned_workspace!(test_root, "NOTE-1")
      File.write!(Path.join(workspace, "README.md"), "changed\n")

      assert {:ok, _} = Remove.remove(workspace, nil, ticket: "NOTE-1")
      assert [_notice] = WipPreservation.pending_notices(workspace, "NOTE-1")
      assert [] = WipPreservation.pending_notices(workspace, "OTHER")

      # The ticket closes; its terminal cleanup expires the notice.
      assert :ok = WorkspaceCleanup.cleanup_terminal_issue_artifacts("NOTE-1", nil)
      assert_receive {:workspace_cleanup_finished, "NOTE-1", _result}, 10_000

      # A reopened ticket gets a new workspace with the same leaf, and no notice.
      clone_at!(test_root, workspace)
      assert {"prompt", []} = WipPreservation.with_pending_notices(workspace, "NOTE-1", "prompt")
      assert WipPreservation.notice_text([hd(manifests("NOTE-1"))]) =~ "can repeat"
    end

    test "the restore commands work when the old HEAD is gone after a squash merge", %{test_root: test_root} do
      workspace = cloned_workspace!(test_root, "SQUASH-1")
      git!(["-C", workspace, "checkout", "--quiet", "-b", "feature"])
      File.write!(Path.join(workspace, "other.txt"), "feature work\n")
      git!(["-C", workspace, "add", "other.txt"])
      git!(["-C", workspace, "commit", "--quiet", "-m", "feature"])
      git!(["-C", workspace, "push", "--quiet", "origin", "feature"])
      File.write!(Path.join(workspace, "README.md"), "initial\nuncommitted edit\n")
      File.write!(Path.join(workspace, "note.md"), "untracked\n")
      before = snapshot(workspace)

      assert {:ok, _} = Remove.remove(workspace, nil)
      [artifact | _later_artifacts] = Enum.filter(WipPreservation.pending_notices(workspace), &(&1["action"] == "remove the workspace"))

      # Squash-merge the branch into main and delete it on the remote.
      helper = clone_at!(test_root, Path.join(test_root, "helper"))
      File.write!(Path.join(helper, "other.txt"), "feature work\n")
      git!(["-C", helper, "add", "other.txt"])
      git!(["-C", helper, "commit", "--quiet", "-m", "squash of feature"])
      git!(["-C", helper, "push", "--quiet", "origin", "main", ":feature"])

      # A `file://` clone copies only reachable objects, as a network clone does.
      git!(["clone", "--quiet", "file://" <> origin!(test_root), workspace])
      assert {_output, status} = System.cmd("git", ["-C", workspace, "cat-file", "-e", artifact["head"] <> "^{commit}"], stderr_to_stdout: true)
      refute status == 0, "the old HEAD must be absent for this test"

      run_restore!(artifact)
      assert snapshot(workspace) == before
    end
  end

  describe "operator escape and alert deduplication" do
    setup %{test_root: test_root} do
      bin = Path.join(test_root, "bin")
      trace = Path.join(test_root, "ssh.trace")
      File.mkdir_p!(bin)

      File.write!(Path.join(bin, "ssh"), """
      #!/bin/sh
      printf '%s\\n--\\n' "$*" >> #{shell_quote(trace)}
      case "$*" in
        *"status --porcelain"*) exit 75 ;;
      esac
      exit 0
      """)

      File.chmod!(Path.join(bin, "ssh"), 0o755)
      previous_path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> (previous_path || ""))
      on_exit(fn -> System.put_env("PATH", previous_path || "") end)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: "/remote/ws", worker_ssh_hosts: ["worker-1"])
      {:ok, trace: trace}
    end

    test "a dirty remote workspace of a closed ticket alerts once and an authorized discard deletes it", %{trace: trace} do
      workspace = "/remote/ws/RT-1"
      subscribe!("ticket.RT-1.workspace.wip_preservation_failed")

      for _attempt <- 1..2 do
        assert {:error, {:wip_preservation_failed, ^workspace, :remote_worker_unsupported}, ""} =
                 Remove.remove(workspace, "worker-1", ticket: "RT-1", terminal?: true)
      end

      assert_receive {:event, %{topic: "ticket.RT-1.workspace.wip_preservation_failed"} = event}, 1_000
      assert event["message"] =~ "RT-1 is closed"
      refute event["message"] =~ "held"
      assert event["message"] =~ "discard-dirty-workspace"
      refute_receive {:event, %{topic: "ticket.RT-1.workspace.wip_preservation_failed"}}, 300

      assert :ok = WipPreservation.authorize_discard("RT-1")
      subscribe!("ticket.RT-1.workspace.wip_discarded")
      assert {:ok, []} = Remove.remove(workspace, "worker-1", ticket: "RT-1", terminal?: true)
      assert_receive {:event, %{topic: "ticket.RT-1.workspace.wip_discarded"}}, 1_000
      refute WipPreservation.discard_authorized?("RT-1")

      last_call = trace |> File.read!() |> String.split("\n--\n", trim: true) |> List.last()
      assert last_call =~ "rm -rf"
      refute last_call =~ "status --porcelain"
    end

    test "a dirty remote workspace does not run its before_remove hook", %{trace: trace} do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/ws",
        worker_ssh_hosts: ["worker-1"],
        hook_before_remove: "echo remove-hook-ran"
      )

      assert {:error, {:wip_preservation_failed, "/remote/ws/RT-HOOK", :remote_worker_unsupported}, ""} =
               Remove.remove("/remote/ws/RT-HOOK", "worker-1", ticket: "RT-HOOK", terminal?: true)

      calls = trace |> File.read!() |> String.split("\n--\n", trim: true)
      assert [call] = calls
      assert call =~ "status --porcelain"
      refute call =~ "remove-hook-ran"
    end

    test "the remote recreate holds the ticket with one alert until an operator authorizes the discard", %{trace: trace} do
      context = %{issue_id: 1, issue_identifier: "RT-2", issue_state: "todo", issue_labels: [], pr_head_ref: nil, branch_name: "aiur/RT-2"}
      error = {:error, {:workspace_hook_failed, "before_run", 65, ""}}
      subscribe!("ticket.RT-2.workspace.wip_preservation_failed")

      for _attempt <- 1..2 do
        assert {:error, {:wip_preservation_failed, "/remote/ws/RT-2", :remote_worker_unsupported}} =
                 Refresh.maybe_recreate_stale_workspace(error, elem(error, 1), "exit 65", "/remote/ws/RT-2", context, "worker-1")
      end

      assert_receive {:event, %{topic: "ticket.RT-2.workspace.wip_preservation_failed"} = event}, 1_000
      assert event["message"] =~ "the ticket is held"
      refute_receive {:event, %{topic: "ticket.RT-2.workspace.wip_preservation_failed"}}, 300
      refute File.exists?(trace)

      assert :ok = WipPreservation.authorize_discard("RT-2")
      assert :ok = Provisioner.recreate("/remote/ws/RT-2", "worker-1", nil, "aiur/RT-2", "RT-2")
      assert File.read!(trace) =~ "mkdir -p"
      refute WipPreservation.discard_authorized?("RT-2")
    end

    test "a local workspace whose save keeps failing is deleted after an authorized discard", %{test_root: test_root, state_dir: state_dir} do
      workspace = cloned_workspace!(test_root, "LOCAL-DISCARD", workspace_wip: [command_timeout_ms: 300])
      File.write!(Path.join(workspace, "README.md"), "changed\n")
      fake_git!(test_root, :hang)

      assert {:error, {:wip_preservation_failed, ^workspace, {:command_timeout, _git, _args, 300}}, ""} = Remove.remove(workspace, nil)
      assert File.exists?(workspace)
      hold = Path.join([state_dir, "wip-preserved", "LOCAL-DISCARD", "hold-alerted.json"])
      assert File.exists?(hold)

      assert :ok = WipPreservation.authorize_discard("LOCAL-DISCARD")
      assert {:ok, _} = Remove.remove(workspace, nil)
      refute File.exists?(workspace)
      refute WipPreservation.discard_authorized?("LOCAL-DISCARD")
      refute File.exists?(hold)
    end
  end

  describe "orchestrator teardown and guarded recreate" do
    test "teardown starts the workspace save only after the runner is gone", %{test_root: test_root} do
      identifier = "TEAR-#{System.unique_integer([:positive])}"
      issue_id = "issue-#{identifier}"
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(test_root, "workspaces"))
      {:ok, workspace} = Layout.workspace_path_for_issue(identifier, nil)
      clone_at!(test_root, workspace)
      File.write!(Path.join(workspace, "README.md"), "changed\n")

      {:ok, agent} = Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> Process.sleep(:infinity) end)
      parent = self()

      tracer =
        spawn(fn ->
          ref = Process.monitor(agent)
          send(parent, :tracer_ready)
          record_order(ref, [])
        end)

      assert_receive :tracer_ready, 1_000

      state = %Orchestrator.State{
        running: %{
          issue_id => %{pid: agent, ref: nil, identifier: identifier, issue: %Issue{id: issue_id, identifier: identifier, state: "Done"}, started_at: DateTime.utc_now()}
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      :erlang.trace_pattern({WorkspaceCleanup, :cleanup_terminal_issue_artifacts, 2}, true, [:global])
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])

      try do
        AgentTeardown.terminate_running_issue(state, issue_id, true)
      after
        :erlang.trace(self(), false, [:call])
        :erlang.trace_pattern({WorkspaceCleanup, :cleanup_terminal_issue_artifacts, 2}, false, [:global])
      end

      assert_receive {:workspace_cleanup_finished, ^identifier, :ok}, 10_000
      send(tracer, {:report, self()})
      assert_receive {:order, [:agent_down, :cleanup_started]}, 1_000
      refute File.exists?(workspace)
    end

    test "Provisioner.recreate has no unguarded entry point and saves the work first", %{test_root: test_root} do
      Code.ensure_loaded!(Provisioner)
      refute function_exported?(Provisioner, :recreate, 2)
      refute function_exported?(Provisioner, :recreate, 4)

      identifier = "GUARD-#{System.unique_integer([:positive])}"
      {workspace, _trace_root} = dirty_refresh_fixture!(test_root, identifier)
      File.write!(Path.join(workspace, "README.md"), "unsaved agent edit\n")

      assert :ok = Provisioner.recreate(workspace, nil, nil, "aiur/#{identifier}", identifier)
      assert [notice] = WipPreservation.pending_notices(workspace, identifier)
      assert notice["tracked_files"] == ["README.md"]
    end
  end
end
