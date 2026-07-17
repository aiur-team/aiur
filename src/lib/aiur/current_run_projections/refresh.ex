defmodule Aiur.CurrentRunProjections.Refresh do
  @moduledoc false

  alias Aiur.CurrentRunProjections.{CheckpointPersistence, Projector, SourceCollector}

  @type mode :: :full | :clock

  @spec start(map(), mode(), [GenServer.from()], pid()) :: map()
  def start(state, mode, waiters \\ [], owner \\ self()) do
    refresh =
      SourceCollector.start(owner, state.readers,
        mode: mode,
        task_supervisor: state.task_supervisor,
        timeout_ms: state.source_timeout_ms,
        waiters: waiters,
        base_summary: state.summary_snapshot,
        base_outcomes: state.outcome_snapshot
      )

    summary = SourceCollector.mark_refreshing(state.summary_snapshot)
    outcomes = refreshing_outcomes(state, mode)
    %{state | refresh: refresh, summary_snapshot: summary, outcome_snapshot: outcomes}
  end

  @spec finish(map(), pid()) :: map()
  def finish(%{refresh: refresh} = state, owner \\ self()) do
    SourceCollector.finish(refresh)

    case project(state, refresh) do
      {:persist, candidate, race_signature, force_full?, changes} ->
        CheckpointPersistence.start(
          state,
          candidate,
          [
            changes: changes,
            race_signature: race_signature,
            force_full?: force_full?,
            waiters: refresh.waiters
          ],
          owner
        )

      {:complete, projected, race_signature, force_full?} ->
        SourceCollector.reply_waiters(refresh)

        projected
        |> Map.put(:refresh, nil)
        |> maybe_retry_race(race_signature)
        |> maybe_force_full(force_full?)
        |> continue(owner)
    end
  end

  @spec finish_checkpoint(map(), reference(), pos_integer(), term(), pid()) :: map()
  def finish_checkpoint(state, ref, generation, result, owner \\ self()) do
    case CheckpointPersistence.finish(state, ref, generation, result) do
      :stale -> state
      completion -> complete_checkpoint(completion, owner)
    end
  end

  @spec expire_checkpoint(map(), reference(), pos_integer(), pid()) :: map()
  def expire_checkpoint(state, ref, generation, owner \\ self()) do
    case CheckpointPersistence.expire(state, ref, generation) do
      :stale -> state
      completion -> complete_checkpoint(completion, owner)
    end
  end

  @spec request_full(map(), pid()) :: map()
  def request_full(state, owner \\ self())

  def request_full(%{checkpoint_write: write} = state, _owner) when is_map(write),
    do: %{state | refresh_again?: true}

  def request_full(%{refresh: nil} = state, owner) do
    state |> Map.put(:refresh_pending?, false) |> start(:full, [], owner)
  end

  def request_full(state, _owner), do: %{state | refresh_again?: true}

  @spec schedule(map(), pid()) :: map()
  def schedule(state, owner \\ self())

  def schedule(%{refresh: refresh} = state, _owner) when is_map(refresh),
    do: %{state | refresh_again?: true}

  def schedule(%{checkpoint_write: write} = state, _owner) when is_map(write),
    do: %{state | refresh_again?: true}

  def schedule(%{refresh_pending?: true} = state, _owner), do: state

  def schedule(state, owner) do
    send(owner, :refresh_sources)
    %{state | refresh_pending?: true}
  end

  defp refreshing_outcomes(state, :full),
    do: SourceCollector.mark_refreshing(state.outcome_snapshot)

  defp refreshing_outcomes(state, :clock), do: state.outcome_snapshot

  defp project(state, %{mode: :full} = refresh) do
    {projected, race_signature, changes} = Projector.full(state, refresh.results)

    if changes.persist? do
      {:persist, projected, race_signature, false, changes}
    else
      {:complete, projected, race_signature, false}
    end
  end

  defp project(state, %{mode: :clock} = refresh) do
    {projected, force_full?, changes} = Projector.clock(state, refresh.results)

    if changes.persist? do
      {:persist, projected, nil, force_full?, changes}
    else
      {:complete, projected, nil, force_full?}
    end
  end

  defp complete_checkpoint({:ok, state, write, result}, owner) do
    next =
      case result do
        :ok -> Projector.commit(state, write.candidate, write.changes)
        _error -> Projector.checkpoint_failed(state)
      end

    SourceCollector.reply_waiters(write.waiters)

    next
    |> maybe_retry_race(write.race_signature)
    |> maybe_force_full(write.force_full?)
    |> continue(owner)
  end

  defp maybe_retry_race(state, signature) do
    cond do
      is_nil(signature) -> %{state | last_race_signature: nil}
      state.last_race_signature == signature -> state
      true -> %{state | last_race_signature: signature, refresh_again?: true}
    end
  end

  defp maybe_force_full(state, true), do: %{state | refresh_again?: true}
  defp maybe_force_full(state, false), do: state

  defp continue(state, owner) do
    if state.refresh_again? or state.queued_waiters != [] do
      waiters = state.queued_waiters

      state
      |> Map.merge(%{refresh_again?: false, queued_waiters: [], refresh_pending?: false})
      |> start(:full, waiters, owner)
    else
      state
    end
  end
end
