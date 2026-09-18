defmodule Aiur.Workspace.WipPreservation do
  @moduledoc """
  Saves the uncommitted state of a workspace before Aiur deletes or recreates
  it (#2743).

  The stale-leftover recreate (#577) and the workspace cleanups run `rm -rf` on
  a checkout. When that checkout still holds an agent's uncommitted work, the
  work is lost. Before any such delete, `guard_destroy/4` writes the dirty state
  to the daemon runtime state directory, outside the workspace:

      <runtime_state_dir>/wip-preserved/<workspace leaf>/<UTC stamp>/
        tracked.patch            git diff --binary against HEAD (staged and unstaged)
        untracked.tar            untracked files that are not ignored
        unpushed-commits.bundle  commits of HEAD that no remote-tracking ref holds
        manifest.json            HEAD, branch, file lists and restore commands

  Files, not a private ref: a ref lives in the object store of the checkout
  that is about to be deleted, so it cannot survive the delete. A patch and a
  tarball survive the delete and daemon restarts, and `git apply` and `tar`
  restore them in any fresh clone.

  The next agent turn for the workspace gets the restore commands through
  `with_pending_notices/2`. If the state cannot be saved, the delete does not
  run: the caller gets `{:error, {:wip_preservation_failed, workspace, reason}}`
  and an operator alert fires.
  """

  require Logger

  alias Aiur.{Alerts, Shell}
  alias Aiur.Config.Paths

  @keep_per_workspace 5
  @root_name "wip-preserved"
  @manifest "manifest.json"
  @patch "tracked.patch"
  @untracked "untracked.tar"
  @untracked_list "untracked.list"
  @bundle "unpushed-commits.bundle"
  @partial_prefix ".partial-"
  # The well-known empty tree: the diff base of a checkout with no commit yet.
  @empty_tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  @git_env [{"GIT_OPTIONAL_LOCKS", "0"}, {"GIT_TERMINAL_PROMPT", "0"}, {"LC_ALL", "C"}]

  @type artifact :: %{required(String.t()) => term()}

  @doc "How many artifacts are kept per workspace. Older ones are pruned only when a newer one exists."
  @spec keep_per_workspace() :: pos_integer()
  def keep_per_workspace, do: @keep_per_workspace

  @doc """
  Runs `destroy_fun` only after the dirty state of `workspace` is saved.

  A clean workspace, a missing one and a directory that is not a Git checkout
  go straight to `destroy_fun`. A dirty one is saved first; the
  `ticket.<ticket>.workspace.wip_preserved` alert fires after `destroy_fun`
  returns. When the save fails, `destroy_fun` does not run.
  """
  @spec guard_destroy(Path.t(), String.t(), String.t(), (-> result)) ::
          result | {:error, {:wip_preservation_failed, Path.t(), term()}}
        when result: term()
  def guard_destroy(workspace, ticket, action, destroy_fun)
      when is_binary(workspace) and is_binary(ticket) and is_binary(action) and is_function(destroy_fun, 0) do
    case preserve(workspace, action) do
      {:ok, :clean} ->
        destroy_fun.()

      {:ok, artifact} ->
        Logger.warning("Preserved uncommitted workspace state before an attempt to #{action} ticket=#{ticket} workspace=#{workspace} artifact=#{artifact["artifact_dir"]}")

        result = destroy_fun.()
        emit_preserved_alert(ticket, action, artifact)
        result

      {:error, reason} ->
        refuse(workspace, ticket, action, reason)
    end
  end

  @doc """
  Refuses a destructive `action` on `workspace` for `reason`: logs, fires the
  `ticket.<ticket>.workspace.wip_preservation_failed` alert and returns the
  named hold reason.
  """
  @spec refuse(Path.t(), String.t(), String.t(), term()) :: {:error, {:wip_preservation_failed, Path.t(), term()}}
  def refuse(workspace, ticket, action, reason) do
    Logger.error("Refusing #{action}: uncommitted workspace state could not be preserved ticket=#{ticket} workspace=#{workspace} reason=#{inspect(reason)}")

    message =
      "Did not #{action} the workspace of #{ticket}: its uncommitted work could not be saved (#{inspect(reason)}). " <>
        "The workspace at #{workspace} is unchanged and the ticket is held."

    Alerts.emit_system("ticket.#{ticket}.workspace.wip_preservation_failed",
      issue: ticket,
      message: message,
      reason: message,
      needs_attention: true,
      severity: "warning"
    )

    {:error, {:wip_preservation_failed, workspace, reason}}
  end

  @doc """
  Saves the dirty state of `workspace`. Returns `{:ok, :clean}` when there is
  nothing to save, `{:ok, manifest}` when an artifact was written and
  `{:error, reason}` when the state could not be saved completely.
  """
  @spec preserve(Path.t(), String.t()) :: {:ok, :clean} | {:ok, artifact()} | {:error, term()}
  def preserve(workspace, action \\ "delete the workspace") when is_binary(workspace) and is_binary(action) do
    if git_checkout?(workspace) do
      case git(workspace, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) do
        {:ok, ""} -> {:ok, :clean}
        {:ok, _status} -> write_artifact(workspace, action)
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, :clean}
    end
  end

  @doc "The artifact directory root for one workspace leaf."
  @spec workspace_dir(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def workspace_dir(leaf) when is_binary(leaf) do
    case Paths.runtime_state_dir() do
      {:ok, root} -> {:ok, Path.join([root, @root_name, Paths.sanitize(leaf, "issue")])}
      {:error, reason} -> {:error, {:runtime_state_dir_unavailable, reason}}
    end
  end

  @doc """
  Returns the manifests of `workspace` whose notice no agent turn has carried
  yet, oldest first.
  """
  @spec pending_notices(Path.t()) :: [artifact()]
  def pending_notices(workspace) when is_binary(workspace) do
    with {:ok, dir} <- workspace_dir(Path.basename(workspace)),
         {:ok, entries} <- File.ls(dir) do
      entries
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.sort()
      |> Enum.flat_map(&read_manifest(Path.join([dir, &1, @manifest])))
      |> Enum.filter(&is_nil(&1["notice_delivered_at"]))
    else
      _ -> []
    end
  end

  @doc """
  Puts the restore notice of every pending artifact in front of `prompt`.
  Returns the prompt and the notices it carries; pass them to
  `mark_delivered/1` once the turn has run.
  """
  @spec with_pending_notices(Path.t(), String.t()) :: {String.t(), [artifact()]}
  def with_pending_notices(workspace, prompt) when is_binary(workspace) and is_binary(prompt) do
    case pending_notices(workspace) do
      [] -> {prompt, []}
      notices -> {notice_text(notices) <> "\n" <> prompt, notices}
    end
  end

  @doc "The agent-facing text for `notices`."
  @spec notice_text([artifact()]) :: String.t()
  def notice_text(notices) when is_list(notices) do
    body =
      Enum.map_join(notices, "\n", fn notice ->
        """
        - Saved at #{notice["created_at"]} before Aiur tried to #{notice["action"] || "delete the workspace"}: #{notice["artifact_dir"]}
          HEAD #{notice["head"] || "(no commit)"} on branch #{notice["branch"] || "(detached)"}; #{length(notice["tracked_files"] || [])} tracked and #{length(notice["untracked_files"] || [])} untracked files.
          Restore with these commands, in order:
        #{Enum.map_join(notice["restore_commands"] || [], "\n", &("      " <> &1))}
        """
      end)

    """
    Aiur preserved uncommitted work (#2743):

    Aiur had to delete or recreate this workspace while it still held uncommitted changes. It saved the changes first; they are not in the current workspace. Restore them before you continue, or say in the workpad why they are no longer needed.
    #{body}
    """
  end

  @doc "Records that an agent turn carried `notices`."
  @spec mark_delivered([artifact()]) :: :ok
  def mark_delivered(notices) when is_list(notices) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.each(notices, fn %{"manifest_path" => path} = notice ->
      manifest = notice |> Map.delete("manifest_path") |> Map.put("notice_delivered_at", now)

      case write_json(path, manifest) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Could not mark preserved-work notice delivered path=#{path} reason=#{inspect(reason)}")
      end
    end)
  end

  # -- capture ----------------------------------------------------------------

  defp git_checkout?(workspace), do: File.dir?(workspace) and File.exists?(Path.join(workspace, ".git"))

  defp write_artifact(workspace, action) do
    leaf = Path.basename(workspace)
    stamp = stamp()

    with {:ok, dir} <- workspace_dir(leaf),
         final = Path.join(dir, stamp),
         partial = Path.join(dir, @partial_prefix <> stamp),
         :ok <- mkdir(partial),
         {:ok, manifest} <- discard_on_error(capture(workspace, leaf, action, partial, final), partial),
         :ok <- discard_on_error(promote(partial, final), partial) do
      prune(dir)
      {:ok, Map.put(manifest, "manifest_path", Path.join(final, @manifest))}
    end
  end

  # The artifact appears under its final name only once every file is written,
  # so a reader never sees a half-written save.
  defp promote(partial, final) do
    case File.rename(partial, final) do
      :ok -> :ok
      {:error, reason} -> {:error, {:artifact_rename_failed, final, reason}}
    end
  end

  defp discard_on_error({:error, _reason} = error, partial) do
    File.rm_rf(partial)
    error
  end

  defp discard_on_error(result, _partial), do: result

  defp capture(workspace, leaf, action, partial, final) do
    with {:ok, head} <- head(workspace),
         {:ok, branch} <- branch(workspace),
         base = head || @empty_tree,
         {:ok, tracked} <- git_list(workspace, ["diff", "--name-only", "-z", "--no-renames", base]),
         {:ok, untracked} <- git_list(workspace, ["ls-files", "--others", "--exclude-standard", "-z"]),
         {:ok, patch?} <- write_patch(workspace, base, tracked, Path.join(partial, @patch)),
         {:ok, tar?} <- write_untracked(workspace, untracked, partial),
         {:ok, bundle?} <- write_bundle(workspace, head, Path.join(partial, @bundle)) do
      files = %{
        "tracked_patch" => if(patch?, do: Path.join(final, @patch)),
        "untracked_tar" => if(tar?, do: Path.join(final, @untracked)),
        "unpushed_bundle" => if(bundle?, do: Path.join(final, @bundle))
      }

      manifest = %{
        "version" => 1,
        "workspace" => workspace,
        "workspace_leaf" => leaf,
        "action" => action,
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "head" => head,
        "branch" => branch,
        "tracked_files" => tracked,
        "untracked_files" => untracked,
        "artifact_dir" => final,
        "files" => files,
        "restore_commands" => restore_commands(workspace, head, branch, files),
        "notice_delivered_at" => nil
      }

      with :ok <- write_json(Path.join(partial, @manifest), manifest), do: {:ok, manifest}
    end
  end

  defp head(workspace) do
    case git_raw(workspace, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]) do
      {out, 0} -> {:ok, String.trim(out)}
      {_out, 1} -> {:ok, nil}
      {out, status} -> {:error, {:git_failed, ["rev-parse", "HEAD"], status, out}}
    end
  end

  defp branch(workspace) do
    case git_raw(workspace, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {out, 0} -> {:ok, String.trim(out)}
      {_out, _status} -> {:ok, nil}
    end
  end

  defp write_patch(_workspace, _base, [], _path), do: {:ok, false}

  defp write_patch(workspace, base, _tracked, path) do
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
    with {:ok, _} <- git(workspace, args, true),
         {:ok, _} <- nonempty(path),
         {:ok, _} <- git(workspace, ["apply", "--check", "--reverse", "--binary", path], true) do
      {:ok, true}
    end
  end

  defp write_untracked(_workspace, [], _partial), do: {:ok, false}

  defp write_untracked(workspace, untracked, partial) do
    list = Path.join(partial, @untracked_list)
    tar = Path.join(partial, @untracked)

    with :ok <- write_file(list, Enum.map_join(untracked, "", &(&1 <> <<0>>))),
         {_out, 0} <- System.cmd("tar", ["-c", "-f", tar, "-C", workspace, "--null", "-T", list], stderr_to_stdout: true),
         {listing, 0} <- System.cmd("tar", ["-t", "-f", tar], stderr_to_stdout: true),
         :ok <- verify_tar_listing(listing, untracked) do
      {:ok, true}
    else
      {out, status} when is_integer(status) -> {:error, {:untracked_tar_failed, status, out}}
      {:error, _reason} = error -> error
    end
  end

  defp verify_tar_listing(listing, untracked) do
    entries = listing |> String.split("\n", trim: true) |> MapSet.new(&String.trim_trailing(&1, "/"))

    case Enum.reject(untracked, &MapSet.member?(entries, String.trim_trailing(&1, "/"))) do
      [] -> :ok
      missing -> {:error, {:untracked_tar_incomplete, missing}}
    end
  end

  defp write_bundle(_workspace, nil, _path), do: {:ok, false}

  defp write_bundle(workspace, _head, path) do
    with {:ok, count} <- git(workspace, ["rev-list", "--count", "HEAD", "--not", "--remotes"]) do
      if String.trim(count) == "0", do: {:ok, false}, else: create_bundle(workspace, path)
    end
  end

  defp create_bundle(workspace, path) do
    with {:ok, _} <- git(workspace, ["bundle", "create", "--quiet", path, "HEAD", "--not", "--remotes"], true),
         {:ok, _} <- git(workspace, ["bundle", "verify", "--quiet", path], true),
         do: {:ok, true}
  end

  defp restore_commands(workspace, head, branch, files) do
    [
      "cd #{Shell.escape(workspace)}",
      files["unpushed_bundle"] && "git fetch #{Shell.escape(files["unpushed_bundle"])} HEAD",
      head && checkout_command(head, branch),
      files["tracked_patch"] && "git apply --binary #{Shell.escape(files["tracked_patch"])}",
      files["untracked_tar"] && "tar -x -f #{Shell.escape(files["untracked_tar"])}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp checkout_command(head, nil), do: "[ \"$(git rev-parse HEAD)\" = #{head} ] || git checkout --detach #{head}"

  defp checkout_command(head, branch),
    do: "[ \"$(git rev-parse HEAD)\" = #{head} ] || git checkout -B #{Shell.escape(branch)} #{head}"

  # -- retention --------------------------------------------------------------

  # Keep the newest artifacts of each workspace. The newest one is never
  # pruned, so the ticket always keeps its latest saved work while it is open.
  # A partial directory left here is from a save that crashed before it
  # completed, so it holds nothing a reader can use.
  defp prune(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        {partials, artifacts} = Enum.split_with(entries, &String.starts_with?(&1, @partial_prefix))
        Enum.each(partials, &File.rm_rf(Path.join(dir, &1)))

        artifacts
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.reverse()
        |> Enum.drop(@keep_per_workspace)
        |> Enum.each(&File.rm_rf(Path.join(dir, &1)))

      {:error, _reason} ->
        :ok
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp stamp do
    now = DateTime.utc_now()
    {usec, _precision} = now.microsecond

    Calendar.strftime(now, "%Y%m%dT%H%M%S") <>
      "." <> String.pad_leading(Integer.to_string(usec), 6, "0") <> "Z-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:artifact_dir_unwritable, path, reason}}
    end
  end

  defp nonempty(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > 0 -> {:ok, size}
      {:ok, _stat} -> {:error, {:empty_patch, path}}
      {:error, reason} -> {:error, {:patch_unreadable, path, reason}}
    end
  end

  defp write_json(path, map), do: write_file(path, Jason.encode_to_iodata!(map, pretty: true))

  defp write_file(path, content) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, content, [:sync]),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:artifact_write_failed, path, reason}}
    end
  end

  defp read_manifest(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = manifest} <- Jason.decode(body) do
      [Map.put(manifest, "manifest_path", path)]
    else
      _ -> []
    end
  end

  defp git_list(workspace, args) do
    with {:ok, out} <- git(workspace, args), do: {:ok, String.split(out, <<0>>, trim: true)}
  end

  # Commands whose stdout is parsed keep stderr apart; the others fold it in
  # so a failure reason carries git's own message.
  defp git(workspace, args, stderr_to_stdout? \\ false) do
    case git_raw(workspace, args, stderr_to_stdout?) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {:git_failed, args, status, String.slice(out, 0, 2_000)}}
    end
  end

  defp git_raw(workspace, args, stderr_to_stdout? \\ false) do
    System.cmd("git", ["-C", workspace | args], stderr_to_stdout: stderr_to_stdout?, env: @git_env)
  rescue
    error -> {Exception.message(error), 127}
  end

  defp emit_preserved_alert(ticket, action, artifact) do
    message =
      "Saved the uncommitted work of #{ticket} before Aiur tried to #{action}: #{length(artifact["tracked_files"])} tracked and " <>
        "#{length(artifact["untracked_files"])} untracked files at #{artifact["artifact_dir"]}. The next agent turn gets the restore commands."

    Alerts.emit_system("ticket.#{ticket}.workspace.wip_preserved",
      issue: ticket,
      message: message,
      reason: message,
      severity: "warning"
    )
  end
end
