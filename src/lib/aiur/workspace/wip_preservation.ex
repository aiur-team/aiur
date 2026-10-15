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
          discard-dirty-workspace                   discard signal (not access control)
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
  and deletes the workspace, with an alert. The delete of a workspace whose
  work cannot be saved, remote ones included, is authorized with
  `authorize_discard/1` or by creating the `discard-dirty-workspace` file.

  The discard file is a deliberate operator signal that lives outside the
  workspace. It is not an access control: agents run as the same Unix user
  as the daemon, without a filesystem sandbox, so an agent can create it too.
  It gives no capability beyond what that user already has, since the same
  user can delete the workspace directly. Real isolation needs a sandbox,
  which this module does not provide.

  A closed ticket's cleanup that crashes before the delete leaves the
  workspace in place. It is tried again only by the terminal sweep at the
  next daemon start.

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

  alias Aiur.Config
  alias Aiur.Signal
  alias Aiur.Workspace.WipPreservation.{Artifact, Capture, Command, Notices, Retention}

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
  module doc describes. `destroy_fun` can return `{:skipped, reason}` to keep
  the workspace after the save (a new run claimed it); the save is kept.
  Options: `terminal?` (the ticket is closed), `before_destroy` (a callback
  that runs after the initial save and before a second save plus deletion).
  """
  @spec guard_destroy(Path.t(), String.t(), String.t(), (-> result), keyword()) ::
          result | {:error, {:wip_preservation_failed, Path.t(), term()}}
        when result: term()
  def guard_destroy(workspace, ticket, action, destroy_fun, opts \\ [])
      when is_binary(workspace) and is_binary(ticket) and is_binary(action) and is_function(destroy_fun, 0) do
    leaf = Path.basename(workspace)

    case preserve(workspace, action, ticket: ticket) do
      {:ok, :clean} ->
        destroy_after_prepare(workspace, ticket, action, destroy_fun, opts, leaf)

      {:ok, artifact} ->
        destroy_saved(workspace, ticket, action, destroy_fun, opts, artifact, leaf)

      {:error, reason} ->
        destroy_unsaved(workspace, ticket, action, reason, destroy_fun, opts)
    end
  end

  defp destroy_after_prepare(workspace, ticket, action, destroy_fun, opts, leaf) do
    case before_destroy_callback(opts) do
      {:callback, callback} -> run_clean_callback(workspace, ticket, action, destroy_fun, opts, leaf, callback)
      :none -> destroyed(leaf, destroy_fun.())
    end
  end

  defp destroy_saved(workspace, ticket, action, destroy_fun, opts, artifact, leaf) do
    case before_destroy_callback(opts) do
      {:callback, callback} -> run_saved_callback(workspace, ticket, action, destroy_fun, opts, artifact, leaf, callback)
      :none -> destroy_and_alert(ticket, action, destroy_fun, artifact, leaf, workspace)
    end
  end

  defp before_destroy_callback(opts) do
    case Keyword.get(opts, :before_destroy) do
      callback when is_function(callback, 0) -> {:callback, callback}
      nil -> :none
    end
  end

  defp run_clean_callback(workspace, ticket, action, destroy_fun, opts, leaf, callback) do
    case callback.() do
      {:skipped, _reason} = skipped -> destroyed(leaf, skipped)
      _result -> guard_destroy(workspace, ticket, action, destroy_fun, Keyword.delete(opts, :before_destroy))
    end
  end

  defp run_saved_callback(workspace, ticket, action, destroy_fun, opts, artifact, leaf, callback) do
    case callback.() do
      {:skipped, _reason} = skipped ->
        destroyed(leaf, skipped)

      _result ->
        result = guard_destroy(workspace, ticket, action, destroy_fun, Keyword.delete(opts, :before_destroy))
        mark_delivered_after_delete(result, artifact)
    end
  end

  defp mark_delivered_after_delete(result, artifact) do
    if match?(:ok, result) or match?({:ok, _value}, result), do: mark_delivered([artifact])
    result
  end

  defp destroy_and_alert(ticket, action, destroy_fun, artifact, leaf, workspace) do
    Logger.warning("Preserved uncommitted workspace state before an attempt to #{action} ticket=#{ticket} workspace=#{workspace} artifact=#{artifact["artifact_dir"]}")

    result = destroy_fun.()
    unless match?({:skipped, _reason}, result), do: Artifact.emit_preserved_alert(ticket, action, artifact)
    destroyed(leaf, result)
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
    case Artifact.write_incomplete(workspace, ticket, action, reason) do
      {:ok, artifact} ->
        result = destroy_fun.()
        unless match?({:skipped, _reason}, result), do: Artifact.emit_incomplete_alert(ticket, workspace, reason, artifact)
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

    if Notices.hold_alerted?(leaf, key) do
      Logger.info("Still refusing #{action}: uncommitted workspace state cannot be preserved ticket=#{ticket} workspace=#{workspace} reason=#{inspect(reason)}")
    else
      Logger.error("Refusing #{action}: uncommitted workspace state could not be preserved ticket=#{ticket} workspace=#{workspace} reason=#{inspect(reason)}")
      message = refusal_message(workspace, ticket, action, reason, Keyword.get(opts, :terminal?, false))

      Signal.alert("ticket.#{ticket}.workspace.wip_preservation_failed",
        issue: ticket,
        message: message,
        reason: message,
        needs_attention: true,
        severity: "warning"
      )

      Notices.record_hold(leaf, key)
    end

    {:error, {:wip_preservation_failed, workspace, reason}}
  end

  defp refusal_message(workspace, ticket, action, reason, terminal?) do
    cause =
      case reason do
        :remote_worker_unsupported -> "the uncommitted or unpushed work of a remote worker's checkout cannot be saved on this daemon"
        _ -> "its uncommitted work could not be saved (#{inspect(reason)})"
      end

    outcome =
      if terminal?,
        do: "#{ticket} is closed. The workspace at #{workspace} is kept with its uncommitted or unpushed work.",
        else: "The workspace at #{workspace} is unchanged and the ticket is held."

    "Did not #{action} the workspace of #{ticket}: #{cause}. #{outcome} " <>
      "To delete it without a save, create #{Notices.discard_path(Path.basename(workspace))}, then resume the ticket or restart Aiur."
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
      {:ok, true} -> Artifact.write_artifact(workspace, action, Keyword.get(opts, :ticket), limits)
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
  defdelegate workspace_dir(leaf), to: Artifact

  @doc """
  Returns the manifests of `workspace` whose notice no agent turn has carried
  yet, oldest first. Only saves of `ticket` (when given) in the current notice
  generation of the workspace count.
  """
  @spec pending_notices(Path.t(), String.t() | nil) :: [artifact()]
  defdelegate pending_notices(workspace, ticket \\ nil), to: Notices

  @doc """
  Puts the restore notice of every pending save of `ticket` in front of
  `prompt`. Returns the prompt and the notices it carries; pass them to
  `mark_delivered/1` once the turn has run.
  """
  @spec with_pending_notices(Path.t(), String.t() | nil, String.t()) :: {String.t(), [artifact()]}
  defdelegate with_pending_notices(workspace, ticket, prompt), to: Notices

  @doc "The agent-facing text for `notices`."
  @spec notice_text([artifact()]) :: String.t()
  defdelegate notice_text(notices), to: Notices

  @doc "Records that an agent turn carried `notices`."
  @spec mark_delivered([artifact()]) :: :ok
  defdelegate mark_delivered(notices), to: Notices

  @doc """
  Expires every pending notice of a workspace leaf: its ticket closed. Saves
  written after this call belong to the next generation.
  """
  @spec expire_notices(String.t()) :: :ok
  defdelegate expire_notices(leaf), to: Artifact

  @doc "The notice generation of a workspace leaf; 0 until its ticket first closes."
  @spec current_generation(String.t()) :: non_neg_integer()
  defdelegate current_generation(leaf), to: Artifact

  @doc """
  Authorizes Aiur to delete the workspace with this leaf without a save, the
  next time it tries. Use it for a dirty remote checkout or a local one whose
  save keeps failing, after you decided the work is not needed.
  """
  @spec authorize_discard(String.t()) :: :ok | {:error, term()}
  defdelegate authorize_discard(leaf), to: Notices

  @doc "True when the discard file authorizes the delete of this workspace leaf without a save."
  @spec discard_authorized?(String.t()) :: boolean()
  defdelegate discard_authorized?(leaf), to: Notices

  @doc "Records that the authorized discard happened, so it does not apply again."
  @spec consume_discard(String.t()) :: :ok
  defdelegate consume_discard(leaf), to: Notices

  @doc "Forgets the refusal of this workspace leaf: it was deleted or discarded."
  @spec clear_hold(String.t()) :: :ok
  defdelegate clear_hold(leaf), to: Notices

  @doc "Alerts the discard of a workspace whose work was not saved."
  @spec emit_discarded_alert(String.t(), Path.t(), term()) :: :ok
  defdelegate emit_discarded_alert(ticket, workspace, reason), to: Notices
end
