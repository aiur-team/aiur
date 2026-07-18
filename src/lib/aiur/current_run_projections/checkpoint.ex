defmodule Aiur.CurrentRunProjections.Checkpoint do
  @moduledoc false

  @fields [
    :checkpoint_generation,
    :run_id,
    :sources,
    :availability,
    :units,
    :weight_health,
    :denominator_signature,
    :denominator_generation,
    :membership_signature,
    :membership_generation,
    :summary_generation,
    :outcome_generation,
    :summary_snapshot,
    :outcome_snapshot,
    :summary_lkg,
    :outcome_lkg,
    :weight_facts
  ]
  @canonical_fields [:membership_index, :restore_fence_pending? | @fields]
  @max_fallback_entries 1_000

  @spec restore(map(), term()) :: map()
  def restore(state, %{run_id: run_id, checkpoint: checkpoint})
      when is_binary(run_id) and is_map(checkpoint) do
    if Map.get(checkpoint, :run_id) == run_id do
      state
      |> Map.merge(Map.take(checkpoint, @fields))
      |> Map.put(:restore_fence_pending?, not fallback_ready?(checkpoint, run_id))
    else
      state
    end
  end

  def restore(state, _checkpoint), do: state

  @spec dump(map()) :: map()
  def dump(state) do
    state
    |> Map.take(@fields)
    |> Map.update(:sources, %{}, &bounded_sources/1)
    |> Map.update(:units, %{}, &bounded_units/1)
    |> Map.update(:weight_facts, %{}, &bounded_map/1)
  end

  @spec candidate(map(), pos_integer()) :: map()
  def candidate(state, generation) do
    state
    |> Map.put(:checkpoint_generation, generation)
    |> Map.take(@canonical_fields)
  end

  @spec adopt(map(), map()) :: map()
  def adopt(state, candidate), do: Map.merge(state, Map.take(candidate, @canonical_fields))

  @spec read((-> term())) :: term()
  def read(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  @spec write((String.t(), map() -> term()), term(), map()) ::
          :ok | {:error, :checkpoint_write_failed}
  def write(_fun, run_id, _checkpoint) when not is_binary(run_id), do: :ok

  def write(fun, run_id, checkpoint) do
    case fun.(run_id, checkpoint) do
      :ok -> :ok
      _result -> {:error, :checkpoint_write_failed}
    end
  rescue
    _error -> {:error, :checkpoint_write_failed}
  catch
    _kind, _reason -> {:error, :checkpoint_write_failed}
  end

  @spec fail(map()) :: map()
  def fail(state) do
    %{
      state
      | checkpoint_health: {:unavailable, :write_failed},
        summary_snapshot: mark_summary_failed(state.summary_snapshot, state.summary_lkg),
        outcome_snapshot: mark_outcomes_failed(state.outcome_snapshot, state.outcome_lkg)
    }
  end

  defp mark_summary_failed(snapshot, lkg) do
    snapshot
    |> mark_health_failed()
    |> mark_freshness_failed()
    |> mark_sources_failed()
    |> Map.put(:last_known_good, public_lkg(lkg))
  end

  defp mark_outcomes_failed(snapshot, lkg) do
    snapshot
    |> mark_health_failed()
    |> mark_freshness_failed()
    |> mark_sources_failed()
    |> mark_outcome_state_failed()
    |> Map.put(:last_known_good, public_lkg(lkg))
  end

  defp mark_health_failed(snapshot) do
    Map.update(snapshot, :health, failed_health(), fn health ->
      status = if Map.get(health, :status) == :unavailable, do: :unavailable, else: :partial
      reasons = Enum.uniq(List.wrap(Map.get(health, :reasons)) ++ [:projection_checkpoint_unavailable])
      %{health | status: status, reasons: reasons}
    end)
  end

  defp mark_freshness_failed(snapshot) do
    Map.update(snapshot, :freshness, %{status: :stale}, &Map.put(&1, :status, :stale))
  end

  defp mark_sources_failed(snapshot) do
    Map.update(snapshot, :sources, %{checkpoint_health: :unavailable}, fn sources ->
      Map.put(sources, :checkpoint_health, :unavailable)
    end)
  end

  defp mark_outcome_state_failed(%{state: state} = snapshot)
       when state in [:healthy, :healthy_empty] do
    snapshot |> Map.put(:state, :stale) |> Map.put(:completeness, :partial)
  end

  defp mark_outcome_state_failed(snapshot), do: snapshot

  defp failed_health do
    %{status: :partial, reasons: [:projection_checkpoint_unavailable]}
  end

  defp public_lkg(nil), do: nil

  defp public_lkg(lkg) do
    %{observed_at: lkg.observed_at, generation: lkg.snapshot.generation, snapshot: lkg.snapshot}
  end

  defp fallback_ready?(checkpoint, run_id) do
    with %{sources: %{run: run, membership: membership}, units: units} <- checkpoint,
         true <- Map.has_key?(checkpoint, :weight_health),
         true <- is_map(run) and Map.get(run, :id) == run_id,
         true <- is_map(membership) and Map.get(membership, :run_id) == run_id,
         true <- is_list(Map.get(membership, :members)),
         true <- is_map(units) and is_list(Map.get(units, :rows)) do
      true
    else
      _missing_or_invalid -> false
    end
  end

  defp bounded_sources(sources) when is_map(sources) do
    sources
    |> Map.update(:membership, %{}, &bounded_membership/1)
    |> Map.update(:status, %{}, &bounded_status/1)
    |> Map.update(:status_facts, [], &bounded_list/1)
    |> Map.update(:activity, %{}, &bounded_entries/1)
    |> Map.update(:merges, %{}, &bounded_merges/1)
  end

  defp bounded_sources(_sources), do: %{}

  defp bounded_membership(membership) when is_map(membership) do
    members = membership |> Map.get(:members, []) |> List.wrap()

    membership
    |> Map.put(:members, Enum.take(members, @max_fallback_entries))
    |> Map.update(:truncated?, length(members) > @max_fallback_entries, fn truncated? ->
      truncated? == true or length(members) > @max_fallback_entries
    end)
  end

  defp bounded_membership(_membership), do: %{}

  defp bounded_status(status) when is_map(status) do
    Enum.reduce([:running, :retrying, :idle], status, fn key, current ->
      Map.update(current, key, [], &bounded_list/1)
    end)
  end

  defp bounded_status(_status), do: %{}
  defp bounded_entries(activity) when is_map(activity), do: Map.update(activity, :entries, [], &bounded_list/1)
  defp bounded_entries(_activity), do: %{}
  defp bounded_merges(merges) when is_map(merges), do: Map.update(merges, :merges, [], &bounded_list/1)
  defp bounded_merges(_merges), do: %{}
  defp bounded_units(units) when is_map(units), do: Map.update(units, :rows, [], &bounded_list/1)
  defp bounded_units(_units), do: %{}
  defp bounded_list(values), do: values |> List.wrap() |> Enum.take(@max_fallback_entries)

  defp bounded_map(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _fact} -> inspect(key) end)
    |> Enum.take(@max_fallback_entries)
    |> Map.new()
  end

  defp bounded_map(_value), do: %{}
end
