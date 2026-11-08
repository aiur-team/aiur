defmodule Aiur.BuildOrder.EpicOverrides.Confirmation do
  @moduledoc false
  alias Aiur.BuildOrder.EpicOverrides.{Batch, Override}

  @spec prepare(map(), list(), map(), String.t() | nil) :: {:ok, [pos_integer()]} | {:error, term()}
  def prepare(state, ids, provenance, expect) do
    with {:ok, ids} <- Batch.numbers(if(is_list(ids), do: Enum.uniq(ids), else: ids)),
         true <- Override.provenance?(provenance) and provenance.source != "backfill-agent",
         {:ok, catalog} <- Batch.catalog(state.settings_fun) do
      keys = Enum.map(catalog, & &1.key)
      failures = Enum.flat_map(ids, &refusals(&1, state.overrides[&1], keys, expect))
      if failures == [], do: {:ok, ids}, else: {:error, {:confirm_refused, failures}}
    else
      false -> {:error, :invalid_epic_arguments}
      error -> error
    end
  end

  defp refusals(n, nil, _keys, _expect), do: [{:no_override, n}]

  defp refusals(n, override, keys, expect) do
    unknown = if override.epic in keys, do: [], else: [{:not_a_configured_epic, n, override.epic}]
    changed = if is_nil(expect) or expect == override.epic, do: [], else: [{:epic_changed, n, override.epic}]
    unknown ++ changed
  end

  @spec apply(map(), [pos_integer()], map(), DateTime.t()) :: {map(), [map()], [pos_integer()]}
  def apply(state, ids, provenance, at) do
    Enum.reduce(ids, {state, [], []}, fn n, {current, results, changed} ->
      previous = current.overrides[n]

      if previous.confirmed do
        {current, results ++ [%{number: n, status: :unchanged, epic: previous.epic, previous: previous}], changed}
      else
        {next, [result], [^n]} = Batch.apply(current, "set", previous.epic, [n], provenance, at)
        {next, results ++ [Map.put(result, :epic, previous.epic)], changed ++ [n]}
      end
    end)
  end
end
