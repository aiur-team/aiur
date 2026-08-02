defmodule Aiur.Workspace.GitMetadata do
  @moduledoc ".git writability probes and stale-lock repair, local and remote, including the git-dir-inside-workspace containment guard."
  alias Aiur.{Config, PathSafety}
  alias Aiur.Workspace.{Checkout, Remote}
  @agent_logs_exclusion "logs/"
  @tool_results_exclusion ".aiur-runtime/"
  @type worker_host :: String.t() | nil

  @doc false
  @spec ensure_paths_excluded(Path.t(), [String.t()]) :: :ok | {:error, term()}
  def ensure_paths_excluded(workspace, exclusions) when is_binary(workspace) and is_list(exclusions) do
    case local_git_metadata_dir(workspace) do
      {:ok, git_dir} ->
        with :ok <- ensure_git_dir_inside_workspace(git_dir, workspace),
             do: append_exclusions(git_dir, exclusions)

      :not_git ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec ensure_agent_logs_excluded(Path.t(), worker_host()) :: :ok | {:error, term()}
  def ensure_agent_logs_excluded(workspace, worker_host \\ nil)

  def ensure_agent_logs_excluded(workspace, nil) when is_binary(workspace) do
    case ensure_paths_excluded(workspace, [@agent_logs_exclusion, @tool_results_exclusion]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:workspace_git_metadata_unwritable, workspace, reason}}
    end
  end

  # AgentEventLog only writes workspace-local logs. Remote workspaces therefore
  # have no Aiur-created logs directory to exclude.
  def ensure_agent_logs_excluded(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host),
      do: :ok

  @doc false
  @spec ensure_tool_results_excluded(Path.t()) :: :ok | {:error, term()}
  def ensure_tool_results_excluded(workspace) when is_binary(workspace) do
    case ensure_paths_excluded(workspace, [@tool_results_exclusion]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:workspace_git_metadata_unwritable, workspace, reason}}
    end
  end

  @spec ensure_git_metadata_writable(Path.t(), worker_host()) :: :ok | {:error, term()}
  def ensure_git_metadata_writable(workspace, worker_host \\ nil)

  def ensure_git_metadata_writable(workspace, nil) when is_binary(workspace) do
    with {:ok, paths} <- local_git_metadata_probe_paths(workspace),
         :ok <- probe_lock_files(paths) do
      probe_git_index_write(workspace)
    else
      :not_git -> :ok
      {:error, reason} -> {:error, {:workspace_git_metadata_unwritable, workspace, reason}}
    end
  end

  def ensure_git_metadata_writable(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    script =
      [
        "set -eu",
        Remote.remote_shell_assign("workspace", workspace),
        "if ! git -C \"$workspace\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
        "  exit 0",
        "fi",
        "git_dir=\"$(git -C \"$workspace\" rev-parse --git-dir)\"",
        "case \"$git_dir\" in",
        "  /*) ;;",
        "  *) git_dir=\"$workspace/$git_dir\" ;;",
        "esac",
        "workspace_real=\"$(cd \"$workspace\" && pwd -P)\"",
        "git_dir_real=\"$(cd \"$git_dir\" && pwd -P)\"",
        "case \"$git_dir_real/\" in",
        "  \"$workspace_real\"/*) ;;",
        "  *) echo \"git metadata outside workspace: $git_dir_real\" >&2; exit 31 ;;",
        "esac",
        "probe_lock() {",
        "  lock_path=\"$1\"",
        "  mkdir -p \"$(dirname \"$lock_path\")\"",
        "  rm -f \"$lock_path\"",
        "  ( set -C; : > \"$lock_path\" )",
        "  rm -f \"$lock_path\"",
        "}",
        "probe_lock \"$git_dir_real/index.lock\"",
        "probe_lock \"$git_dir_real/FETCH_HEAD.lock\"",
        "probe_lock \"$git_dir_real/ORIG_HEAD.lock\"",
        "branch=\"$(git -C \"$workspace\" symbolic-ref --quiet --short HEAD || true)\"",
        "if [ -n \"$branch\" ]; then",
        "  probe_lock \"$git_dir_real/refs/remotes/origin/${branch}.lock\"",
        "fi",
        "probe_file=\".aiur-git-index-write-probe.$$\"",
        "cleanup_probe() {",
        "  git -C \"$workspace\" reset -q -- \"$probe_file\" >/dev/null 2>&1 || true",
        "  rm -f \"$workspace/$probe_file\"",
        "}",
        "trap cleanup_probe EXIT",
        "printf 'aiur git index write probe\\n' > \"$workspace/$probe_file\"",
        "git -C \"$workspace\" add -f -N -- \"$probe_file\"",
        "git -C \"$workspace\" reset -q -- \"$probe_file\"",
        "rm -f \"$workspace/$probe_file\"",
        "trap - EXIT"
      ]
      |> Enum.join("\n")

    case Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:workspace_git_metadata_unwritable, workspace, worker_host, status, output}}
      {:error, reason} -> {:error, {:workspace_git_metadata_unwritable, workspace, worker_host, reason}}
    end
  end

  defp local_git_metadata_probe_paths(workspace) do
    with {:ok, git_dir} <- local_git_metadata_dir(workspace),
         :ok <- ensure_git_dir_inside_workspace(git_dir, workspace) do
      {:ok, git_metadata_probe_paths(workspace, git_dir)}
    end
  end

  defp append_exclusions(git_dir, exclusions) do
    with {:ok, info_dir} <- ensure_git_info_directory(git_dir),
         path = Path.join(info_dir, "exclude"),
         {:ok, contents} <- read_optional_regular_file(path) do
      missing = Enum.reject(exclusions, &exclusion_present?(contents, &1))
      write_exclusions(info_dir, path, contents, missing)
    end
  end

  defp ensure_git_info_directory(git_dir) do
    path = Path.join(git_dir, "info")

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, path}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:symlinked_git_info, path}}

      {:ok, _stat} ->
        {:error, {:invalid_git_info, path}}

      {:error, :enoent} ->
        with :ok <- File.mkdir(path),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
             do: {:ok, path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_exclusions(_info_dir, _path, _contents, []), do: :ok

  defp write_exclusions(info_dir, path, contents, exclusions) do
    tmp = Path.join(info_dir, ".exclude-#{System.unique_integer([:positive])}.tmp")

    try do
      with {:ok, io} <- :file.open(String.to_charlist(tmp), [:write, :binary, :raw, :exclusive]),
           :ok <- write_and_close(io, contents <> exclusion_suffix(contents, exclusions)),
           {:ok, %File.Stat{type: :directory}} <- File.lstat(info_dir),
           {:ok, final_state} <- regular_or_missing(path),
           true <- final_state in [:regular, :missing],
           :ok <- File.rename(tmp, path) do
        :ok
      else
        false -> {:error, {:invalid_git_exclude, path}}
        {:error, reason} -> {:error, reason}
      end
    after
      _ = File.rm(tmp)
    end
  end

  defp write_and_close(io, contents) do
    with :ok <- :file.write(io, contents), do: :file.sync(io)
  after
    :ok = :file.close(io)
  end

  defp read_optional_regular_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> File.read(path)
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlinked_git_exclude, path}}
      {:ok, _stat} -> {:error, {:invalid_git_exclude, path}}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, {:git_exclude_unreadable, path, reason}}
    end
  end

  defp regular_or_missing(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, :regular}
      {:error, :enoent} -> {:ok, :missing}
      {:ok, _stat} -> {:ok, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exclusion_present?(contents, exclusion) do
    contents
    |> String.split("\n")
    |> Enum.any?(&(String.trim(&1) == exclusion))
  end

  defp exclusion_suffix("", exclusions), do: Enum.join(exclusions, "\n") <> "\n"

  defp exclusion_suffix(contents, exclusions) do
    separator = if String.ends_with?(contents, "\n"), do: "", else: "\n"
    separator <> Enum.join(exclusions, "\n") <> "\n"
  end

  defp probe_lock_files(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case probe_lock_file(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp local_git_metadata_dir(workspace) do
    case git(workspace, ["rev-parse", "--is-inside-work-tree"]) do
      {_output, 0} ->
        case git(workspace, ["rev-parse", "--git-dir"]) do
          {git_dir, 0} ->
            {:ok, expand_git_dir(workspace, String.trim(git_dir))}

          {output, status} ->
            {:error, {:git_dir_unavailable, status, String.trim(output)}}
        end

      _ ->
        :not_git
    end
  end

  defp expand_git_dir(workspace, git_dir) do
    if Path.type(git_dir) == :absolute, do: Path.expand(git_dir), else: Path.expand(git_dir, workspace)
  end

  defp ensure_git_dir_inside_workspace(git_dir, workspace) do
    with {:ok, canonical_git_dir} <- PathSafety.canonicalize(git_dir),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace) do
      workspace_prefix = canonical_workspace <> "/"

      if String.starts_with?(canonical_git_dir <> "/", workspace_prefix),
        do: :ok,
        else: {:error, {:git_dir_outside_workspace, canonical_git_dir}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_metadata_probe_paths(workspace, git_dir) do
    [
      Path.join(git_dir, "index.lock"),
      Path.join(git_dir, "FETCH_HEAD.lock"),
      Path.join(git_dir, "ORIG_HEAD.lock")
    ] ++ current_branch_ref_lock_paths(workspace, git_dir)
  end

  # Probe the actual checked-out remote ref rather than reconstructing one from
  # the workspace leaf. This covers readable and legacy ticket branches as well
  # as PR-anchored heads without coupling recovery to a branch-name convention.
  defp current_branch_ref_lock_paths(workspace, git_dir) do
    case Checkout.current_branch(workspace) do
      branch when is_binary(branch) and branch != "" ->
        [Path.join([git_dir, "refs", "remotes", "origin"] ++ ref_lock_segments(String.split(branch, "/", trim: true)))]

      _ ->
        []
    end
  end

  defp ref_lock_segments(ref_segments) do
    {leading, [last]} = Enum.split(ref_segments, length(ref_segments) - 1)
    leading ++ ["#{last}.lock"]
  end

  defp probe_lock_file(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- remove_stale_lock(path),
         {:ok, io} <- File.open(path, [:write, :exclusive]) do
      File.close(io)
      File.rm(path)
    else
      {:error, reason} ->
        {:error, {:workspace_git_metadata_unwritable, path, reason}}
    end
  end

  defp probe_git_index_write(workspace) do
    probe_name = ".aiur-git-index-write-probe-#{System.unique_integer([:positive])}"
    probe_path = Path.join(workspace, probe_name)

    case File.write(probe_path, "aiur git index write probe\n") do
      :ok ->
        try do
          with {_output, 0} <- git(workspace, ["add", "-f", "-N", "--", probe_name]),
               {_output, 0} <- git(workspace, ["reset", "-q", "--", probe_name]) do
            :ok
          else
            {output, status} ->
              {:error, {:workspace_git_metadata_unwritable, probe_path, {:git_index_probe_failed, status, String.trim(output)}}}
          end
        after
          git(workspace, ["reset", "-q", "--", probe_name])
          File.rm(probe_path)
        end

      {:error, reason} ->
        {:error, {:workspace_git_metadata_unwritable, probe_path, reason}}
    end
  end

  defp remove_stale_lock(path) do
    case File.rm(path) do
      result when result in [:ok, {:error, :enoent}] -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp git(workspace, args), do: System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
end
