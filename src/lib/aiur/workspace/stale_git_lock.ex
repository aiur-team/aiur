defmodule Aiur.Workspace.StaleGitLock do
  @moduledoc "Conservative recovery for abandoned local Git metadata locks."

  require Logger

  alias Aiur.PathSafety

  @stale_after_seconds 120

  @doc false
  @spec recover(Path.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def recover(workspace, worker_host, opts \\ [])

  def recover(_workspace, worker_host, _opts) when is_binary(worker_host), do: :ok

  def recover(workspace, nil, opts) when is_binary(workspace) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace) do
      git_dirs = local_git_dirs(workspace, canonical_workspace)
      paths = lock_paths(workspace, git_dirs)
      recover_paths(paths, Keyword.merge(opts, workspace: canonical_workspace, git_dirs: git_dirs))
    end
  end

  @doc false
  @spec recover_paths([Path.t()], keyword()) :: :ok | {:error, term()}
  def recover_paths(paths, opts \\ []) when is_list(paths) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    workspace = canonical_root(Keyword.get(opts, :workspace))
    git_dirs = Keyword.get(opts, :git_dirs, Enum.map(paths, &git_dir_for_lock/1)) |> Enum.map(&canonical_root/1)
    paths = Enum.map(paths, &Path.expand/1)
    proc_root = Keyword.get(opts, :proc_root, "/proc")
    holder_probe = Keyword.get(opts, :holder_probe, &open_workspace_holders(&1, workspace, git_dirs, proc_root))
    sleeper = Keyword.get(opts, :sleep, &Process.sleep/1)

    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case recover_lock(path, now, holder_probe, sleeper) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp local_git_dirs(workspace, canonical_workspace) do
    [resolve_git_dir(Path.join(workspace, ".git")), {:ok, Path.join(workspace, ".git-writable")}]
    |> Enum.flat_map(fn
      {:ok, path} -> [path]
      _ -> []
    end)
    |> Enum.flat_map(fn path ->
      with {:ok, %File.Stat{type: :directory}} <- File.stat(path),
           {:ok, canonical_path} <- PathSafety.canonicalize(path),
           true <- contained_path?(canonical_workspace, canonical_path) do
        [canonical_path]
      else
        _ -> []
      end
    end)
  end

  defp resolve_git_dir(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, path}

      {:ok, %File.Stat{type: :regular}} ->
        read_gitfile(path)

      _ ->
        :not_git
    end
  end

  defp read_gitfile(path) do
    with {:ok, contents} <- File.read(path),
         [_, git_dir] <- Regex.run(~r/^gitdir:\s*(.+)\s*$/m, contents) do
      resolved = if Path.type(git_dir) == :absolute, do: git_dir, else: Path.expand(git_dir, Path.dirname(path))
      {:ok, resolved}
    else
      _ -> :not_git
    end
  end

  defp lock_paths(_workspace, git_dirs) do
    Enum.flat_map(git_dirs, fn git_dir ->
      fixed = ["index.lock", "FETCH_HEAD.lock", "ORIG_HEAD.lock"]
      remote_refs = Path.wildcard(Path.join(git_dir, "refs/remotes/origin/**/*.lock"))
      Enum.map(fixed, &Path.join(git_dir, &1)) ++ remote_refs
    end)
  end

  defp recover_lock(path, now, holder_probe, sleeper) do
    case File.lstat(path, time: :posix) do
      {:error, reason} when reason in [:enoent, :enotdir] ->
        :ok

      {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} ->
        age = max(DateTime.to_unix(now) - mtime, 0)
        wait_or_remove(path, age, size, holder_probe, sleeper)

      {:ok, _stat} ->
        {:error, {:git_metadata_lock_invalid_type, path}}

      {:error, reason} ->
        {:error, {:git_metadata_lock_stat_failed, path, reason}}
    end
  end

  defp wait_or_remove(path, age, size, holder_probe, sleeper) when age < @stale_after_seconds do
    case holder_probe.(path) do
      {:ok, [pid | _]} ->
        {:error, {:git_metadata_lock_held, path, age, size, pid}}

      {:error, reason} ->
        {:error, {:git_metadata_lock_holder_check_failed, path, age, size, reason}}

      {:ok, []} ->
        sleeper.((@stale_after_seconds - age) * 1_000)
        recover_lock(path, DateTime.utc_now(), holder_probe, sleeper)
    end
  end

  defp wait_or_remove(path, age, size, holder_probe, _sleeper) do
    case holder_probe.(path) do
      {:ok, []} ->
        case File.rm(path) do
          :ok ->
            Logger.warning("Removed stale Git metadata lock path=#{path} age_seconds=#{age} size_bytes=#{size}")
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            {:error, {:git_metadata_lock_remove_failed, path, age, size, reason}}
        end

      {:ok, [pid | _]} ->
        {:error, {:git_metadata_lock_held, path, age, size, pid}}

      {:error, reason} ->
        {:error, {:git_metadata_lock_holder_check_failed, path, age, size, reason}}
    end
  end

  defp open_workspace_holders(path, workspace, git_dirs, proc_root) do
    with {:ok, %File.Stat{uid: expected_uid}} <- File.stat(path),
         {:ok, entries} <- File.ls(proc_root) do
      scan_processes(entries, path, expected_uid, workspace, git_dirs, proc_root)
    else
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scan_processes(entries, path, expected_uid, workspace, git_dirs, proc_root) do
    entries
    |> Enum.filter(fn pid ->
      Regex.match?(~r/^\d+$/, pid) and same_user_process?(pid, expected_uid, proc_root)
    end)
    |> Enum.reduce_while({:ok, []}, &collect_holder(&1, &2, path, workspace, git_dirs, proc_root))
    |> case do
      {:ok, holders} -> {:ok, holders |> Enum.uniq() |> Enum.sort()}
      {:error, _reason} = error -> error
    end
  end

  defp collect_holder(pid, {:ok, holders}, path, workspace, git_dirs, proc_root) do
    case process_holds_workspace_lock(pid, path, workspace, git_dirs, proc_root) do
      {:ok, nil} -> {:cont, {:ok, holders}}
      {:ok, holder} -> {:cont, {:ok, [holder | holders]}}
    end
  end

  defp process_holds_workspace_lock(pid, path, workspace, git_dirs, proc_root) do
    if process_cwd_in_workspace?(pid, workspace, proc_root) do
      {:ok, String.to_integer(pid)}
    else
      scan_process_descriptors(pid, path, workspace, git_dirs, proc_root)
    end
  end

  defp scan_process_descriptors(pid, path, workspace, git_dirs, proc_root) do
    fd_dir = Path.join([proc_root, pid, "fd"])

    case File.ls(fd_dir) do
      {:ok, descriptors} ->
        if Enum.any?(descriptors, &link_in_workspace?(Path.join(fd_dir, &1), path, workspace, git_dirs)),
          do: {:ok, String.to_integer(pid)},
          else: {:ok, nil}

      # Processes can exit between the /proc scan and fd listing. Permission
      # denied on an unrelated descriptor table is also normal for systemd
      # session helpers such as (sd-pam); neither can hold this lock open.
      {:error, _reason} ->
        {:ok, nil}
    end
  end

  defp link_in_workspace?(link, path, workspace, git_dirs) do
    case File.read_link(link) do
      {:ok, target} ->
        target = strip_deleted_suffix(target)
        target == path or path_in_roots?(target, [workspace | git_dirs])

      _ ->
        false
    end
  end

  defp process_cwd_in_workspace?(pid, workspace, proc_root) do
    case File.read_link(Path.join([proc_root, pid, "cwd"])) do
      {:ok, cwd} -> path_in_roots?(strip_deleted_suffix(cwd), [workspace])
      _ -> false
    end
  end

  defp path_in_roots?(path, roots) do
    Enum.any?(roots, fn
      root when is_binary(root) -> contained_path?(root, path)
      _ -> false
    end)
  end

  defp canonical_root(path) when is_binary(path) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical_path} -> canonical_path
      _ -> Path.expand(path)
    end
  end

  defp canonical_root(_path), do: nil

  defp contained_path?(root, path), do: path == root or String.starts_with?(path, root <> "/")

  defp strip_deleted_suffix(path), do: String.replace_suffix(path, " (deleted)", "")

  defp git_dir_for_lock(path), do: find_git_dir(Path.dirname(path))

  defp find_git_dir(path) do
    if Path.basename(path) in [".git", ".git-writable"] do
      path
    else
      parent = Path.dirname(path)
      if parent == path, do: path, else: find_git_dir(parent)
    end
  end

  defp same_user_process?(pid, expected_uid, proc_root) do
    case File.stat(Path.join([proc_root, pid])) do
      {:ok, %File.Stat{uid: ^expected_uid}} -> true
      _ -> false
    end
  end
end
