defmodule Aiur.Workspace.WipPreservationTest do
  # #2743: a dirty workspace must never lose its uncommitted work to the
  # stale-leftover recreate (#577) or to a workspace removal.
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Workspace.{Refresh, Remove, WipPreservation}

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
      git!(["clone", "--quiet", Path.join(test_root, "origin.git"), workspace])
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
  defp cloned_workspace!(test_root, leaf) do
    origin = Path.join(test_root, "origin.git")
    git!(["clone", "--quiet", "--bare", committed_repo!(Path.join(test_root, "source")), origin])
    workspace = Path.join([test_root, "workspaces", leaf])
    git!(["clone", "--quiet", origin, workspace])
    git!(["-C", workspace, "config", "user.email", "t@example.com"])
    git!(["-C", workspace, "config", "user.name", "T"])
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(test_root, "workspaces"))
    workspace
  end

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
