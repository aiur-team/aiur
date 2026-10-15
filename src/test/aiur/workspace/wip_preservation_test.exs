defmodule Aiur.Workspace.WipPreservationTest do
  # #2743: stale-leftover recreation (#577) and removal must preserve dirty work.
  use Aiur.TestSupport

  import Aiur.WipPreservationFixtures

  alias Aiur.Workspace.{Refresh, Remove, WipPreservation}

  setup :runtime_state_dir!

  describe "stale-leftover recreate (exit 65)" do
    test "saves every change before the recreate and the artifact restores the tree exactly", %{test_root: test_root} do
      identifier = "WIP-#{System.unique_integer([:positive])}"
      {workspace, trace_root} = dirty_refresh_fixture!(test_root, identifier)
      make_everything_dirty!(workspace)
      before = snapshot(workspace)
      subscribe!("ticket.#{identifier}.workspace.wip_preserved")

      assert :ok = Workspace.run_before_run_hook(workspace, todo_issue(identifier))

      # The recreate ran: a fresh clone on the base, with nothing dirty left.
      assert trace_count(trace_path(trace_root, todo_issue(identifier))) == 2
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
      {workspace, trace_root} = dirty_refresh_fixture!(test_root, identifier)
      make_everything_dirty!(workspace)
      before = snapshot(workspace)
      block_state_dir!(state_dir)
      subscribe!("ticket.#{identifier}.workspace.wip_preservation_failed")

      assert {:error, {:wip_preservation_failed, ^workspace, {:artifact_dir_unwritable, _path, _reason}}} =
               Workspace.run_before_run_hook(workspace, todo_issue(identifier))

      assert trace_count(trace_path(trace_root, todo_issue(identifier))) == 1
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
      {workspace, _trace_root} = dirty_refresh_fixture!(test_root, identifier, fake_codex_opts!(test_root, codex_trace))
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
      {workspace, trace_root} = dirty_refresh_fixture!(test_root, identifier, fake_codex_opts!(test_root, codex_trace))
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
      assert trace_count(trace_path(trace_root, issue)) == 1
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

    test "a failed save keeps the dirty checkout without running before_remove", %{test_root: test_root, state_dir: state_dir} do
      workspace = cloned_workspace!(test_root, "RM-2")
      File.write!(Path.join(workspace, "README.md"), "changed\n")
      marker = Path.join(test_root, "remove-hook-ran")
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), workspace_root: test_root, hook_before_remove: "touch #{marker}")
      block_state_dir!(state_dir)

      assert {:error, {:wip_preservation_failed, ^workspace, _reason}, ""} = Remove.remove(workspace, nil)
      assert File.read!(Path.join(workspace, "README.md")) == "changed\n"
      refute File.exists?(marker)
    end

    test "a clean workspace is removed without an artifact", %{test_root: test_root} do
      workspace = cloned_workspace!(test_root, "RM-3")

      assert {:ok, _} = Remove.remove(workspace, nil)
      refute File.exists?(workspace)
      assert {:ok, dir} = WipPreservation.workspace_dir("RM-3")
      refute File.exists?(dir)
    end

    test "a clean checkout with a local-only commit is saved and restored", %{test_root: test_root} do
      identifier = "RM-LOCAL-COMMIT-#{System.unique_integer([:positive])}"
      workspace = cloned_workspace!(test_root, identifier)
      File.write!(Path.join(workspace, "local-only.txt"), "committed work\n")
      git!(["-C", workspace, "add", "local-only.txt"])
      git!(["-C", workspace, "commit", "--quiet", "-m", "local work"])
      before = snapshot(workspace)

      assert git!(["-C", workspace, "status", "--porcelain"]) == ""
      assert {:ok, _} = Remove.remove(workspace, nil, ticket: identifier)
      refute File.exists?(workspace)

      assert [artifact] = WipPreservation.pending_notices(workspace, identifier)
      assert File.regular?(artifact["files"]["unpushed_bundle"])
      clone_at!(test_root, workspace)
      run_restore!(artifact)
      assert snapshot(workspace) == before
    end

    test "a failed save after before_remove keeps its changes and the first restore notice", %{
      test_root: test_root
    } do
      identifier = "RM-HOOK-FAIL-#{System.unique_integer([:positive])}"
      workspace = cloned_workspace!(test_root, identifier)
      File.write!(Path.join(workspace, "README.md"), "agent edit\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        hook_before_remove: "touch hook-created.txt"
      )

      fake_git!(test_root, {:fail_on_ls_files, 2})

      assert {:error, {:wip_preservation_failed, ^workspace, _reason}, ""} =
               Remove.remove(workspace, nil, ticket: identifier)

      assert File.dir?(workspace)
      assert File.regular?(Path.join(workspace, "hook-created.txt"))
      assert [_artifact] = WipPreservation.pending_notices(workspace, identifier)
    end

    test "work written by before_remove is saved before the workspace is deleted", %{test_root: test_root} do
      identifier = "RM-HOOK-#{System.unique_integer([:positive])}"
      workspace = cloned_workspace!(test_root, identifier)
      File.write!(Path.join(workspace, "README.md"), "agent edit\n")
      before = snapshot(workspace)

      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        workspace_root: test_root,
        hook_before_remove: "touch hook-created.txt"
      )

      assert {:ok, _} = Remove.remove(workspace, nil, ticket: identifier)
      refute File.exists?(workspace)

      assert [artifact] = WipPreservation.pending_notices(workspace, identifier)
      assert Enum.sort(artifact["tracked_files"]) == ["README.md"]
      assert "hook-created.txt" in artifact["untracked_files"]

      clone_at!(test_root, workspace)
      run_restore!(artifact)
      assert File.read!(Path.join(workspace, "README.md")) == elem(before["README.md"], 0)
      assert File.regular?(Path.join(workspace, "hook-created.txt"))
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
    # #2744: tar escapes these names in `-t`, so listing checks reject valid saves.
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

      artifacts = WipPreservation.pending_notices(workspace)
      artifact = Enum.find(artifacts, &(&1["action"] == "remove the workspace"))
      assert Enum.sort(artifact["untracked_files"]) == Enum.sort(names)

      clone_at!(test_root, workspace)
      Enum.each(artifacts, &run_restore!/1)
      assert snapshot(workspace) == before
    end
  end
end
