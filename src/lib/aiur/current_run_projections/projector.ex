defmodule Aiur.CurrentRunProjections.Projector do
  @moduledoc false

  alias Aiur.{CurrentRunOutcomeSnapshot, CurrentRunSummary}
  alias Aiur.CurrentRunProjections.{Checkpoint, Finalizer, MembershipCache, SourceFallback, UnitsBuilder}

  @spec full(map(), map()) :: {map(), term()}
  def full(state, results) do
    {sources, availability} = SourceFallback.resolve(results, state.sources)
    run_id = get_in(sources, [:run, :id])
    retained = if state.run_id == run_id, do: state.weight_facts, else: %{}

    built =
      UnitsBuilder.build(
        sources,
        availability,
        retained,
        sources.membership,
        state.units_snapshot_fun
      )

    denominator_signature =
      CurrentRunSummary.Projection.denominator_signature(Map.get(built.units, :rows, []))

    denominator_generation =
      next_denominator_generation(
        state.run_id,
        run_id,
        state.denominator_signature,
        denominator_signature,
        state.denominator_generation
      )

    membership_generation = Map.get(sources.membership, :generation)
    members = Map.get(sources.membership, :members, [])

    membership_index =
      MembershipCache.get(state, run_id, membership_generation, members)

    membership_signature = membership_index.signature

    summary_raw =
      CurrentRunSummary.Projection.snapshot(%{
        run: sources.run,
        units: built.units,
        generation: 0,
        denominator_generation: denominator_generation,
        weight_health: built.weight_health
      })

    outcome_raw =
      CurrentRunOutcomeSnapshot.Projection.snapshot(%{
        run: summary_raw.run,
        membership: sources.membership,
        recent_merges: sources.merges,
        configured_repository: sources.configured_repository,
        membership_index: membership_index,
        generation: 0
      })

    canonical = canonical_state(state)
    summary = Finalizer.summary(canonical, summary_raw, run_id, denominator_signature)

    outcomes =
      Finalizer.outcomes(
        canonical,
        outcome_raw,
        run_id,
        membership_generation,
        membership_signature
      )

    candidate = %{
      state
      | sources: sources,
        availability: availability,
        units: built.units,
        weight_facts: built.weight_facts,
        weight_health: built.weight_health,
        run_id: run_id,
        denominator_signature: denominator_signature,
        denominator_generation: denominator_generation,
        membership_signature: membership_signature,
        membership_generation: membership_generation,
        membership_index: membership_index,
        summary_generation: summary.generation,
        outcome_generation: outcomes.generation,
        summary_snapshot: summary.snapshot,
        outcome_snapshot: outcomes.snapshot,
        summary_lkg: summary.lkg,
        outcome_lkg: outcomes.lkg
    }

    case Checkpoint.write(candidate.checkpoint_writer, candidate) do
      :ok ->
        next = %{candidate | checkpoint_health: :healthy}
        broadcast_changes(next, summary, outcomes)
        {next, built.race_signature}

      {:error, :checkpoint_write_failed} ->
        failed = Checkpoint.fail(canonical)
        broadcast_checkpoint_failure(canonical, failed)
        {failed, built.race_signature}
    end
  end

  @spec clock(map(), map()) :: {map(), boolean()}
  def clock(%{checkpoint_health: health} = state, _results) when health != :healthy do
    {restore_canonical(state), false}
  end

  def clock(state, results) do
    {clock_sources, clock_availability} = SourceFallback.resolve(results, state.sources)
    run = Map.fetch!(clock_sources, :run)
    run_id = Map.get(run, :id)

    if is_binary(state.run_id) and is_binary(run_id) and state.run_id != run_id do
      {restore_canonical(state), true}
    else
      sources = Map.put(state.sources, :run, run)
      availability = Map.put(state.availability, :run, Map.fetch!(clock_availability, :run))

      raw =
        CurrentRunSummary.Projection.snapshot(%{
          run: run,
          units: state.units,
          generation: 0,
          denominator_generation: state.denominator_generation,
          weight_health: state.weight_health
        })

      summary =
        Finalizer.summary(
          canonical_state(state),
          raw,
          run_id,
          state.denominator_signature
        )

      canonical = canonical_state(state)

      candidate = %{
        state
        | sources: sources,
          availability: availability,
          run_id: run_id,
          summary_generation: summary.generation,
          summary_snapshot: summary.snapshot,
          summary_lkg: summary.lkg
      }

      case Checkpoint.write(candidate.checkpoint_writer, candidate) do
        :ok ->
          next = %{candidate | checkpoint_health: :healthy}
          broadcast_summary_change(next, summary)
          {next, false}

        {:error, :checkpoint_write_failed} ->
          failed = Checkpoint.fail(canonical)
          broadcast_checkpoint_failure(canonical, failed)
          {failed, false}
      end
    end
  end

  defp canonical_state(%{refresh: %{base_summary: summary, base_outcomes: outcomes}} = state) do
    %{state | summary_snapshot: summary, outcome_snapshot: outcomes}
  end

  defp canonical_state(state), do: state

  defp restore_canonical(%{refresh: %{base_summary: summary, base_outcomes: outcomes}} = state) do
    %{state | summary_snapshot: summary, outcome_snapshot: outcomes}
  end

  defp restore_canonical(state), do: state

  defp next_denominator_generation(previous_run, run, _previous, _current, _generation)
       when previous_run != run,
       do: 1

  defp next_denominator_generation(run, run, nil, _signature, _generation), do: 1

  defp next_denominator_generation(run, run, signature, signature, generation),
    do: generation

  defp next_denominator_generation(run, run, _previous, _current, generation),
    do: generation + 1

  defp broadcast_changes(state, summary, outcomes) do
    if summary.changed? do
      broadcast(
        state.pubsub,
        CurrentRunSummary.topic(),
        {:current_run_summary_changed, summary.snapshot}
      )
    end

    if outcomes.changed? do
      broadcast(
        state.pubsub,
        CurrentRunOutcomeSnapshot.topic(),
        {:current_run_outcome_snapshot_changed, outcomes.snapshot}
      )
    end
  end

  defp broadcast_summary_change(state, summary) do
    if summary.changed? do
      broadcast(
        state.pubsub,
        CurrentRunSummary.topic(),
        {:current_run_summary_changed, summary.snapshot}
      )
    end
  end

  defp broadcast_checkpoint_failure(previous, failed) do
    if previous.summary_snapshot != failed.summary_snapshot do
      broadcast(
        failed.pubsub,
        CurrentRunSummary.topic(),
        {:current_run_summary_changed, failed.summary_snapshot}
      )
    end

    if previous.outcome_snapshot != failed.outcome_snapshot do
      broadcast(
        failed.pubsub,
        CurrentRunOutcomeSnapshot.topic(),
        {:current_run_outcome_snapshot_changed, failed.outcome_snapshot}
      )
    end
  end

  defp broadcast(pubsub, topic, message) do
    if is_atom(pubsub) and is_pid(Process.whereis(pubsub)) do
      Phoenix.PubSub.broadcast(pubsub, topic, message)
    end

    :ok
  end
end
