defmodule Aiur.CurrentRunProjections.Checkpoint do
  @moduledoc false

  @fields [
    :run_id,
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

  @spec restore(map(), term()) :: map()
  def restore(state, %{run_id: run_id, checkpoint: checkpoint})
      when is_binary(run_id) and is_map(checkpoint) do
    if Map.get(checkpoint, :run_id) == run_id do
      Map.merge(state, Map.take(checkpoint, @fields))
    else
      state
    end
  end

  def restore(state, _checkpoint), do: state

  @spec dump(map()) :: map()
  def dump(state), do: Map.take(state, @fields)

  @spec read((-> term())) :: term()
  def read(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  @spec write((String.t(), map() -> term()), map()) :: :ok | {:error, :checkpoint_write_failed}
  def write(_fun, %{run_id: run_id}) when not is_binary(run_id), do: :ok

  def write(fun, state) do
    case fun.(state.run_id, dump(state)) do
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
end
