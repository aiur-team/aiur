defmodule Aiur.WipPreservationFixtures do
  @moduledoc false
  # Shared checkout, stalling-git and manifest fixtures for the
  # `Aiur.Workspace.WipPreservation` tests.
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Aiur.TestSupport, only: [write_workflow_file!: 2]

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Issue
  alias Aiur.Orchestrator.WorkspaceCleanup
  alias Aiur.Workflow
  alias Aiur.Workspace
  alias Aiur.Workspace.Context
  alias Aiur.Workspace.WipPreservation
  alias Aiur.Workspace.WipPreservation.Retention

  def runtime_state_dir!(_context) do
    test_root = Aiur.TestSupport.tmp_root!("wip-preservation")
    File.mkdir_p!(test_root)
    state_dir = Path.join(test_root, "runtime-state")
    Aiur.TestSupport.put_runtime_state_dir!(state_dir)

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(test_root, unset: [:runtime_state_dir]) end)
    {:ok, test_root: test_root, state_dir: state_dir}
  end

  def dirty_refresh_fixture!(test_root, identifier, workflow_opts \\ []) do
    source = committed_repo!(Path.join(test_root, "source"))
    remote = Path.join(test_root, "origin.git")
    workspace_root = Path.join(test_root, "workspaces")
    trace_root = Path.join(test_root, "before-run-traces")
    git!(["clone", "--quiet", "--bare", source, remote])

    File.mkdir_p!(trace_root)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      [
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: """
        PATH="/usr/bin:/bin:$PATH"
        git -C "$PWD" clone --quiet #{shell_quote(remote)} .
        git -C "$PWD" config user.email t@example.com
        git -C "$PWD" config user.name T
        git -C "$PWD" checkout --quiet -b "aiur/$(basename "$PWD")" origin/main
        """,
        hook_before_run: """
        PATH="/usr/bin:/bin:$PATH"
        printf 'attempt\\n' >> #{shell_quote(trace_root)}/"${AIUR_TICKET_BRANCH#aiur/}"
        if [ ! -d .git ]; then
          find . -mindepth 1 -maxdepth 1 -exec rm -rf {} +
          git -C "$PWD" clone --quiet #{shell_quote(remote)} .
          git -C "$PWD" config user.email t@example.com
          git -C "$PWD" config user.name T
          git -C "$PWD" checkout --quiet -b "aiur/$(basename "$PWD")" origin/main
        elif ! git diff --quiet || ! git diff --cached --quiet; then
          exit 65
        fi
        """
      ] ++ workflow_opts
    )

    assert {:ok, workspace} = Workspace.create_for_issue(identifier)
    {workspace, trace_root}
  end

  # Modified, staged, deleted, staged-new, binary tracked and binary untracked
  # files, a nested untracked file, an executable bit and an unpushed commit.
  def make_everything_dirty!(workspace) do
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

  def committed_repo!(path) do
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
  def cloned_workspace!(test_root, leaf, workflow_opts \\ []) do
    write_workflow_file!(Workflow.workflow_file_path(), [workspace_root: Path.join(test_root, "workspaces")] ++ workflow_opts)
    clone_at!(test_root, Path.join([test_root, "workspaces", leaf]))
  end

  def clone_at!(test_root, workspace) do
    git!(["clone", "--quiet", origin!(test_root), workspace])
    git!(["-C", workspace, "config", "user.email", "t@example.com"])
    git!(["-C", workspace, "config", "user.name", "T"])
    workspace
  end

  def origin!(test_root) do
    origin = Path.join(test_root, "origin.git")
    unless File.dir?(origin), do: git!(["clone", "--quiet", "--bare", committed_repo!(Path.join(test_root, "source")), origin])
    origin
  end

  # A `git` that stalls on `ls-files`: for `seconds` then runs, or for good.
  def fake_git!(test_root, mode) do
    real_git = System.find_executable("git")
    path = Path.join(test_root, "stalling-git")

    stall =
      case mode do
        :hang ->
          "exec sleep 30"

        {:delay, seconds} ->
          "touch #{shell_quote(Path.join(test_root, "ls-files-entered"))}; sleep #{seconds}"

        {:fail_on_ls_files, attempt} ->
          count = shell_quote(Path.join(test_root, "ls-files-count"))
          "count=$(cat #{count} 2>/dev/null || echo 0); count=$((count + 1)); echo $count > #{count}; if [ \"$count\" -eq #{attempt} ]; then exit 42; fi"
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

  def manifests(leaf) do
    {:ok, dir} = WipPreservation.workspace_dir(leaf)

    dir
    |> File.ls!()
    |> Enum.filter(&Retention.artifact_name?/1)
    |> Enum.sort()
    |> Enum.map(&(Path.join([dir, &1, "manifest.json"]) |> File.read!() |> Jason.decode!()))
  end

  def assert_eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts > 0 -> Process.sleep(100) && assert_eventually(fun, attempts - 1)
      true -> flunk("condition not met in time")
    end
  end

  def zombie?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> stat |> String.split(") ", parts: 2) |> List.last() |> String.starts_with?("Z")
      {:error, _reason} -> true
    end
  end

  def mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  def record_order(ref, acc) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> record_order(ref, [:agent_down | acc])
      {:trace, _pid, :call, {WorkspaceCleanup, :cleanup_terminal_issue_artifacts, _args}} -> record_order(ref, [:cleanup_started | acc])
      {:report, to} -> send(to, {:order, Enum.reverse(acc)})
    end
  end

  def save!(workspace, content) do
    File.write!(Path.join(workspace, "README.md"), content <> "\n")
    assert {:ok, artifact} = WipPreservation.preserve(workspace)
    artifact["artifact_dir"]
  end

  # Renames a save so its stamp says it was written `days` ago.
  def age!(dir, days) do
    stamp = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> Calendar.strftime("%Y%m%dT%H%M%S")
    aged = Path.join(Path.dirname(dir), stamp <> ".000000Z-#{days}")
    File.rename!(dir, aged)
    aged
  end

  def dir_bytes(dir), do: dir |> File.ls!() |> Enum.map(&File.stat!(Path.join(dir, &1)).size) |> Enum.sum()

  def binary_blob(seed), do: for(n <- 0..4095, into: <<>>, do: <<rem(n * seed + 7, 256)>>)

  def fake_codex_opts!(test_root, codex_trace) do
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

  def block_state_dir!(state_dir) do
    File.mkdir_p!(Path.dirname(state_dir))
    File.rm_rf!(state_dir)
    File.write!(state_dir, "not a directory\n")
  end

  def delivered_artifacts(workspace) do
    {:ok, dir} = WipPreservation.workspace_dir(Path.basename(workspace))

    dir
    |> File.ls!()
    |> Enum.filter(&Retention.artifact_name?/1)
    |> Enum.map(&(Path.join([dir, &1, "manifest.json"]) |> File.read!() |> Jason.decode!()))
  end

  def run_restore!(artifact) do
    script = Enum.join(artifact["restore_commands"], " && ")
    {output, status} = System.cmd("sh", ["-c", script], stderr_to_stdout: true)
    assert status == 0, "restore failed (#{status}):\n#{script}\n#{output}"
  end

  # The content and executable bit of every file Git can see, tracked or not.
  def snapshot(workspace) do
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

  def subscribe!(topic) do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe(topic)
    on_exit(fn -> Publisher.set_tracked_fn(fn _ -> true end) end)
  end

  def todo_issue(identifier),
    do: %Issue{id: "issue-#{identifier}", identifier: identifier, title: "WIP", state: "todo", labels: ["agent:todo"]}

  def trace_path(trace_root, issue),
    do: Path.join(trace_root, String.replace_prefix(Context.build(issue).branch_name, "aiur/", ""))

  def trace_count(path), do: path |> File.read!() |> String.split("\n", trim: true) |> length()

  def git!(args) do
    {output, 0} = Aiur.TestGit.cmd(args)
    output
  end

  def shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
