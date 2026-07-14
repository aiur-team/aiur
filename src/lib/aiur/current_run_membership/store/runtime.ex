defmodule Aiur.CurrentRunMembership.Store.Runtime do
  @moduledoc false

  require Logger

  alias Aiur.CurrentRunMembership
  alias Aiur.CurrentRunMembership.{Event, Projection}
  alias Aiur.CurrentRunMembership.Store.{Checkpoint, FileOps}

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
    changed? = state.reconciliation.status != status
    reconciliation = %{status: status, reconciled_at: state.clock.()}
    state = %{state | reconciliation: reconciliation}
    if changed?, do: notify(state, nil)
    state
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
      reconciled_at: state.reconciliation.reconciled_at
    }
  end

  @spec health_message(term()) :: String.t()
  def health_message(:healthy), do: "current-run membership is healthy"
  def health_message({:degraded, {:checkpoint_corrupt, _reason}}), do: "current-run membership is degraded: checkpoint is corrupt"
  def health_message({:degraded, :checkpoint_corrupt}), do: "current-run membership is degraded: checkpoint is corrupt"
  def health_message({:degraded, {:journal_corrupt, _line, _reason}}), do: "current-run membership is degraded: journal is corrupt"
  def health_message({:degraded, :journal_corrupt}), do: "current-run membership is degraded: journal is corrupt"
  def health_message({:degraded, {:append_failed, _reason}}), do: "current-run membership is degraded: journal append failed"
  def health_message({:degraded, {:checkpoint_failed, _reason}}), do: "current-run membership is degraded: checkpoint write failed"
  def health_message({:degraded, {:checkpoint_entry_sync_failed, _reason}}), do: "current-run membership is degraded: checkpoint directory sync failed"
  def health_message({:degraded, {:journal_compaction_failed, _reason}}), do: "current-run membership is degraded: journal compaction failed"
  def health_message({:degraded, {:cleanup_failed, _reason}}), do: "current-run membership is degraded: obsolete generation cleanup failed"
  def health_message({:degraded, _reason}), do: "current-run membership is degraded"
  def health_message({:unavailable, {:path_unresolved, _reason}}), do: "current-run membership is unavailable: state path cannot be resolved"
  def health_message({:unavailable, {:prepare_failed, :invalid_run_id}}), do: "current-run membership is unavailable: run identity is invalid"
  def health_message({:unavailable, {:prepare_failed, _reason}}), do: "current-run membership is unavailable: recovery storage cannot be prepared"
  def health_message({:unavailable, {:journal_unreadable, _reason}}), do: "current-run membership is unavailable: journal cannot be read"
  def health_message({:unavailable, {:journal_prefix_checkpoint_failed, _reason}}), do: "current-run membership is unavailable: validated journal prefix cannot be checkpointed"
  def health_message({:unavailable, {:degraded_marker_failed, _reason}}), do: "current-run membership is unavailable: degraded recovery state cannot be recorded"
  def health_message({:unavailable, {:quarantine_failed, _reason}}), do: "current-run membership is unavailable: corrupt recovery data cannot be quarantined"
  def health_message({:unavailable, _reason}), do: "current-run membership is unavailable"

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
    with :ok <- state.checkpoint_fun.(state.checkpoint_path, Checkpoint.record(projection)),
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
        state = %{state | health: {:degraded, {:journal_compaction_failed, reason}}}
        notify(state, event)
        {:reply, {:ok, %{status: :accepted, generation: state.projection.generation}}, state}
    end
  end

  defp persist_failed(state, reason) do
    state = %{state | health: {:degraded, reason}}
    notify(state, nil)
    {:reply, {:error, {:membership_persistence_failed, reason}}, state}
  end

  defp snapshot_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_snapshot_limit)
  defp snapshot_limit(_limit), do: @max_snapshot_limit
  defp persisted_health({:degraded, {:cleanup_failed, _reason}} = health), do: health
  defp persisted_health(_health), do: :healthy

  @spec notify(map(), Event.t() | nil) :: :ok
  def notify(state, event) do
    CurrentRunMembership.broadcast_changed(state.run_id, state.projection.generation, event, state.health, freshness(state))
  rescue
    error -> Logger.warning("aiur_current_run_membership phase=notify_failed error=#{Exception.message(error)}")
  end
end
