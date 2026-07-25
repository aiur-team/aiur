defmodule Aiur.CurrentRunProjections.Finalizer do
  @moduledoc false

  @spec summary(map(), map(), term(), String.t()) :: map()
  def summary(state, raw, run_id, denominator_signature) do
    changed? = summary_semantic(state.summary_snapshot) != summary_semantic(raw)
    generation = next_generation(state.summary_generation, changed?)
    current = raw |> Map.put(:generation, generation) |> Map.put(:last_known_good, nil)
    key = {run_id, denominator_signature}
    previous_lkg = same_lkg(state.summary_lkg, key)
    {snapshot, lkg} = attach_lkg(current, previous_lkg, key, &good_summary?/1)

    %{snapshot: snapshot, generation: generation, lkg: lkg, changed?: changed?}
  end

  @spec outcomes(map(), map(), term(), term(), String.t()) :: map()
  def outcomes(state, raw, run_id, membership_generation, membership_signature) do
    changed? = outcome_semantic(state.outcome_snapshot) != outcome_semantic(raw)
    generation = next_generation(state.outcome_generation, changed?)
    current = raw |> Map.put(:generation, generation) |> Map.put(:last_known_good, nil)
    key = {run_id, membership_generation, membership_signature, raw.repository}
    previous_lkg = same_lkg(state.outcome_lkg, key)
    {snapshot, lkg} = attach_lkg(current, previous_lkg, key, &good_outcomes?/1)

    %{snapshot: snapshot, generation: generation, lkg: lkg, changed?: changed?}
  end

  defp attach_lkg(current, previous_lkg, key, good?) do
    if good?.(current) do
      {current, new_lkg(key, current)}
    else
      {Map.put(current, :last_known_good, public_lkg(previous_lkg)), previous_lkg}
    end
  end

  defp next_generation(generation, true), do: generation + 1
  defp next_generation(generation, false), do: generation

  defp summary_semantic(snapshot) when is_map(snapshot) do
    snapshot
    |> Map.drop([:generation, :last_known_good])
    |> drop_refreshing()
  end

  defp summary_semantic(_snapshot), do: nil

  defp outcome_semantic(snapshot) when is_map(snapshot) do
    snapshot
    |> Map.drop([:generation, :last_known_good])
    |> drop_refreshing()
    |> Map.update(:run, %{}, &Map.delete(&1, :observed_at))
    |> Map.update(:outcomes, [], fn outcomes ->
      Enum.map(outcomes, &Map.update(&1, :run, %{}, fn run -> Map.delete(run, :observed_at) end))
    end)
  end

  defp outcome_semantic(_snapshot), do: nil

  defp drop_refreshing(snapshot) do
    snapshot
    |> Map.update(:freshness, %{}, &Map.delete(&1, :refreshing?))
    |> Map.update(:sources, %{}, &Map.delete(&1, :refreshing?))
    |> Map.update(:health, %{}, fn health ->
      Map.update(health, :reasons, [], &List.delete(&1, :source_refresh_in_progress))
    end)
  end

  defp good_summary?(snapshot) do
    snapshot.health.status == :healthy and snapshot.freshness.status == :fresh and
      not is_nil(snapshot.progress.exact)
  end

  defp good_outcomes?(snapshot) do
    snapshot.state in [:healthy, :healthy_empty] and snapshot.completeness == :complete and
      snapshot.truncated? == false and snapshot.freshness.status == :fresh
  end

  defp new_lkg(key, snapshot) do
    %{
      key: key,
      snapshot: Map.put(snapshot, :last_known_good, nil),
      observed_at: get_in(snapshot, [:run, :observed_at])
    }
  end

  defp same_lkg(%{key: key} = lkg, key), do: lkg
  defp same_lkg(_lkg, _key), do: nil
  defp public_lkg(nil), do: nil

  defp public_lkg(lkg) do
    %{observed_at: lkg.observed_at, generation: lkg.snapshot.generation, snapshot: lkg.snapshot}
  end
end
