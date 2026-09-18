defmodule Aiur.Workspace.WipPreservation do
  @moduledoc """
  Saves the uncommitted state of a workspace before Aiur deletes or recreates
  it (#2743).

  The stale-leftover recreate (#577) and the workspace cleanups run `rm -rf` on
  a checkout. When that checkout still holds an agent's uncommitted work, the
  work is lost. Before any such delete, `guard_destroy/5` writes the dirty state
  to the daemon runtime state directory, outside the workspace:

      <runtime_state_dir>/wip-preserved/            mode 0700
        <workspace leaf>/                           mode 0700
          generation                                notice generation (see below)
          hold-alerted.json                         the refusal already alerted
          discard-dirty-workspace                   operator discard authorization
          <UTC stamp>/                              mode 0700, files mode 0600
            tracked.patch            git diff --binary against HEAD (staged and unstaged)
            untracked.tar            untracked files that are not ignored
            unpushed-commits.bundle  commits of HEAD that no remote-tracking ref holds
            manifest.json            HEAD, branch, file lists, skipped paths, restore commands

  Files, not a private ref: a ref lives in the object store of the checkout
  that is about to be deleted, so it cannot survive the delete. A patch and a
  tarball survive the delete and daemon restarts, and `git apply` and `tar`
  restore them in any fresh clone. Untracked files can hold secrets, so the
  directories are private to the daemon user.

  `Aiur.Workspace.WipPreservation.Capture` bounds the save (size caps and a
  per-command timeout) and `Aiur.Workspace.WipPreservation.Retention` bounds
  the directory. The bounds are the `workspace.wip_*` settings.

  ## Failure

  If the state cannot be saved, the delete does not run: the caller gets
  `{:error, {:wip_preservation_failed, workspace, reason}}` and one operator
  alert fires per workspace and reason. There are two exceptions. A terminal
  cleanup (`terminal?: true`) whose save timed out writes a manifest-only save
  and deletes the workspace, with an alert. An operator can authorize the
  delete of a workspace whose work cannot be saved, remote ones included,
  with `authorize_discard/1` or by creating the `discard-dirty-workspace`
  file.

  ## Worker notice

  The next agent turn of the same ticket gets the restore commands through
  `with_pending_notices/3`. A notice belongs to one ticket and one notice
  generation of its workspace leaf. Closing the ticket advances the
  generation (`expire_notices/1`), so the notice of a ticket that closed
  before its next turn is never delivered, also not to a later workspace with
  the same leaf. Delivery is at least once: a notice is marked delivered only
  after a turn that carried it completes, so a crash between the two repeats
  it in the next turn.
  """

  require Logger

  alias Aiur.Alerts
  alias Aiur.Config
  alias Aiur.Config.Paths
  alias Aiur.Workspace.WipPreservation.{Capture, Command, Retention}

  @root_name "wip-preserved"
  @generation_file "generation"
  @hold_file "hold-alerted.json"
  @discard_file "discard-dirty-workspace"
  @orchestrator_check_timeout_ms 5_000

  @type artifact :: %{required(String.t()) => term()}

  @doc "How many saves are kept per workspace. Older ones are pruned only when a newer one exists."
  @spec keep_per_workspace() :: pos_integer()
  def keep_per_workspace, do: Retention.keep_per_workspace()

  @doc """
  The save bounds from the `workspace.wip_*` settings: `:max_bytes`,
  `:max_file_bytes`, `:max_dir_files`, `:command_timeout_ms`,
  `:retention_bytes` and `:retention_days`.
  """
  @spec limits() :: map()
  def limits do
    workspace =
      try do
        Config.settings!().workspace
      rescue
        _error -> %Aiur.Config.Schema.Workspace{}
      end

    %{
      max_bytes: workspace.wip_max_bytes,
      max_file_bytes: workspace.wip_max_file_bytes,
      max_dir_files: workspace.wip_max_dir_files,
      command_timeout_ms: workspace.wip_command_timeout_ms,
      retention_bytes: workspace.wip_retention_bytes,
      retention_days: workspace.wip_retention_days
    }
  end

  @doc """
  Runs `destroy_fun` only after the dirty state of `workspace` is saved.

  A clean workspace, a missing one and a directory that is not a Git checkout
  go straight to `destroy_fun`. A dirty one is saved first; the
  `ticket.<ticket>.workspace.wip_preserved` alert fires after `destroy_fun`
  returns. When the save fails, `destroy_fun` does not run, except as the
  module doc describes. Options: `terminal?` (the ticket is closed).
  """
  @spec guard_destroy(Path.t(), String.t(), String.t(), (-> result), keyword()) ::
          result | {:error, {:wip_preservation_failed, Path.t(), term()}}
        when result: term()
  def guard_destroy(workspace, ticket, action, destroy_fun, opts \\ [])
      when is_binary(workspace) and is_binary(ticket) and is_binary(action) and is_function(destroy_fun, 0) do
    leaf = Path.basename(workspace)

    case preserve(workspace, action, ticket: ticket) do
      {:ok, :clean} ->
        destroyed(leaf, destroy_fun.())

      {:ok, artifact} ->
        Logger.warning("Preserved uncommitted workspace state before an attempt to #{action} ticket=#{ticket} workspace=#{workspace} artifact=#{artifact["artifact_dir"]}")

        result = destroy_fun.()
        emit_preserved_alert(ticket, action, artifact)
        destroyed(leaf, result)

      {:error, reason} ->
        destroy_unsaved(workspace, ticket, action, reason, destroy_fun, opts)
    end
  end

  defp destroy_unsaved(workspace, ticket, action, reason, destroy_fun, opts) do
    leaf = Path.basename(workspace)

    cond do
      discard_authorized?(leaf) ->
        Logger.warning("Discarding unsaved workspace work on operator authorization ticket=#{ticket} workspace=#{workspace} reason=#{inspect(reason)}")
        result = destroy_fun.()
        emit_discarded_alert(ticket, workspace, reason)
        destroyed(leaf, result)

      Keyword.get(opts, :terminal?, false) and Command.timeout?(reason) ->
        destroy_after_incomplete_save(workspace, ticket, action, reason, destroy_fun, opts)

      true ->
        refuse(workspace, ticket, action, reason, opts)
    end
  end

  # A closed ticket whose save timed out: the workspace is deleted anyway so a
  # huge or hung checkout cannot pin it forever. The manifest records what was
  # attempted and why it is incomplete.
  defp destroy_after_incomplete_save(workspace, ticket, action, reason, destroy_fun, opts) do
    case write_incomplete(workspace, ticket, action, reason) do
      {:ok, artifact} ->
        result = destroy_fun.()
        emit_incomplete_alert(ticket, workspace, reason, artifact)
        destroyed(Path.basename(workspace), result)

      {:error, write_reason} ->
        refuse(workspace, ticket, action, {reason, write_reason}, opts)
    end
  end

  defp destroyed(leaf, result) do
    if match?(:ok, result) or match?({:ok, _}, result) do
      clear_hold(leaf)
      consume_discard(leaf)
    end

    result
  end

  @doc """
  Refuses a destructive `action` on `workspace` for `reason` and returns the
  named hold reason. The `ticket.<ticket>.workspace.wip_preservation_failed`
  alert fires once per workspace, action and reason class; a repeat of the same
  refusal is only logged. Options: `terminal?` (the ticket is closed, so the
  workspace is kept but no ticket is held).
  """
  @spec refuse(Path.t(), String.t(), String.t(), term(), keyword()) :: {:error, {:wip_preservation_failed, Path.t(), term()}}
  def refuse(workspace, ticket, action, reason, opts \\ []) do
    leaf = Path.basename(workspace)
    key = "#{action}|#{reason_class(reason)}"

    if hold_alerted?(leaf, key) do
      Logger.info("Still refusing #{action}: uncommitted workspace state cannot be preserved ticket=#{ticket} workspace=#{workspace} reason=#{inspect(reason)}")
    else
      Logger.error("Refusing #{action}: uncommitted workspace state could not be preserved ticket=#{ticket} workspace=#{workspace} reason=#{inspect(reason)}")
      message = refusal_message(workspace, ticket, action, reason, Keyword.get(opts, :terminal?, false))

      Alerts.emit_system("ticket.#{ticket}.workspace.wip_preservation_failed",
        issue: ticket,
        message: message,
        reason: message,
        needs_attention: true,
        severity: "warning"
      )

      record_hold(leaf, key)
    end

    {:error, {:wip_preservation_failed, workspace, reason}}
  end

  defp refusal_message(workspace, ticket, action, reason, terminal?) do
    cause =
      case reason do
        :remote_worker_unsupported -> "the uncommitted work of a remote worker's checkout cannot be saved on this daemon"
        _ -> "its uncommitted work could not be saved (#{inspect(reason)})"
      end

    outcome =
      if terminal?,
        do: "#{ticket} is closed. The workspace at #{workspace} is kept with its uncommitted work.",
        else: "The workspace at #{workspace} is unchanged and the ticket is held."

    "Did not #{action} the workspace of #{ticket}: #{cause}. #{outcome} " <>
      "To delete it without a save, create #{discard_path(Path.basename(workspace))}, then resume the ticket or restart Aiur."
  end

  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: reason |> elem(0) |> reason_class()
  defp reason_class(_reason), do: "other"

  @doc """
  Saves the dirty state of `workspace`. Returns `{:ok, :clean}` when there is
  nothing to save, `{:ok, manifest}` when a save was written and
  `{:error, reason}` when the state could not be saved. Options: `ticket`.
  """
  @spec preserve(Path.t(), String.t(), keyword()) :: {:ok, :clean} | {:ok, artifact()} | {:error, term()}
  def preserve(workspace, action \\ "delete the workspace", opts \\ []) when is_binary(workspace) and is_binary(action) do
    limits = limits()

    case Capture.dirty?(workspace, limits) do
      {:ok, false} -> {:ok, :clean}
      {:ok, true} -> write_artifact(workspace, action, Keyword.get(opts, :ticket), limits)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  True when `workspace` has uncommitted changes. The check has a short time
  limit because the Orchestrator calls it; an error means "unknown".
  """
  @spec dirty?(Path.t()) :: {:ok, boolean()} | {:error, term()}
  def dirty?(workspace) when is_binary(workspace) do
    limits = limits()
    Capture.dirty?(workspace, %{limits | command_timeout_ms: min(limits.command_timeout_ms, @orchestrator_check_timeout_ms)})
  end

  @doc "The save directory root for one workspace leaf."
  @spec workspace_dir(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def workspace_dir(leaf) when is_binary(leaf) do
    with {:ok, root} <- root_dir(), do: {:ok, Path.join(root, Paths.sanitize(leaf, "issue"))}
  end

  defp root_dir do
    case Paths.runtime_state_dir() do
      {:ok, root} -> {:ok, Path.join(root, @root_name)}
      {:error, reason} -> {:error, {:runtime_state_dir_unavailable, reason}}
    end
  end

  # -- notices ----------------------------------------------------------------

  @doc """
  Returns the manifests of `workspace` whose notice no agent turn has carried
  yet, oldest first. Only saves of `ticket` (when given) in the current notice
  generation of the workspace count.
  """
  @spec pending_notices(Path.t(), String.t() | nil) :: [artifact()]
  def pending_notices(workspace, ticket \\ nil) when is_binary(workspace) do
    leaf = Path.basename(workspace)
    generation = current_generation(leaf)

    leaf
    |> artifact_dirs()
    |> Enum.flat_map(&read_manifest(Path.join(&1, Capture.manifest_name())))
    |> Enum.filter(fn manifest ->
      is_nil(manifest["notice_delivered_at"]) and manifest["complete"] != false and
        Map.get(manifest, "notice_generation", 0) == generation and
        (is_nil(ticket) or Map.get(manifest, "ticket", ticket) == ticket)
    end)
  end

  @doc """
  Puts the restore notice of every pending save of `ticket` in front of
  `prompt`. Returns the prompt and the notices it carries; pass them to
  `mark_delivered/1` once the turn has run.
  """
  @spec with_pending_notices(Path.t(), String.t() | nil, String.t()) :: {String.t(), [artifact()]}
  def with_pending_notices(workspace, ticket, prompt) when is_binary(workspace) and is_binary(prompt) do
    case pending_notices(workspace, ticket) do
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
          HEAD at save time #{notice["head"] || "(no commit)"} on branch #{notice["branch"] || "(detached)"}; #{length(notice["tracked_files"] || [])} tracked and #{length(notice["untracked_files"] || [])} untracked files.#{skipped_line(notice)}
          Restore with these commands, in order. They apply the work to the current HEAD:
        #{Enum.map_join(notice["restore_commands"] || [], "\n", &("      " <> &1))}
        """
      end)

    """
    Aiur preserved uncommitted work (#2743):

    Aiur had to delete or recreate this workspace while it still held uncommitted changes. It saved the changes first; they are not in the current workspace. Restore them before you continue, or say in the workpad why they are no longer needed. This notice can repeat after a restart; if the work is already restored, do not restore it twice.
    #{body}
    """
  end

  defp skipped_line(%{"skipped_untracked" => [_ | _] = skipped}),
    do: " Not saved because of the size bounds: " <> Enum.map_join(skipped, ", ", & &1["path"]) <> "."

  defp skipped_line(_notice), do: ""

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

  @doc """
  Expires every pending notice of a workspace leaf: its ticket closed. Saves
  written after this call belong to the next generation.
  """
  @spec expire_notices(String.t()) :: :ok
  def expire_notices(leaf) when is_binary(leaf) do
    with {:ok, dir} <- workspace_dir(leaf),
         true <- File.dir?(dir),
         :ok <- write_file(Path.join(dir, @generation_file), Integer.to_string(current_generation(leaf) + 1)) do
      :ok
    else
      false -> :ok
      {:error, reason} -> Logger.warning("Could not expire preserved-work notices leaf=#{leaf} reason=#{inspect(reason)}")
    end
  end

  @doc "The notice generation of a workspace leaf; 0 until its ticket first closes."
  @spec current_generation(String.t()) :: non_neg_integer()
  def current_generation(leaf) do
    with {:ok, dir} <- workspace_dir(leaf),
         {:ok, body} <- File.read(Path.join(dir, @generation_file)),
         {generation, _rest} when generation >= 0 <- Integer.parse(String.trim(body)) do
      generation
    else
      _ -> 0
    end
  end

  # -- holds and discards ------------------------------------------------------

  @doc """
  Authorizes Aiur to delete the workspace with this leaf without a save, the
  next time it tries. Use it for a dirty remote checkout or a local one whose
  save keeps failing, after you decided the work is not needed.
  """
  @spec authorize_discard(String.t()) :: :ok | {:error, term()}
  def authorize_discard(leaf) when is_binary(leaf) do
    with {:ok, dir} <- workspace_dir(leaf),
         :ok <- mkdir_private(dir),
         do: write_file(Path.join(dir, @discard_file), DateTime.utc_now() |> DateTime.to_iso8601())
  end

  @doc "True when an operator authorized the delete of this workspace leaf without a save."
  @spec discard_authorized?(String.t()) :: boolean()
  def discard_authorized?(leaf), do: File.exists?(discard_path(leaf))

  @doc "Records that the authorized discard happened, so it does not apply again."
  @spec consume_discard(String.t()) :: :ok
  def consume_discard(leaf) do
    _ = File.rm(discard_path(leaf))
    :ok
  end

  @doc "Forgets the refusal of this workspace leaf: it was deleted or discarded."
  @spec clear_hold(String.t()) :: :ok
  def clear_hold(leaf) do
    with {:ok, dir} <- workspace_dir(leaf), do: File.rm(Path.join(dir, @hold_file))
    :ok
  end

  @doc "Alerts the discard of a workspace whose work was not saved."
  @spec emit_discarded_alert(String.t(), Path.t(), term()) :: :ok
  def emit_discarded_alert(ticket, workspace, reason) do
    message = "Deleted the workspace of #{ticket} at #{workspace} without saving its uncommitted work, as an operator authorized (#{inspect(reason)})."
    _ = Alerts.emit_system("ticket.#{ticket}.workspace.wip_discarded", issue: ticket, message: message, reason: message, severity: "warning")
    :ok
  end

  defp discard_path(leaf) do
    case workspace_dir(leaf) do
      {:ok, dir} -> Path.join(dir, @discard_file)
      {:error, _reason} -> Path.join(["<runtime_state_dir>", @root_name, leaf, @discard_file])
    end
  end

  defp hold_alerted?(leaf, key) do
    with {:ok, dir} <- workspace_dir(leaf),
         {:ok, body} <- File.read(Path.join(dir, @hold_file)),
         {:ok, %{"key" => ^key}} <- Jason.decode(body) do
      true
    else
      _ -> false
    end
  end

  defp record_hold(leaf, key) do
    with {:ok, dir} <- workspace_dir(leaf),
         :ok <- mkdir_private(dir),
         :ok <- write_json(Path.join(dir, @hold_file), %{"key" => key, "at" => DateTime.utc_now() |> DateTime.to_iso8601()}) do
      :ok
    else
      {:error, reason} -> Logger.warning("Could not record the preserved-work refusal leaf=#{leaf} reason=#{inspect(reason)}")
    end
  end

  # -- capture ----------------------------------------------------------------

  defp write_artifact(workspace, action, ticket, limits) do
    leaf = Path.basename(workspace)
    stamp = stamp()

    with {:ok, dir} <- workspace_dir(leaf),
         final = Path.join(dir, stamp),
         partial = Path.join(dir, Retention.partial_prefix() <> stamp),
         :ok <- mkdir_private(partial),
         context = %{workspace: workspace, partial: partial, final: final, limits: limits},
         {:ok, captured} <- discard_on_error(Capture.capture(context), partial),
         manifest = Map.merge(base_manifest(workspace, leaf, ticket, action, final), captured),
         :ok <- discard_on_error(write_json(Path.join(partial, Capture.manifest_name()), manifest), partial),
         :ok <- discard_on_error(promote(partial, final), partial) do
      prune(limits)
      {:ok, Map.put(manifest, "manifest_path", Path.join(final, Capture.manifest_name()))}
    end
  end

  defp write_incomplete(workspace, ticket, action, reason) do
    leaf = Path.basename(workspace)
    stamp = stamp()

    with {:ok, dir} <- workspace_dir(leaf),
         final = Path.join(dir, stamp),
         partial = Path.join(dir, Retention.partial_prefix() <> stamp),
         :ok <- mkdir_private(partial),
         manifest =
           workspace
           |> base_manifest(leaf, ticket, action, final)
           |> Map.merge(%{"complete" => false, "failure" => inspect(reason), "files" => %{}, "restore_commands" => []}),
         :ok <- discard_on_error(write_json(Path.join(partial, Capture.manifest_name()), manifest), partial),
         :ok <- discard_on_error(promote(partial, final), partial) do
      {:ok, manifest}
    end
  end

  defp base_manifest(workspace, leaf, ticket, action, final) do
    %{
      "version" => 2,
      "ticket" => ticket,
      "notice_generation" => current_generation(leaf),
      "workspace" => workspace,
      "workspace_leaf" => leaf,
      "action" => action,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "artifact_dir" => final,
      "complete" => true,
      "skipped_untracked" => [],
      "notice_delivered_at" => nil
    }
  end

  # The save appears under its final name only once every file is written,
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

  defp prune(limits) do
    with {:ok, root} <- root_dir(), do: Retention.prune(root, limits, &current_generation/1)
  end

  defp artifact_dirs(leaf) do
    with {:ok, dir} <- workspace_dir(leaf),
         {:ok, entries} <- File.ls(dir) do
      entries |> Enum.filter(&Retention.artifact_name?/1) |> Enum.sort() |> Enum.map(&Path.join(dir, &1))
    else
      _ -> []
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp stamp do
    now = DateTime.utc_now()
    {usec, _precision} = now.microsecond

    Calendar.strftime(now, "%Y%m%dT%H%M%S") <>
      "." <> String.pad_leading(Integer.to_string(usec), 6, "0") <> "Z-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  # Creates `path` and makes it and every directory up to `wip-preserved/`
  # private to the daemon user: untracked files can hold secrets.
  defp mkdir_private(path) do
    with {:ok, root} <- root_dir(),
         :ok <- mkdir(path) do
      path
      |> Path.relative_to(root)
      |> Path.split()
      |> Enum.scan(root, &Path.join(&2, &1))
      |> then(&[root | &1])
      |> Enum.reduce_while(:ok, &chmod_private/2)
    end
  end

  defp chmod_private(dir, :ok) do
    case File.chmod(dir, 0o700) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:artifact_dir_unwritable, dir, reason}}}
    end
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:artifact_dir_unwritable, path, reason}}
    end
  end

  defp write_json(path, map), do: write_file(path, Jason.encode_to_iodata!(map, pretty: true))

  defp write_file(path, content) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, content, [:sync]),
         :ok <- File.chmod(tmp, 0o600),
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

  defp emit_preserved_alert(ticket, action, artifact) do
    skipped = artifact["skipped_untracked"] || []

    message =
      "Saved the uncommitted work of #{ticket} before Aiur tried to #{action}: #{length(artifact["tracked_files"])} tracked and " <>
        "#{length(artifact["untracked_files"])} untracked files at #{artifact["artifact_dir"]}." <>
        if(skipped == [], do: "", else: " #{length(skipped)} untracked paths were over the size bounds and not saved; the manifest lists them.") <>
        " The next agent turn gets the restore commands."

    Alerts.emit_system("ticket.#{ticket}.workspace.wip_preserved",
      issue: ticket,
      message: message,
      reason: message,
      severity: "warning"
    )
  end

  defp emit_incomplete_alert(ticket, workspace, reason, artifact) do
    message =
      "Deleted the workspace of closed ticket #{ticket} at #{workspace} after its uncommitted-work save timed out (#{inspect(reason)}). " <>
        "Only a manifest was saved, at #{artifact["artifact_dir"]}."

    Alerts.emit_system("ticket.#{ticket}.workspace.wip_preservation_incomplete",
      issue: ticket,
      message: message,
      reason: message,
      needs_attention: true,
      severity: "warning"
    )
  end
end
