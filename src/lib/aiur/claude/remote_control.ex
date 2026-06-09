defmodule Aiur.Claude.RemoteControl do
  @moduledoc """
  Stateless helpers shared by the Claude Remote Control path.

  Remote Control runs as a flag on an interactive `claude` REPL spawned by
  `Aiur.Claude.ReplAgent`; this module holds the pure utilities that path
  needs but that don't belong to a single session process:

    * `parse_session_url/1` — extract the `https://claude.ai/code/session_…`
      URL the REPL prints to its pane on attach,
    * `ensure_workspace_trusted/2` — pre-seed the per-project trust flag in
      `~/.claude.json` so RC will start in the workspace,
    * `resolve_transcript_path/1` / `newest_transcript/3` — locate the
      session's `.jsonl` transcript so a re-dispatched agent resumes by cwd,
    * `graceful_kill/1` / `graceful_kill_tree/1` — SIGTERM→SIGKILL a tracked
      OS pid (and, for the headless `bash -lc` wrapper, its orphaned subtree),
    * `reap_orphaned_servers/0` — sweep RC debug files left by a crashed aiur.

  ## Workspace trust

  RC refuses to start in an untrusted directory. Unlike the headless
  `--print` path, it honors the per-project `hasTrustDialogAccepted` flag
  in `~/.claude.json`. `ensure_workspace_trusted/2` pre-seeds that one key
  with an atomic, backup-guarded edit. The read-modify-write must be
  serialized by the caller (the Orchestrator's `handle_call`) so
  simultaneous toggles can't clobber each other's keys.
  """

  @session_url_regex ~r{https://claude\.ai/code/session_[A-Za-z0-9]+}
  # On teardown, wait for the RC process to exit after SIGTERM before
  # escalating to SIGKILL.
  @kill_grace_ms 2_000
  @kill_poll_ms 25

  # --------------------------------------------------------------- url parse

  @doc """
  Extract the `https://claude.ai/code/session_…` URL from a captured RC
  output line, or `nil` when absent. The TUI line that carries it is
  `Continue coding in the Claude mobile app or https://claude.ai/code/session_…`.
  """
  @spec parse_session_url(String.t()) :: String.t() | nil
  def parse_session_url(text) when is_binary(text) do
    case Regex.run(@session_url_regex, text) do
      [url | _] -> url
      _ -> nil
    end
  end

  def parse_session_url(_), do: nil

  # ----------------------------------------------------------- trust pre-seed

  @doc """
  Ensure the workspace project is trusted so RC will start. Sets
  `projects.<workspace>.hasTrustDialogAccepted = true` in `~/.claude.json`
  (override with `:path` for tests). The edit is atomic (write to a temp
  file, then rename) and backup-guarded, and idempotent when the flag is
  already set.

  Must be called from a serialized context (the Orchestrator's
  `handle_call`) so concurrent toggles can't clobber each other's keys.
  """
  @spec ensure_workspace_trusted(Path.t(), keyword()) :: :ok | {:error, term()}
  def ensure_workspace_trusted(workspace, opts \\ []) when is_binary(workspace) do
    path = Keyword.get(opts, :path) || default_claude_json()

    with {:ok, raw} <- read_or_empty(path),
         {:ok, config} <- decode_config(raw) do
      projects = Map.get(config, "projects", %{})
      project = Map.get(projects, workspace, %{})

      if Map.get(project, "hasTrustDialogAccepted") == true do
        :ok
      else
        updated_project = Map.put(project, "hasTrustDialogAccepted", true)
        updated = Map.put(config, "projects", Map.put(projects, workspace, updated_project))
        write_atomic(path, Jason.encode!(updated))
      end
    end
  end

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, :enoent} -> {:ok, "{}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_config(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :unexpected_config_shape}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_atomic(path, contents) do
    tmp = path <> ".aiur-tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  # ----------------------------------------------------------- transcript

  @doc """
  Project-dir slug for a workspace path: every `/` and `.` becomes `-`
  (verified against `~/.claude/projects/`).
  """
  @spec workspace_slug(Path.t()) :: String.t()
  def workspace_slug(workspace) when is_binary(workspace) do
    String.replace(workspace, ~r/[\/.]/, "-")
  end

  @doc """
  Resolve the transcript `.jsonl` path for a session.

  With `:transcript_path` set, returns it verbatim. Otherwise resolves the
  newest cwd-matching transcript in the workspace's project dir (cwd+mtime
  rule — see `newest_transcript/2`). Returns `nil` when none is found.
  Shared with `Aiur.Claude.ReplAgent`, whose REPL sessions resolve the same
  way (the interactive `/remote-control` path writes no `bridge-pointer.json`).
  """
  @spec resolve_transcript_path(keyword()) :: Path.t() | nil
  def resolve_transcript_path(opts) do
    case Keyword.get(opts, :transcript_path) do
      path when is_binary(path) ->
        path

      _ ->
        workspace = Keyword.fetch!(opts, :workspace)
        projects_dir = Keyword.get(opts, :projects_dir) || default_projects_dir()
        since = Keyword.get(opts, :since, 0)
        newest_transcript(Path.join(projects_dir, workspace_slug(workspace)), workspace, since)
    end
  end

  @doc """
  Most-recently-modified `.jsonl` in `dir` whose records reference the
  workspace cwd. The project dir is already workspace-scoped, so
  newest-by-mtime is the primary rule; the cwd check guards against a
  stale unrelated file. Returns `nil` when `dir` has no matching file.
  """
  @spec newest_transcript(Path.t(), Path.t(), integer()) :: Path.t() | nil
  def newest_transcript(dir, workspace, since \\ 0) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&(file_mtime_unix(&1) >= since))
        |> Enum.sort_by(&file_mtime/1, {:desc, DateTime})
        |> Enum.find(&transcript_matches_cwd?(&1, workspace))

      {:error, _} ->
        nil
    end
  end

  defp file_mtime(path) do
    DateTime.from_unix!(file_mtime_unix(path))
  end

  defp file_mtime_unix(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp transcript_matches_cwd?(path, workspace) do
    path
    |> read_transcript()
    |> Enum.any?(fn record -> Map.get(record, "cwd") == workspace end)
  end

  defp read_transcript(nil), do: []

  defp read_transcript(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, record} when is_map(record) -> [record]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # ----------------------------------------------------------------- kill

  @doc false
  # SIGTERM the process and block until it actually exits, escalating to
  # SIGKILL if it overstays.
  @spec graceful_kill(nil | integer()) :: :ok
  def graceful_kill(nil), do: :ok

  def graceful_kill(os_pid) when is_integer(os_pid) do
    pid = Integer.to_string(os_pid)
    System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)

    unless await_exit(pid, @kill_grace_ms) do
      System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
      await_exit(pid, @kill_grace_ms)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc false
  # Like graceful_kill/1 but also reaps the process subtree. The headless
  # `claude` backend runs under a `bash -lc` wrapper that does NOT exec, so
  # its `claude`/node grandchildren reparent to init when the bash pid dies
  # and would survive teardown. Descendants are snapshotted while the root is
  # still alive (once it dies the parent link is lost), then each is
  # graceful-killed alongside the root.
  @spec graceful_kill_tree(nil | integer()) :: :ok
  def graceful_kill_tree(nil), do: :ok

  def graceful_kill_tree(os_pid) when is_integer(os_pid) do
    descendants = collect_descendants(os_pid)
    graceful_kill(os_pid)
    Enum.each(descendants, &graceful_kill/1)
    :ok
  end

  defp collect_descendants(pid) when is_integer(pid) do
    children =
      case System.find_executable("pgrep") do
        nil ->
          []

        pgrep ->
          case System.cmd(pgrep, ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
            {out, 0} -> out |> String.split() |> Enum.map(&String.to_integer/1)
            _ -> []
          end
      end

    children ++ Enum.flat_map(children, &collect_descendants/1)
  end

  defp await_exit(pid, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_await_exit(pid, deadline)
  end

  defp do_await_exit(pid, deadline) do
    cond do
      not os_process_alive?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@kill_poll_ms)
        do_await_exit(pid, deadline)
    end
  end

  # --------------------------------------------------------------- reap

  @doc """
  Reap `claude remote-control` servers orphaned by a crashed aiur instance.

  The Orchestrator has no `terminate/2` and does not trap exits, so a
  crash/SIGKILL leaves orphan RC servers holding api.anthropic.com
  sessions. Each server's `--debug-file` path embeds the owning BEAM OS
  pid (`rc-<pid>-<n>.debug`); this reaps only servers whose owner pid is
  no longer alive, so live servers from a side-by-side aiur instance are
  never touched. Stray debug files for dead owners are swept too.
  """
  @spec reap_orphaned_servers() :: :ok
  def reap_orphaned_servers do
    dir = debug_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.match?(&1, ~r/^rc-\d+-\d+.*\.debug$/))
        |> Enum.each(fn entry -> maybe_reap_orphan(Path.join(dir, entry), entry) end)

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Reap agent processes whose working directory lives under `workspace_root`.

  Called on aiur shutdown to kill any `claude`/`node` grandchild the headless
  backend left reparented to init. Scoped strictly to processes whose `cwd` is
  *under* the workspace root (never the root itself), so an operator's
  out-of-band interactive claude — running anywhere else — is never touched.
  """
  @spec reap_workspace_agents(Path.t(), keyword()) :: :ok
  def reap_workspace_agents(workspace_root, opts \\ []) when is_binary(workspace_root) do
    proc_dir = Keyword.get(opts, :proc_dir, "/proc")
    kill_fun = Keyword.get(opts, :kill_fun, &graceful_kill/1)

    workspace_root
    |> workspace_agent_pids(proc_dir)
    |> Enum.each(kill_fun)

    :ok
  end

  defp workspace_agent_pids(workspace_root, proc_dir) do
    case File.ls(proc_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          String.match?(entry, ~r/^\d+$/) and
            workspace_agent?(Path.join(proc_dir, entry), workspace_root)
        end)
        |> Enum.map(&String.to_integer/1)

      _ ->
        []
    end
  end

  defp workspace_agent?(proc_entry, workspace_root) do
    with {:ok, comm} <- File.read(Path.join(proc_entry, "comm")),
         true <- String.trim(comm) in ~w(claude node),
         {:ok, cwd} <- File.read_link(Path.join(proc_entry, "cwd")) do
      cwd != workspace_root and String.starts_with?(cwd <> "/", workspace_root <> "/")
    else
      _ -> false
    end
  end

  defp maybe_reap_orphan(path, entry) do
    case Regex.run(~r/^rc-(\d+)-\d+.*\.debug$/, entry) do
      [_, owner_pid] ->
        unless os_process_alive?(owner_pid) do
          kill_orphan_server(path)
          File.rm(path)
        end

      _ ->
        :ok
    end
  end

  defp os_process_alive?(pid) when is_binary(pid) do
    case System.find_executable("kill") do
      nil ->
        true

      kill ->
        match?({_, 0}, System.cmd(kill, ["-0", pid], stderr_to_stdout: true))
    end
  rescue
    _ -> true
  end

  defp kill_orphan_server(debug_path) do
    case System.find_executable("pkill") do
      nil -> :ok
      pkill -> System.cmd(pkill, ["-f", "remote-control.*#{Regex.escape(debug_path)}"], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp debug_dir, do: Path.join(System.tmp_dir!(), "aiur-rc")

  defp default_claude_json, do: Path.join(System.user_home!(), ".claude.json")

  defp default_projects_dir, do: Path.join([System.user_home!(), ".claude", "projects"])
end
