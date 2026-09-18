defmodule Aiur.Workspace.WipPreservation.Capture do
  @moduledoc """
  Writes the files of one uncommitted-work save into a partial directory
  (#2743). `Aiur.Workspace.WipPreservation` owns the directory, the notice and
  the alerts; this module owns the `git` and `tar` work and its bounds.

  Every command runs through `Aiur.Workspace.WipPreservation.Command` with
  `workspace.wip_command_timeout_ms`. Untracked content is bounded:

    * an untracked file larger than `workspace.wip_max_file_bytes` is skipped;
    * an untracked directory that is a nested Git repository, or that holds
      more than `workspace.wip_max_dir_files` files, is skipped whole;
    * once the patch and the archived files reach `workspace.wip_max_bytes`,
      the remaining untracked files are skipped.

  Each skipped path is recorded with its size in the manifest under
  `skipped_untracked`. A skip never fails the save. The tracked patch is never
  cut: it is the agent's primary work, and its command timeout bounds it.
  """

  require Logger

  alias Aiur.Shell
  alias Aiur.Workspace.WipPreservation.Command

  @patch "tracked.patch"
  @untracked "untracked.tar"
  @untracked_list "untracked.list"
  @bundle "unpushed-commits.bundle"
  @manifest "manifest.json"
  # The well-known empty tree: the diff base of a checkout with no commit yet.
  @empty_tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  @git_env [{"GIT_OPTIONAL_LOCKS", "0"}, {"GIT_TERMINAL_PROMPT", "0"}, {"LC_ALL", "C"}]

  @type context :: %{workspace: Path.t(), partial: Path.t(), final: Path.t(), limits: map()}

  @doc "The manifest file name of a save."
  @spec manifest_name() :: String.t()
  def manifest_name, do: @manifest

  @doc """
  Captures the dirty state of `context.workspace` into `context.partial`.
  Returns the manifest fields that describe the captured state.
  """
  @spec capture(context()) :: {:ok, map()} | {:error, term()}
  def capture(%{workspace: workspace, final: final} = context) do
    with {:ok, head} <- head(context),
         {:ok, branch} <- branch(context),
         base = head || @empty_tree,
         {:ok, tracked} <- git_list(context, ["diff", "--name-only", "-z", "--no-renames", base]),
         {:ok, patch_bytes} <- write_patch(context, base, tracked),
         {:ok, archived, skipped} <- select_untracked(context, patch_bytes),
         {:ok, tar?} <- write_untracked(context, archived),
         {:ok, bundle?} <- write_bundle(context, head) do
      files = %{
        "tracked_patch" => if(patch_bytes > 0, do: Path.join(final, @patch)),
        "untracked_tar" => if(tar?, do: Path.join(final, @untracked)),
        "unpushed_bundle" => if(bundle?, do: Path.join(final, @bundle))
      }

      log_skipped(workspace, skipped)

      {:ok,
       %{
         "head" => head,
         "branch" => branch,
         "tracked_files" => tracked,
         "untracked_files" => archived,
         "skipped_untracked" => skipped,
         "files" => files,
         "restore_commands" => restore_commands(workspace, Path.basename(final), files)
       }}
    end
  end

  @doc "True when `workspace` has uncommitted changes. Not a checkout reads as clean."
  @spec dirty?(Path.t(), map()) :: {:ok, boolean()} | {:error, term()}
  def dirty?(workspace, limits) do
    if checkout?(workspace) do
      context = %{workspace: workspace, limits: limits}

      with {:ok, status} <- git(context, ["status", "--porcelain=v1", "-z", "--untracked-files=normal"]),
           do: {:ok, status != ""}
    else
      {:ok, false}
    end
  end

  @doc "True when `workspace` is a directory with a `.git` entry."
  @spec checkout?(Path.t()) :: boolean()
  def checkout?(workspace), do: File.dir?(workspace) and File.exists?(Path.join(workspace, ".git"))

  # -- tracked ----------------------------------------------------------------

  defp head(context) do
    case git_raw(context, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]) do
      {:ok, {out, 0}} -> {:ok, String.trim(out)}
      {:ok, {_out, 1}} -> {:ok, nil}
      {:ok, {out, status}} -> {:error, {:git_failed, ["rev-parse", "HEAD"], status, out}}
      {:error, _reason} = error -> error
    end
  end

  defp branch(context) do
    case git_raw(context, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {:ok, {out, 0}} -> {:ok, String.trim(out)}
      {:ok, {_out, _status}} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp write_patch(_context, _base, []), do: {:ok, 0}

  defp write_patch(context, base, _tracked) do
    path = Path.join(context.partial, @patch)

    args = [
      "diff",
      "--binary",
      "--no-color",
      "--no-ext-diff",
      "--no-textconv",
      "--no-renames",
      "--src-prefix=a/",
      "--dst-prefix=b/",
      "--output=#{path}",
      base
    ]

    # The reverse check proves the saved patch is exactly the difference
    # between the base and the current worktree before anything is deleted.
    with {:ok, _} <- git(context, args, true),
         {:ok, size} <- nonempty(path),
         :ok <- private(path),
         {:ok, _} <- git(context, ["apply", "--check", "--reverse", "--binary", path], true) do
      {:ok, size}
    end
  end

  # -- untracked --------------------------------------------------------------

  # `--directory` names a wholly untracked directory once, with a trailing
  # slash, so a huge untracked tree or a nested repository is judged as one
  # unit. The full listing gives the files inside the directories that stay.
  defp select_untracked(context, patch_bytes) do
    with {:ok, collapsed} <- git_list(context, ["ls-files", "--others", "--exclude-standard", "--directory", "-z"]),
         {:ok, full} <- full_untracked(context, collapsed) do
      dirs = collapsed |> Enum.filter(&String.ends_with?(&1, "/")) |> MapSet.new()
      groups = Enum.group_by(full, &owning_dir(&1, dirs))
      {candidates, skipped_dirs} = judge_dirs(context, groups)
      budget = max(context.limits.max_bytes - patch_bytes, 0)
      {archived, skipped_files} = judge_files(context, Enum.sort(candidates), budget)
      {:ok, archived, skipped_dirs ++ skipped_files}
    end
  end

  defp full_untracked(_context, []), do: {:ok, []}
  defp full_untracked(context, _collapsed), do: git_list(context, ["ls-files", "--others", "--exclude-standard", "-z"])

  defp owning_dir(path, dirs) do
    parts = path |> String.trim_trailing("/") |> String.split("/")
    parts = if String.ends_with?(path, "/"), do: parts, else: Enum.drop(parts, -1)

    parts
    |> Enum.scan(&(&2 <> "/" <> &1))
    |> Enum.map(&(&1 <> "/"))
    |> Enum.find(&MapSet.member?(dirs, &1))
  end

  defp judge_dirs(context, groups) do
    Enum.reduce(groups, {[], []}, fn
      {nil, entries}, {candidates, skipped} ->
        {entries ++ candidates, skipped}

      {dir, entries}, {candidates, skipped} ->
        cond do
          nested_repository?(context.workspace, dir, entries) ->
            {candidates, [dir_skip(context, dir, "nested_repository") | skipped]}

          length(entries) > context.limits.max_dir_files ->
            {candidates, [dir_skip(context, dir, "too_many_files") | skipped]}

          true ->
            {entries ++ candidates, skipped}
        end
    end)
  end

  defp nested_repository?(workspace, dir, entries),
    do: entries == [dir] or File.exists?(Path.join([workspace, dir, ".git"]))

  defp judge_files(context, entries, budget) do
    {archived, skipped, _used} =
      Enum.reduce(entries, {[], [], 0}, fn entry, {archived, skipped, used} ->
        case file_verdict(context, entry, used, budget) do
          {:keep, size} -> {[entry | archived], skipped, used + size}
          {:skip, record} -> {archived, [record | skipped], used}
        end
      end)

    {Enum.reverse(archived), Enum.reverse(skipped)}
  end

  defp file_verdict(context, entry, used, budget) do
    if String.ends_with?(entry, "/") do
      {:skip, dir_skip(context, entry, "nested_repository")}
    else
      case File.lstat(Path.join(context.workspace, entry)) do
        {:ok, %File.Stat{size: size}} when size > context.limits.max_file_bytes ->
          {:skip, %{"path" => entry, "reason" => "file_too_large", "size_bytes" => size}}

        {:ok, %File.Stat{size: size}} when used + size > budget ->
          {:skip, %{"path" => entry, "reason" => "save_size_cap", "size_bytes" => size}}

        {:ok, %File.Stat{size: size}} ->
          {:keep, size}

        {:error, reason} ->
          {:skip, %{"path" => entry, "reason" => "unreadable: #{reason}", "size_bytes" => nil}}
      end
    end
  end

  # The size of a skipped directory. The walk stops after `max_dir_files`
  # entries, so the recorded size is then a lower bound.
  defp dir_skip(context, dir, reason) do
    {bytes, count, complete?} = walk(Path.join(context.workspace, dir), context.limits.max_dir_files)

    %{
      "path" => dir,
      "reason" => reason,
      "size_bytes" => bytes,
      "file_count" => count,
      "size_is_lower_bound" => not complete?
    }
  end

  defp walk(root, limit), do: walk([root], limit, 0, 0)

  defp walk([], _limit, bytes, count), do: {bytes, count, true}
  defp walk(_stack, limit, bytes, count) when count >= limit, do: {bytes, count, false}

  defp walk([path | rest], limit, bytes, count) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        children =
          path
          |> File.ls()
          |> then(fn
            {:ok, names} -> names
            _ -> []
          end)
          |> Enum.map(&Path.join(path, &1))

        walk(children ++ rest, limit, bytes, count)

      {:ok, %File.Stat{size: size}} ->
        walk(rest, limit, bytes + size, count + 1)

      {:error, _reason} ->
        walk(rest, limit, bytes, count)
    end
  end

  # Names go to tar through a NUL-separated list, so tar reads them verbatim:
  # a backslash, a newline or a non-ASCII byte is not escaped. The `./` prefix
  # keeps a name that starts with `-` from being read as an option. tar's exit
  # status is the check; its `-t` listing escapes such names, so the listing
  # is not compared with the Git names.
  defp write_untracked(_context, []), do: {:ok, false}

  defp write_untracked(context, archived) do
    list = Path.join(context.partial, @untracked_list)
    tar = Path.join(context.partial, @untracked)
    args = ["-c", "-f", tar, "-C", context.workspace, "--no-recursion", "--null", "-T", list]

    with :ok <- File.write(list, Enum.map_join(archived, "", &("./" <> &1 <> <<0>>))),
         :ok <- private(list),
         {:ok, {_out, 0}} <- run("tar", args, context, true),
         :ok <- private(tar) do
      {:ok, true}
    else
      {:ok, {out, status}} -> {:error, {:untracked_tar_failed, status, String.slice(out, 0, 2_000)}}
      {:error, reason} when is_atom(reason) -> {:error, {:artifact_write_failed, list, reason}}
      {:error, _reason} = error -> error
    end
  end

  # -- unpushed commits -------------------------------------------------------

  defp write_bundle(_context, nil), do: {:ok, false}

  defp write_bundle(context, _head) do
    with {:ok, count} <- git(context, ["rev-list", "--count", "HEAD", "--not", "--remotes"]) do
      if String.trim(count) == "0", do: {:ok, false}, else: create_bundle(context)
    end
  end

  defp create_bundle(context) do
    path = Path.join(context.partial, @bundle)

    with {:ok, _} <- git(context, ["bundle", "create", "--quiet", path, "HEAD", "--not", "--remotes"], true),
         {:ok, _} <- git(context, ["bundle", "verify", "--quiet", path], true),
         :ok <- private(path),
         do: {:ok, true}
  end

  # -- restore ----------------------------------------------------------------

  # The commands work on the current HEAD of the checkout, which can differ
  # from the HEAD at save time: after a squash merge the old branch may be
  # gone. Only a bundle brings old commits back; they land on a local
  # `aiur-wip/<save>` branch and fast-forward the current branch when they can.
  # The patch then applies to the current HEAD, with a three-way fallback.
  defp restore_commands(workspace, save_name, files) do
    [
      "cd #{Shell.escape(workspace)}",
      files["unpushed_bundle"] && bundle_command(files["unpushed_bundle"], "aiur-wip/" <> save_name),
      files["tracked_patch"] && patch_command(files["tracked_patch"]),
      files["untracked_tar"] && "tar -x -f #{Shell.escape(files["untracked_tar"])}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp bundle_command(bundle, branch) do
    "git fetch --quiet #{Shell.escape(bundle)} HEAD && git branch -f #{Shell.escape(branch)} FETCH_HEAD && " <>
      "{ git merge --ff-only --quiet FETCH_HEAD || echo #{Shell.escape("unpushed commits kept on branch " <> branch)}; }"
  end

  defp patch_command(patch) do
    escaped = Shell.escape(patch)
    "{ git apply --binary #{escaped} || git apply --binary --3way #{escaped}; }"
  end

  # -- helpers ----------------------------------------------------------------

  defp log_skipped(_workspace, []), do: :ok

  defp log_skipped(workspace, skipped) do
    listed = Enum.map_join(skipped, ", ", &"#{&1["path"]} (#{&1["reason"]}, #{&1["size_bytes"]} bytes)")
    Logger.warning("Uncommitted-work save skipped untracked paths workspace=#{workspace} skipped=#{listed}")
  end

  defp nonempty(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > 0 -> {:ok, size}
      {:ok, _stat} -> {:error, {:empty_patch, path}}
      {:error, reason} -> {:error, {:patch_unreadable, path, reason}}
    end
  end

  defp private(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, reason} -> {:error, {:artifact_chmod_failed, path, reason}}
    end
  end

  defp git_list(context, args) do
    with {:ok, out} <- git(context, args), do: {:ok, String.split(out, <<0>>, trim: true)}
  end

  # Commands whose stdout is parsed keep stderr apart; the others fold it in
  # so a failure reason carries git's own message.
  defp git(context, args, stderr_to_stdout? \\ false) do
    case git_raw(context, args, stderr_to_stdout?) do
      {:ok, {out, 0}} -> {:ok, out}
      {:ok, {out, status}} -> {:error, {:git_failed, args, status, String.slice(out, 0, 2_000)}}
      {:error, _reason} = error -> error
    end
  end

  defp git_raw(context, args, stderr_to_stdout? \\ false),
    do: run(git_executable(), ["-C", context.workspace | args], context, stderr_to_stdout?)

  defp run(command, args, context, stderr_to_stdout?) do
    Command.run(command, args, timeout_ms: context.limits.command_timeout_ms, env: @git_env, stderr_to_stdout: stderr_to_stdout?)
  end

  # A test seam: the suite points this at a wrapper that stalls one command.
  defp git_executable, do: Application.get_env(:aiur, :wip_preservation_git, "git")
end
