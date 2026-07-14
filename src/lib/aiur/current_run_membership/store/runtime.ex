defmodule Aiur.CurrentRunMembership.Store.Runtime do
  @moduledoc false

  require Logger

  alias Aiur.{CurrentRunMembership, TrackerIdentity}
  alias Aiur.CurrentRunMembership.{Event, Event.Codec, Projection}
  alias Aiur.CurrentRunMembership.Store.{Checkpoint, FileOps, TerminalVerification}

  @max_snapshot_limit 1_000

  @spec handle_observation(Event.t(), map()) :: {:reply, term(), map()}
  def handle_observation(event, state) do
    case Projection.apply(state.projection, event) do
      {:accepted, projection} -> persist(event, projection, state)
      {:ignored, reason, _projection} -> {:reply, {:ok, %{status: reason, generation: state.projection.generation}}, state}
    end
  end

  @spec snapshot(map(), term()) :: map()
  def snapshot(state, limit) do
    members = Projection.members(state.projection)
    visible_members = Enum.take(members, snapshot_limit(limit))

    %{
      run_id: state.run_id,
      generation: state.projection.generation,
      health: state.health,
      health_message: health_message(state.health),
      freshness: freshness(state),
      members: visible_members,
      truncated?: length(members) > length(visible_members)
    }
  end

  @spec mark_reconciled(map(), :fresh | :unavailable) :: map()
  def mark_reconciled(state, status) do
    status = reconciliation_status(state, status)
    changed? = state.reconciliation.status != status
    reconciliation = %{status: status, reconciled_at: state.clock.()}
    state = %{state | reconciliation: reconciliation}
    if changed?, do: notify(state, nil)
    state
  end

  @spec set_terminal_verification_pending(map(), TrackerIdentity.t(), boolean()) :: {:ok, map()} | {:error, term(), map()}
  def set_terminal_verification_pending(state, identity, pending?) do
    with {:ok, key} <- TerminalVerification.pending_key(identity) do
      pending_keys = update_pending_keys(state.terminal_verification_pending_keys, key, pending?)

      if pending_keys == state.terminal_verification_pending_keys do
        {:ok, state}
      else
        persist_terminal_verification_pending(state, pending_keys)
      end
    else
      {:error, _reason} -> terminal_verification_marker_failed(state, :invalid_identity)
    end
  end

  @spec initial_reconciliation(Projection.t()) :: map()
  def initial_reconciliation(projection) do
    status = if Projection.members(projection) == [], do: :unknown, else: :stale
    %{status: status, reconciled_at: nil}
  end

  @spec freshness(map()) :: map()
  def freshness(state) do
    last_observed_at =
      state.projection
      |> Projection.members()
      |> Enum.map(& &1.last_observed_at)
      |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)

    %{
      status: state.reconciliation.status,
      last_observed_at: last_observed_at,
      recovered_at: state.recovered_at,
      reconciled_at: state.reconciliation.reconciled_at,
      terminal_verification_pending?: state.terminal_verification_pending?
    }
  end

  @spec health_message(term()) :: String.t()
  def health_message(:healthy), do: "current-run membership is healthy"
  def health_message({:degraded, {:checkpoint_corrupt, _}}), do: "current-run membership is degraded: checkpoint is corrupt"
  def health_message({:degraded, :checkpoint_corrupt}), do: "current-run membership is degraded: checkpoint is corrupt"
  def health_message({:degraded, {:journal_corrupt, _, _}}), do: "current-run membership is degraded: journal is corrupt"
  def health_message({:degraded, :journal_corrupt}), do: "current-run membership is degraded: journal is corrupt"
  def health_message({:degraded, {:append_failed, _}}), do: "current-run membership is degraded: journal append failed"
  def health_message({:degraded, {:checkpoint_failed, _}}), do: "current-run membership is degraded: checkpoint write failed"
  def health_message({:degraded, {:checkpoint_entry_sync_failed, _}}), do: "current-run membership is degraded: checkpoint directory sync failed"
  def health_message({:degraded, {:journal_compaction_failed, _}}), do: "current-run membership is degraded: journal compaction failed"
  def health_message({:degraded, {:cleanup_failed, _}}), do: "current-run membership is degraded: obsolete generation cleanup failed"
  def health_message({:degraded, {:terminal_verification_marker_failed, _}}), do: "current-run membership is degraded: terminal verification state cannot be stored"
  def health_message({:degraded, _}), do: "current-run membership is degraded"
  def health_message({:unavailable, {:path_unresolved, _}}), do: "current-run membership is unavailable: state path cannot be resolved"
  def health_message({:unavailable, {:prepare_failed, :invalid_run_id}}), do: "current-run membership is unavailable: run identity is invalid"
  def health_message({:unavailable, {:prepare_failed, _}}), do: "current-run membership is unavailable: recovery storage cannot be prepared"
  def health_message({:unavailable, {:journal_unreadable, _}}), do: "current-run membership is unavailable: journal cannot be read"
  def health_message({:unavailable, {:journal_prefix_checkpoint_failed, _}}), do: "current-run membership is unavailable: validated journal prefix cannot be checkpointed"
  def health_message({:unavailable, {:degraded_marker_failed, _}}), do: "current-run membership is unavailable: degraded recovery state cannot be recorded"
  def health_message({:unavailable, {:quarantine_failed, _}}), do: "current-run membership is unavailable: corrupt recovery data cannot be quarantined"
  def health_message({:unavailable, :terminal_verification_marker_invalid}), do: "current-run membership is unavailable: terminal verification state is invalid"
  def health_message({:unavailable, :terminal_verification_marker_too_large}), do: "current-run membership is unavailable: terminal verification state is too large"
  def health_message({:unavailable, _}), do: "current-run membership is unavailable"

  @spec public_health(term()) :: term()
  def public_health(:healthy), do: :healthy
  def public_health({:degraded, {:checkpoint_corrupt, reason}}), do: {:degraded, {:checkpoint_corrupt, recovery_reason(reason)}}
  def public_health({:degraded, {:journal_corrupt, line, reason}}) when is_integer(line) and line > 0, do: {:degraded, {:journal_corrupt, line, recovery_reason(reason)}}

  def public_health({:degraded, {operation, reason}})
      when operation in [:append_failed, :checkpoint_failed, :checkpoint_entry_sync_failed, :journal_compaction_failed, :cleanup_failed, :terminal_verification_marker_failed],
      do: {:degraded, {operation, persistence_reason(reason)}}

  def public_health({:degraded, _}), do: {:degraded, :recovery_degraded}

  def public_health({:unavailable, {operation, reason}})
      when operation in [:path_unresolved, :prepare_failed, :journal_unreadable, :journal_prefix_checkpoint_failed, :degraded_marker_failed, :quarantine_failed],
      do: {:unavailable, {operation, persistence_reason(reason)}}

  def public_health({:unavailable, reason}) when reason in [:terminal_verification_marker_invalid, :terminal_verification_marker_too_large], do: {:unavailable, reason}
  def public_health({:unavailable, _}), do: {:unavailable, :recovery_unavailable}

  defp persist(event, projection, state) do
    case state.append_fun.(state.journal_path, Event.to_record(event)) do
      :ok -> persist_appended_event(event, projection, state)
      {:error, reason} -> persist_failed(%{state | writable?: false}, {:append_failed, reason})
    end
  end

  defp persist_appended_event(event, projection, state) do
    state = %{state | journal_event_count: state.journal_event_count + 1}
    if state.journal_event_count >= state.checkpoint_interval, do: persist_checkpoint(event, projection, state), else: finish_journal_append(event, projection, state)
  end

  defp finish_journal_append(event, projection, state) do
    state = %{state | projection: projection}
    notify(state, event)
    {:reply, {:ok, %{status: :accepted, generation: projection.generation}}, state}
  end

  defp persist_checkpoint(event, projection, state) do
    checkpoint = Checkpoint.record(projection)

    with :ok <- Codec.validate_checkpoint_record_size(checkpoint),
         :ok <- state.checkpoint_fun.(state.checkpoint_path, checkpoint),
         :ok <- FileOps.ensure_regular_file(state.checkpoint_path),
         :ok <- FileOps.sync_recovery_entry(state.sync_fun) do
      finish_checkpoint(event, %{state | projection: projection, health: persisted_health(state.health)})
    else
      {:error, :checkpoint_entry_sync_failed, reason} -> persist_failed(%{state | writable?: false}, {:checkpoint_entry_sync_failed, reason})
      {:error, reason} -> persist_failed(%{state | writable?: false}, {:checkpoint_failed, reason})
    end
  end

  defp finish_checkpoint(event, state) do
    case state.clear_journal_fun.(state.journal_path) do
      :ok ->
        state = %{state | journal_event_count: 0}
        notify(state, event)
        {:reply, {:ok, %{status: :accepted, generation: state.projection.generation}}, state}

      {:error, reason} ->
        state = %{state | health: public_health({:degraded, {:journal_compaction_failed, reason}})}
        notify(state, event)
        {:reply, {:ok, %{status: :accepted, generation: state.projection.generation}}, state}
    end
  end

  defp persist_failed(state, reason) do
    health = public_health({:degraded, reason})
    state = %{state | health: health}
    notify(state, nil)
    {:reply, {:error, {:membership_persistence_failed, persistence_failure_reason(health)}}, state}
  end

  defp update_pending_keys(pending_keys, key, true), do: MapSet.put(pending_keys, key)
  defp update_pending_keys(pending_keys, key, false), do: MapSet.delete(pending_keys, key)

  defp persist_terminal_verification_pending(state, pending_keys) do
    case state.terminal_verification_marker_fun.(state.terminal_verification_path, state.run_id, pending_keys, state.sync_fun) do
      :ok ->
        state = %{
          state
          | terminal_verification_pending_keys: pending_keys,
            terminal_verification_pending?: TerminalVerification.pending?(pending_keys)
        }

        notify(state, nil)
        {:ok, state}

      {:error, reason} ->
        terminal_verification_marker_failed(state, reason)
    end
  rescue
    error -> terminal_verification_marker_failed(state, error)
  catch
    kind, reason -> terminal_verification_marker_failed(state, {kind, reason})
  end

  defp terminal_verification_marker_failed(state, reason) do
    health = public_health({:degraded, {:terminal_verification_marker_failed, reason}})
    state = %{state | health: health, terminal_verification_pending?: true}
    notify(state, nil)
    {:error, :terminal_verification_marker_failed, state}
  end

  defp snapshot_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_snapshot_limit)
  defp snapshot_limit(_), do: @max_snapshot_limit
  defp persisted_health({:degraded, {:cleanup_failed, _}} = health), do: health
  defp persisted_health(_), do: :healthy
  defp reconciliation_status(%{terminal_verification_pending?: true}, :fresh), do: :unavailable
  defp reconciliation_status(_, status), do: status
  defp recovery_reason(reason) when reason in [:checksum_mismatch, :invalid_checkpoint, :invalid_record, :invalid_checksum, :record_too_large, :symlink_rejected, :not_a_regular_file], do: reason
  defp recovery_reason(_), do: :invalid_recovery_record

  defp persistence_reason(reason)
       when reason in [
              :invalid_run_id,
              :disk_full,
              :acknowledgement_lost,
              :compaction_failed,
              :rename_failed,
              :sync_failed,
              :permission_denied,
              :record_too_large,
              :injected_marker_write_failure,
              :atomic_write_not_visible,
              :enoent,
              :eacces,
              :enospc
            ],
       do: reason

  defp persistence_reason(_), do: :persistence_failure
  defp persistence_failure_reason({:degraded, reason}), do: reason

  @spec notify(map(), Event.t() | nil) :: :ok
  def notify(state, event) do
    CurrentRunMembership.broadcast_changed(state.run_id, state.projection.generation, event, state.health, freshness(state))
  rescue
    error -> Logger.warning("aiur_current_run_membership phase=notify_failed error=#{Exception.message(error)}")
  end
end
