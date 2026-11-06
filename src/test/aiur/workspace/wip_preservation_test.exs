defmodule Aiur.Workspace.WipPreservationTest do
  # #2743: stale-leftover recreation (#577) and removal must preserve dirty work.
  use Aiur.TestSupport

  import Aiur.WipPreservationFixtures

  alias Aiur.AgentPubSub
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

    # #7543: when the work cannot be saved, the workspace is kept and the
    # worker runs in it. The ticket is not held on a pause nobody resumes.
    test "a failed save keeps the dirty workspace, skips the recreate and dispatches into it", %{
      test_root: test_root,
      state_dir: state_dir
    } do
      identifier = "WIP-FAIL-#{System.unique_integer([:positive])}"
      {workspace, trace_root} = dirty_refresh_fixture!(test_root, identifier)
      make_everything_dirty!(workspace)
      before = snapshot(workspace)
      block_state_dir!(state_dir)
      subscribe!("ticket.#{identifier}.workspace.wip_preservation_failed")
      subscribe!("ticket.#{identifier}.workspace.wip_preservation_skipped")

      assert :ok = Workspace.run_before_run_hook(workspace, todo_issue(identifier))

      # No recreate: the hook ran once and the dirty tree is untouched.
      assert trace_count(trace_path(trace_root, todo_issue(identifier))) == 1
      assert snapshot(workspace) == before
      assert git!(["-C", workspace, "status", "--porcelain"]) =~ "README.md"

      failed = await_topic("ticket.#{identifier}.workspace.wip_preservation_failed")
      assert failed["message"] =~ "could not be saved"

      skipped = await_topic("ticket.#{identifier}.workspace.wip_preservation_skipped")
      assert skipped["needs_attention"] == true
      assert skipped["message"] =~ "dispatched into"
      assert skipped["message"] =~ workspace
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

  describe "untracked files the patch also touches" do
    # #7543: the patch deletes a path the worktree still holds, because the
    # agent dropped it from the index (`git rm --cached`) and kept the bytes.
    # The reverse check of the saved patch must not read the untracked copy.
    test "a path the patch deletes and the worktree still holds untracked is saved and restored", %{
      test_root: test_root
    } do
      identifier = "WIP-UNTRACKED-DELETE-#{System.unique_integer([:positive])}"
      workspace = cloned_workspace!(test_root, identifier)
      git!(["-C", workspace, "rm", "--cached", "--quiet", "doomed.txt"])
      File.write!(Path.join(workspace, "README.md"), "agent edit\n")
      before = snapshot(workspace)

      assert {:ok, _} = Remove.remove(workspace, nil, ticket: identifier)
      refute File.exists?(workspace)

      assert [artifact] = WipPreservation.pending_notices(workspace, identifier)
      assert "doomed.txt" in artifact["tracked_files"]
      assert "doomed.txt" in artifact["untracked_files"]
      refute File.exists?(Path.join(artifact["artifact_dir"], "reverse-check.index"))

      clone_at!(test_root, workspace)
      run_restore!(artifact)
      assert snapshot(workspace) == before
    end

    test "a stale leftover with such a path is recreated instead of holding the ticket", %{test_root: test_root} do
      identifier = "WIP-UNTRACKED-RECREATE-#{System.unique_integer([:positive])}"
      {workspace, trace_root} = dirty_refresh_fixture!(test_root, identifier)
      git!(["-C", workspace, "rm", "--cached", "--quiet", "doomed.txt"])
      File.write!(Path.join(workspace, "README.md"), "agent edit\n")

      assert :ok = Workspace.run_before_run_hook(workspace, todo_issue(identifier))
      assert trace_count(trace_path(trace_root, todo_issue(identifier))) == 2
      assert git!(["-C", workspace, "status", "--porcelain", "--untracked-files=all"]) == ""
      assert [_artifact] = WipPreservation.pending_notices(workspace)
    end
  end

  describe "the copied index of the reverse check" do
    # #7543: the reverse check stages the worktree changes into a copy of the
    # index. The copy is stamped "now", so git reads its stat cache as settled
    # and skips an edit whose size did not change since the checkout wrote the
    # file. The save must still capture that edit and succeed.
    test "a settled stamp on the copied index does not fail a same-size edit", %{test_root: test_root} do
      identifier = "WIP-SAME-SIZE-#{System.unique_integer([:positive])}"
      workspace = cloned_workspace!(test_root, identifier)
      path = Path.join(workspace, "README.md")
      stamp = DateTime.utc_now() |> DateTime.add(-3_600) |> DateTime.to_unix()

      # Park the index and the file on one stamp so the stat cache alone cannot
      # tell the edit from the checkout. "initial\n" and "changed\n" are both
      # eight bytes, so the size does not tell either.
      File.touch!(path, stamp)
      git!(["-C", workspace, "update-index", "--refresh"])
      git!(["-C", workspace, "config", "core.trustctime", "false"])
      File.write!(path, "changed\n")
      File.touch!(path, stamp)
      File.touch!(Path.join([workspace, ".git", "index"]), stamp)

      assert {:ok, _} = Remove.remove(workspace, nil, ticket: identifier)
      refute File.exists?(workspace)

      assert [artifact] = WipPreservation.pending_notices(workspace, identifier)
      assert artifact["complete"] == true
      assert "README.md" in artifact["tracked_files"]
      assert File.read!(artifact["files"]["tracked_patch"]) =~ "+changed"

      clone_at!(test_root, workspace)
      run_restore!(artifact)
      assert File.read!(Path.join(workspace, "README.md")) == "changed\n"
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

    # #7543: a leftover whose work cannot be saved is kept, and the worker runs
    # in it. Holding the ticket on a preflight pause stranded it silently.
    test "a failed save dispatches the worker into the kept workspace and raises attention", %{
      test_root: test_root,
      state_dir: state_dir
    } do
      identifier = "WIP-CONTINUE-#{System.unique_integer([:positive])}"
      codex_trace = Path.join(test_root, "codex.trace")
      {workspace, trace_root} = dirty_refresh_fixture!(test_root, identifier, fake_codex_opts!(test_root, codex_trace))
      File.write!(Path.join(workspace, "README.md"), "unsaved agent edit\n")
      block_state_dir!(state_dir)
      :ok = AgentPubSub.subscribe_agent(identifier)

      issue = %Issue{id: "issue-#{identifier}", identifier: identifier, title: "WIP continue", state: "todo", labels: ["agent:todo"]}
      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(issue, test_pid, issue_state_fetcher: fn [_id] -> {:ok, [%{issue | state: "Done"}]} end)
        end)

      assert {:ok, :ok} = Task.yield(task, 20_000)

      issue_id = issue.id
      refute_receive {:worker_control_state, ^issue_id, :paused, _payload}, 200
      skipped = await_alert("ticket.#{identifier}.workspace.wip_preservation_skipped")
      assert skipped.needs_attention == true
      assert skipped.reason =~ "dispatched into"

      # The workspace was not recreated: the hook ran once and the edit stayed.
      assert File.read!(Path.join(workspace, "README.md")) == "unsaved agent edit\n"
      assert trace_count(trace_path(trace_root, issue)) == 1
      assert File.exists?(codex_trace)
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

  describe "skill mounts" do
    # #4557: the fresh workspace materializes the skill link the saved patch adds.
    test "a patch that adds a materialized skill link restores over the link", %{test_root: test_root} do
      workspace = cloned_workspace!(test_root, "SKILL-1")
      link = ".codex/skills/aiur-agent"
      Aiur.AgentSkills.install(workspace)
      target = File.read_link!(Path.join(workspace, link))
      git!(["-C", workspace, "add", "--force", link])
      File.write!(Path.join(workspace, "README.md"), "initial\nwith a skill link\n")

      assert {:ok, _} = Remove.remove(workspace, nil, ticket: "SKILL-1")
      assert [artifact] = WipPreservation.pending_notices(workspace, "SKILL-1")
      assert link in artifact["tracked_files"]

      clone_at!(test_root, workspace)
      Aiur.AgentSkills.install(workspace)
      assert File.read_link!(Path.join(workspace, link)) == target

      run_restore!(artifact)
      assert File.read_link!(Path.join(workspace, link)) == target
      assert File.read!(Path.join(workspace, "README.md")) == "initial\nwith a skill link\n"
    end
  end
end
