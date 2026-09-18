defmodule Aiur.Workspace.WipPreservationTest do
  # #2743: a dirty workspace must never lose its uncommitted work to the
  # stale-leftover recreate (#577) or to a workspace removal.
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Orchestrator.{AgentTeardown, WorkspaceCleanup}
  alias Aiur.Workspace.{Layout, Provisioner, Refresh, Remove, WipPreservation}
  alias Aiur.Workspace.WipPreservation.Retention

  setup do
    test_root = Aiur.TestSupport.tmp_root!("wip-preservation")
    File.mkdir_p!(test_root)
    state_dir = Path.join(test_root, "runtime-state")
    Aiur.TestSupport.put_runtime_state_dir!(state_dir)

    on_exit(fn -> File.rm_rf(test_root) end)
    {:ok, test_root: test_root, state_dir: state_dir}
  end

  describe "stale-leftover recreate (exit 65)" do
    test "saves every change before the recreate and the artifact restores the tree exactly", %{test_root: test_root} do
      identifier = "WIP-#{System.unique_integer([:positive])}"
      {workspace, trace_file} = dirty_refresh_fixture!(test_root, identifier)
      make_everything_dirty!(workspace)
      before = snapshot(workspace)
      subscribe!("ticket.#{identifier}.workspace.wip_preserved")

      assert :ok = Workspace.run_before_run_hook(workspace, todo_issue(identifier))

      # The recreate ran: a fresh clone on the base, with nothing dirty left.
      assert trace_count(trace_file) == 2
      assert git!(["-C", workspace, "status", "--porcelain", "--untracked-files=all"]) == ""
      refute snapshot(workspace) == before

      assert [artifact] = WipPreservation.pending_notices(workspace)
      assert File.regular?(artifact["files"]["tracked_patch"])
      assert File.regular?(artifact["files"]["untracked_tar"])
      assert File.regular?(artifact["files"]["unpushed_bundle"])
      assert artifact["branch"] == "aiur/#{identifier}"
      refute String.starts_with?(artifact["artifact_dir"], workspace)

      assert Enum.sort(artifact["tracked_files"]) == ["README.md", "data.bin", "doomed.txt", "staged-new.txt"]
      assert Enum.sort(artifact["untracked_files"]) == ["notes/draft.md", "untracked.bin"]

      assert_receive {:event, %{topic: "ticket." <> _} = event}, 1_000
      assert event["message"] =~ artifact["artifact_dir"]

      run_restore!(artifact)
      assert snapshot(workspace) == before
    end

    test "a failed save keeps the dirty workspace, skips the recreate and names the hold reason", %{
      test_root: test_root,
      state_dir: state_dir
    } do
      identifier = "WIP-FAIL-#{System.unique_integer([:positive])}"
      {workspace, trace_file} = dirty_refresh_fixture!(test_root, identifier)
      make_everything_dirty!(workspace)
      before = snapshot(workspace)
      block_state_dir!(state_dir)
      subscribe!("ticket.#{identifier}.workspace.wip_preservation_failed")

      assert {:error, {:wip_preservation_failed, ^workspace, {:artifact_dir_unwritable, _path, _reason}}} =
               Workspace.run_before_run_hook(workspace, todo_issue(identifier))

      assert trace_count(trace_file) == 1
      assert snapshot(workspace) == before
      assert git!(["-C", workspace, "status", "--porcelain"]) =~ "README.md"

      assert_receive {:event, %{topic: "ticket." <> _} = event}, 1_000
      assert event["message"] =~ "held"
      assert event["message"] =~ workspace
    end

    test "a remote worker holds the ticket instead of deleting its dirty checkout" do
      context = %{issue_id: 1, issue_identifier: "remote-wip", issue_state: "todo", issue_labels: [], pr_head_ref: nil, branch_name: "aiur/remote-wip"}
      error = {:error, {:workspace_hook_failed, "before_run", 65, ""}}

      assert {:error, {:wip_preservation_failed, "/remote/ws/remote-wip", :remote_worker_unsupported}} =
               Refresh.maybe_recreate_stale_workspace(
                 error,
                 elem(error, 1),
                 "exit 65",
                 "/remote/ws/remote-wip",
                 context,
                 "worker-1"
               )
    end
  end

  describe "agent runner" do
    test "the next turn input names the artifact and its restore commands", %{test_root: test_root} do
      identifier = "WIP-TURN-#{System.unique_integer([:positive])}"
      codex_trace = Path.join(test_root, "codex.trace")
      {workspace, _trace_file} = dirty_refresh_fixture!(test_root, identifier, fake_codex_opts!(test_root, codex_trace))
      File.write!(Path.join(workspace, "README.md"), "unsaved agent edit\n")

      issue = %Issue{id: "issue-#{identifier}", identifier: identifier, title: "WIP turn", state: "todo", labels: ["agent:todo"]}
      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(issue, test_pid, issue_state_fetcher: fn [_id] -> {:ok, [%{issue | state: "Done"}]} end)
        end)

      assert {:ok, :ok} = Task.yield(task, 20_000)

      turn_start =
        codex_trace
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.find(&(&1 =~ ~s("method":"turn/start")))

      assert is_binary(turn_start), "no turn/start in codex trace:\n#{File.read!(codex_trace)}"
      input = turn_start |> String.replace_prefix("JSON:", "") |> Jason.decode!() |> get_in(["params", "input"]) |> inspect()

      [artifact] = delivered_artifacts(workspace)
      assert input =~ "Aiur preserved uncommitted work"
      assert input =~ artifact["artifact_dir"]
      assert input =~ "git apply --binary"
      assert is_binary(artifact["notice_delivered_at"])
      assert WipPreservation.pending_notices(workspace) == []
    end

    test "a failed save holds the ticket on a before_run pause with the dirty workspace intact", %{
      test_root: test_root,
      state_dir: state_dir
    } do
      identifier = "WIP-HOLD-#{System.unique_integer([:positive])}"
      codex_trace = Path.join(test_root, "codex.trace")
      {workspace, trace_file} = dirty_refresh_fixture!(test_root, identifier, fake_codex_opts!(test_root, codex_trace))
      File.write!(Path.join(workspace, "README.md"), "unsaved agent edit\n")
      block_state_dir!(state_dir)

      issue = %Issue{id: "issue-#{identifier}", identifier: identifier, title: "WIP hold", state: "todo", labels: ["agent:todo"]}
      test_pid = self()
      task = Task.async(fn -> AgentRunner.run(issue, test_pid) end)
      on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)

      issue_id = issue.id
      assert_receive {:worker_control_state, ^issue_id, :paused, %{kind: :before_run_failure}}, 10_000
      refute_receive {:codex_worker_update, ^issue_id, %{event: :session_started}}, 200

      assert File.read!(Path.join(workspace, "README.md")) == "unsaved agent edit\n"
      assert trace_count(trace_file) == 1
      refute File.exists?(codex_trace)
      assert File.read!(Path.join([workspace, "logs", "agent.ndjson"])) =~ "wip_preservation_failed"

      Task.shutdown(task, :brutal_kill)
    end
  end

  describe "workspace removal" do
    test "removing a dirty workspace saves it first", %{test_root: test_root} do
      workspace = cloned_workspace!(test_root, "RM-1")
      File.write!(Path.join(workspace, "README.md"), "changed\n")
      File.write!(Path.join(workspace, "new.txt"), "new\n")
      before = snapshot(workspace)

      assert {:ok, _} = Remove.remove(workspace, nil)
      refute File.exists?(workspace)

      assert [artifact] = WipPreservation.pending_notices(workspace)
      clone_at!(test_root, workspace)
      run_restore!(artifact)
      assert snapshot(workspace) == before
    end

    test "a failed save keeps the workspace", %{test_root: test_root, state_dir: state_dir} do
      workspace = cloned_workspace!(test_root, "RM-2")
      File.write!(Path.join(workspace, "README.md"), "changed\n")
      block_state_dir!(state_dir)

      assert {:error, {:wip_preservation_failed, ^workspace, _reason}, ""} = Remove.remove(workspace, nil)
      assert File.read!(Path.join(workspace, "README.md")) == "changed\n"
    end

    test "a clean workspace is removed without an artifact", %{test_root: test_root} do
      workspace = cloned_workspace!(test_root, "RM-3")

      assert {:ok, _} = Remove.remove(workspace, nil)
      refute File.exists?(workspace)
      assert {:ok, dir} = WipPreservation.workspace_dir("RM-3")
      refute File.exists?(dir)
    end
  end

  describe "retention" do
    test "keeps the newest artifacts per workspace and never prunes the newest", %{test_root: test_root} do
      workspace = cloned_workspace!(test_root, "KEEP-1")
      keep = WipPreservation.keep_per_workspace()

      artifacts =
        for n <- 1..(keep + 2) do
          File.write!(Path.join(workspace, "README.md"), "edit #{n}\n")
          assert {:ok, artifact} = WipPreservation.preserve(workspace)
          artifact
        end

      assert {:ok, dir} = WipPreservation.workspace_dir("KEEP-1")
      kept = dir |> File.ls!() |> Enum.sort() |> Enum.map(&Path.join(dir, &1))
      assert length(kept) == keep
      assert kept == artifacts |> Enum.take(-keep) |> Enum.map(& &1["artifact_dir"])
      assert File.dir?(List.last(artifacts)["artifact_dir"])
    end
  end

  describe "untracked names" do
    # Review of #2744, finding 1: tar's `-t` listing escapes these names, so a
    # listing check failed every save of such a workspace.
    test "a backslash, a newline, non-ASCII bytes and a leading -- are saved and restored", %{test_root: test_root} do
      workspace = cloned_workspace!(test_root, "ODD-1")
      names = ["back\\slash.txt", "new\nline.txt", "ñame-日本.txt", "--dash.txt", "dir/--nested\\x.txt"]

      for name <- names do
        path = Path.join(workspace, name)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "content of #{inspect(name)}\n")
      end

      before = snapshot(workspace)

      assert {:ok, _} = Remove.remove(workspace, nil)
      refute File.exists?(workspace)

      assert [artifact] = WipPreservation.pending_notices(workspace)
      assert Enum.sort(artifact["untracked_files"]) == Enum.sort(names)

      clone_at!(test_root, workspace)
      run_restore!(artifact)
      assert snapshot(workspace) == before
    end
  end

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

      assert [manifest] = manifests("CAP-1")
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
      {workspace, trace_file} = dirty_refresh_fixture!(test_root, identifier, workspace_wip: [command_timeout_ms: 500])
      File.write!(Path.join(workspace, "README.md"), "unsaved agent edit\n")
      before = snapshot(workspace)
      fake_git!(test_root, :hang)

      started = System.monotonic_time(:millisecond)

      assert {:error, {:wip_preservation_failed, ^workspace, {:command_timeout, _git, _args, 500}}} =
               Workspace.run_before_run_hook(workspace, todo_issue(identifier))

      assert System.monotonic_time(:millisecond) - started < 10_000
      assert trace_count(trace_file) == 1
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
      assert [artifact] = WipPreservation.pending_notices(workspace)
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
      assert [artifact] = WipPreservation.pending_notices(workspace)

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

      assert_receive :tracer_ready

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
      {workspace, _trace_file} = dirty_refresh_fixture!(test_root, identifier)
      File.write!(Path.join(workspace, "README.md"), "unsaved agent edit\n")

      assert :ok = Provisioner.recreate(workspace, nil, nil, "aiur/#{identifier}", identifier)
      assert [notice] = WipPreservation.pending_notices(workspace, identifier)
      assert notice["tracked_files"] == ["README.md"]
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp dirty_refresh_fixture!(test_root, identifier, workflow_opts \\ []) do
    source = committed_repo!(Path.join(test_root, "source"))
    remote = Path.join(test_root, "origin.git")
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "before-run.trace")
    git!(["clone", "--quiet", "--bare", source, remote])

    write_workflow_file!(
      Workflow.workflow_file_path(),
      [
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: """
        git clone --quiet #{shell_quote(remote)} .
        git config user.email t@example.com
        git config user.name T
        git checkout --quiet -b "aiur/$(basename "$PWD")" origin/main
        """,
        hook_before_run: """
        printf 'attempt\\n' >> #{shell_quote(trace_file)}
        if [ ! -d .git ]; then
          find . -mindepth 1 -maxdepth 1 -exec rm -rf {} +
          git clone --quiet #{shell_quote(remote)} .
          git config user.email t@example.com
          git config user.name T
          git checkout --quiet -b "aiur/$(basename "$PWD")" origin/main
        elif ! git diff --quiet || ! git diff --cached --quiet; then
          exit 65
        fi
        """
      ] ++ workflow_opts
    )

    assert {:ok, workspace} = Workspace.create_for_issue(identifier)
    {workspace, trace_file}
  end

  # Modified, staged, deleted, staged-new, binary tracked and binary untracked
  # files, a nested untracked file, an executable bit and an unpushed commit.
  defp make_everything_dirty!(workspace) do
    File.write!(Path.join(workspace, "local-only.txt"), "committed but never pushed\n")
    git!(["-C", workspace, "add", "local-only.txt"])
    git!(["-C", workspace, "commit", "--quiet", "-m", "local"])

    File.write!(Path.join(workspace, "README.md"), "initial\nunstaged edit\n")
    File.write!(Path.join(workspace, "staged-new.txt"), "staged\n")
    git!(["-C", workspace, "add", "staged-new.txt"])
    File.rm!(Path.join(workspace, "doomed.txt"))
    File.write!(Path.join(workspace, "data.bin"), binary_blob(2))
    File.chmod!(Path.join(workspace, "data.bin"), 0o755)
    File.mkdir_p!(Path.join(workspace, "notes"))
    File.write!(Path.join(workspace, "notes/draft.md"), "untracked draft\n")
    File.write!(Path.join(workspace, "untracked.bin"), binary_blob(3))
  end

  defp committed_repo!(path) do
    File.mkdir_p!(path)
    git!(["-C", path, "init", "--quiet", "-b", "main"])
    git!(["-C", path, "config", "user.email", "t@example.com"])
    git!(["-C", path, "config", "user.name", "T"])
    File.write!(Path.join(path, "README.md"), "initial\n")
    File.write!(Path.join(path, "doomed.txt"), "delete me\n")
    File.write!(Path.join(path, "data.bin"), binary_blob(1))
    git!(["-C", path, "add", "."])
    git!(["-C", path, "commit", "--quiet", "-m", "initial"])
    path
  end

  # A workspace checkout with a pushed base, as a real clone has.
  defp cloned_workspace!(test_root, leaf, workflow_opts \\ []) do
    write_workflow_file!(Workflow.workflow_file_path(), [workspace_root: Path.join(test_root, "workspaces")] ++ workflow_opts)
    clone_at!(test_root, Path.join([test_root, "workspaces", leaf]))
  end

  defp clone_at!(test_root, workspace) do
    git!(["clone", "--quiet", origin!(test_root), workspace])
    git!(["-C", workspace, "config", "user.email", "t@example.com"])
    git!(["-C", workspace, "config", "user.name", "T"])
    workspace
  end

  defp origin!(test_root) do
    origin = Path.join(test_root, "origin.git")
    unless File.dir?(origin), do: git!(["clone", "--quiet", "--bare", committed_repo!(Path.join(test_root, "source")), origin])
    origin
  end

  # A `git` that stalls on `ls-files`: for `seconds` then runs, or for good.
  defp fake_git!(test_root, mode) do
    real_git = System.find_executable("git")
    path = Path.join(test_root, "stalling-git")

    stall =
      case mode do
        :hang -> "exec sleep 30"
        {:delay, seconds} -> "sleep #{seconds}"
      end

    File.write!(path, """
    #!/bin/sh
    case " $* " in
      *" ls-files "*) #{stall} ;;
    esac
    exec #{shell_quote(real_git)} "$@"
    """)

    File.chmod!(path, 0o755)
    Application.put_env(:aiur, :wip_preservation_git, path)
    on_exit(fn -> Application.delete_env(:aiur, :wip_preservation_git) end)
    path
  end

  defp manifests(leaf) do
    {:ok, dir} = WipPreservation.workspace_dir(leaf)

    dir
    |> File.ls!()
    |> Enum.filter(&Retention.artifact_name?/1)
    |> Enum.sort()
    |> Enum.map(&(Path.join([dir, &1, "manifest.json"]) |> File.read!() |> Jason.decode!()))
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp record_order(ref, acc) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> record_order(ref, [:agent_down | acc])
      {:trace, _pid, :call, {WorkspaceCleanup, :cleanup_terminal_issue_artifacts, _args}} -> record_order(ref, [:cleanup_started | acc])
      {:report, to} -> send(to, {:order, Enum.reverse(acc)})
    end
  end

  defp save!(workspace, content) do
    File.write!(Path.join(workspace, "README.md"), content <> "\n")
    assert {:ok, artifact} = WipPreservation.preserve(workspace)
    artifact["artifact_dir"]
  end

  # Renames a save so its stamp says it was written `days` ago.
  defp age!(dir, days) do
    stamp = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> Calendar.strftime("%Y%m%dT%H%M%S")
    aged = Path.join(Path.dirname(dir), stamp <> ".000000Z-#{days}")
    File.rename!(dir, aged)
    aged
  end

  defp dir_bytes(dir), do: dir |> File.ls!() |> Enum.map(&File.stat!(Path.join(dir, &1)).size) |> Enum.sum()

  defp binary_blob(seed), do: for(n <- 0..4095, into: <<>>, do: <<rem(n * seed + 7, 256)>>)

  defp fake_codex_opts!(test_root, codex_trace) do
    codex_binary = Path.join(test_root, "fake-codex")

    File.write!(codex_binary, """
    #!/bin/sh
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> #{shell_quote(codex_trace)}
      request_id=$(printf '%s' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p')
      case "$line" in
        *'"method":"initialize"'*) printf '{"id":%s,"result":{}}\\n' "$request_id" ;;
        *'"method":"thread/start"'*) printf '{"id":%s,"result":{"thread":{"id":"thread-wip"}}}\\n' "$request_id" ;;
        *'"method":"turn/start"'*)
          printf '{"id":%s,"result":{"turn":{"id":"turn-wip"}}}\\n' "$request_id"
          printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
    [codex_command: "#{codex_binary} app-server", max_turns: 1]
  end

  defp block_state_dir!(state_dir) do
    File.mkdir_p!(Path.dirname(state_dir))
    File.rm_rf!(state_dir)
    File.write!(state_dir, "not a directory\n")
  end

  defp delivered_artifacts(workspace) do
    {:ok, dir} = WipPreservation.workspace_dir(Path.basename(workspace))

    dir
    |> File.ls!()
    |> Enum.filter(&Retention.artifact_name?/1)
    |> Enum.map(&(Path.join([dir, &1, "manifest.json"]) |> File.read!() |> Jason.decode!()))
  end

  defp run_restore!(artifact) do
    script = Enum.join(artifact["restore_commands"], " && ")
    {output, status} = System.cmd("sh", ["-c", script], stderr_to_stdout: true)
    assert status == 0, "restore failed (#{status}):\n#{script}\n#{output}"
  end

  # The content and executable bit of every file Git can see, tracked or not.
  defp snapshot(workspace) do
    workspace
    |> then(&git!(["-C", &1, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]))
    |> String.split(<<0>>, trim: true)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?(Path.join(workspace, &1)))
    |> Map.new(fn path ->
      full = Path.join(workspace, path)
      {path, {File.read!(full), Bitwise.band(File.stat!(full).mode, 0o111) != 0}}
    end)
  end

  defp subscribe!(topic) do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe(topic)
    on_exit(fn -> Publisher.set_tracked_fn(fn _ -> true end) end)
  end

  defp todo_issue(identifier),
    do: %Issue{id: "issue-#{identifier}", identifier: identifier, title: "WIP", state: "todo", labels: ["agent:todo"]}

  defp trace_count(path), do: path |> File.read!() |> String.split("\n", trim: true) |> length()

  defp git!(args) do
    {output, 0} = System.cmd("git", args, stderr_to_stdout: true)
    output
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
