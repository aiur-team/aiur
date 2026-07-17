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

  @spec write((String.t(), map() -> term()), map()) :: :ok
  def write(_fun, %{run_id: run_id}) when not is_binary(run_id), do: :ok

  def write(fun, state) do
    _ = fun.(state.run_id, dump(state))
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
