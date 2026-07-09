defmodule Aiur.Workspace.GitMetadata do
  @moduledoc ".git writability probes and stale-lock repair, local and remote, including the git-dir-inside-workspace containment guard."
  alias Aiur.{Config, PathSafety}
  alias Aiur.Workspace.{Checkout, Layout, Remote}
  @type worker_host :: String.t() | nil
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
        "issue_id=\"$(basename \"$workspace\")\"",
        "probe_lock \"$git_dir_real/index.lock\"",
        "probe_lock \"$git_dir_real/FETCH_HEAD.lock\"",
        "probe_lock \"$git_dir_real/ORIG_HEAD.lock\"",
        "probe_lock \"$git_dir_real/refs/remotes/origin/aiur/${issue_id}.lock\"",
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
    issue_id = Path.basename(workspace)

    [
      Path.join(git_dir, "index.lock"),
      Path.join(git_dir, "FETCH_HEAD.lock"),
      Path.join(git_dir, "ORIG_HEAD.lock"),
      Path.join([git_dir, "refs", "remotes", "origin", "aiur", "#{issue_id}.lock"])
    ] ++ pr_anchored_ref_lock_paths(workspace, git_dir)
  end

  # A PR-anchored workspace (leaf `pr-<pr#>`) tracks the human PR's existing head
  # branch, not `aiur/<id>`, so its remote-ref lock lives at
  # `refs/remotes/origin/<head_ref>.lock`. Derive the head ref from the checked-out
  # branch (the PR-anchored checkout set it) and pre-clear that lock too. Legacy
  # `aiur/<id>` workspaces return `[]` here — their existing probe is unchanged.
  defp pr_anchored_ref_lock_paths(workspace, git_dir) do
    with true <- Layout.pr_anchored_workspace?(workspace),
         branch when is_binary(branch) <- Checkout.current_branch(workspace) do
      case String.split(branch, "/", trim: true) do
        [] -> []
        ref_segments -> [Path.join([git_dir, "refs", "remotes", "origin"] ++ ref_lock_segments(ref_segments))]
      end
    else
      _ -> []
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
