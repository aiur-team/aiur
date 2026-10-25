defmodule Aiur.BuildOrder.EpicOverrides.Batch do
  @moduledoc false
  alias Aiur.BuildOrder.EpicOverrides.Override

  @spec numbers(term()) :: {:ok, [pos_integer()]} | {:error, term()}
  def numbers(ids) when is_list(ids) and length(ids) > 200, do: {:error, {:too_many_ids, 200}}

  def numbers(ids) when is_list(ids) and ids != [] do
    ids |> Enum.reduce_while({:ok, []}, &parse/2) |> dedupe()
  end

  def numbers(_ids), do: {:error, :invalid_epic_arguments}

  defp parse(id, {:ok, acc}) do
    case Override.number(id) do
      {:ok, n} -> {:cont, {:ok, [n | acc]}}
      error -> {:halt, error}
    end
  end

  defp dedupe({:ok, ids}), do: {:ok, ids |> Enum.reverse() |> Enum.uniq()}
  defp dedupe(error), do: error

  @spec catalog((-> term())) :: {:ok, [map()]} | {:error, :epic_config_unavailable}
  def catalog(settings_fun) do
    case settings_fun.() do
      {:ok, %{build_order: %{general_epics: epics}}} when is_list(epics) -> {:ok, Enum.map(epics, &Map.take(&1, [:key, :label]))}
      _ -> {:error, :epic_config_unavailable}
    end
  rescue
    _ -> {:error, :epic_config_unavailable}
  catch
    _, _ -> {:error, :epic_config_unavailable}
  end

  @spec validate(String.t() | nil, term(), term(), (-> term())) :: {:ok, [pos_integer()]} | {:error, term()}
  def validate(epic, ids, provenance, settings_fun) do
    with {:ok, ids} <- numbers(ids), true <- Override.provenance?(provenance), {:ok, catalog} <- catalog(settings_fun), :ok <- epic(epic, catalog) do
      {:ok, ids}
    else
      false -> {:error, :invalid_epic_arguments}
      error -> error
    end
  end

  defp epic(nil, _catalog), do: :ok

  defp epic(epic, catalog) do
    known = Enum.map(catalog, & &1.key)
    if epic != "unsorted" and epic in known, do: :ok, else: {:error, {:unknown_epic, epic, known}}
  end

  @spec apply(map(), String.t(), String.t() | nil, [pos_integer()], map(), DateTime.t()) :: {map(), [map()], [pos_integer()]}
  def apply(state, op, epic, ids, provenance, at) do
    Enum.reduce(ids, {state, [], []}, fn n, {current, results, changed} ->
      previous = current.overrides[n]
      value = if op == "set", do: struct!(Override, Map.merge(provenance, %{number: n, epic: epic, confirmed: provenance.source != "backfill-agent", at: at, seq: current.generation + 1})), else: nil
      same = same?(previous, value)
      result = %{number: n, status: if(same, do: :unchanged, else: :changed), previous: previous}
      if same, do: {current, results ++ [result], changed}, else: {append(current, op, n, value, provenance, at), results ++ [result], changed ++ [n]}
    end)
  end

  defp same?(nil, nil), do: true
  defp same?(%Override{} = a, %Override{} = b), do: Map.take(a, [:epic, :source, :confirmed]) == Map.take(b, [:epic, :source, :confirmed])
  defp same?(_a, _b), do: false

  defp append(state, op, n, value, provenance, at) do
    seq = state.generation + 1
    entry = if op == "set", do: Override.to_entry(value), else: Map.merge(provenance, %{op: "clear", number: n, seq: seq, at: DateTime.to_iso8601(at)})
    overrides = if op == "set", do: Map.put(state.overrides, n, value), else: Map.delete(state.overrides, n)
    %{state | entries: state.entries ++ [entry], overrides: overrides, generation: seq}
  end
end
