defmodule AiurWeb.Build.SnapshotRows do
  @moduledoc false
  alias AiurWeb.Build.PayloadValidator

  @sections ~w(hist now plan nq)

  @spec retain_valid(map()) :: {map(), [{String.t(), non_neg_integer(), term(), [String.t()]}]}
  def retain_valid(message) when is_map(message) do
    sections = message["sections"]

    if is_map(sections) do
      {kept, dropped} =
        Enum.reduce(@sections, {%{}, []}, fn section, {kept, dropped} ->
          {rows, invalid} = retain_section(section, sections[section], message)
          {Map.put(kept, section, rows), invalid ++ dropped}
        end)

      dropped_ids = dropped |> Enum.map(&elem(&1, 2)) |> Enum.reject(&is_nil/1) |> MapSet.new()
      rows = Map.new(kept, fn {section, section_rows} -> {section, sanitize_rows(section_rows, dropped_ids)} end)
      {Map.put(message, "sections", Map.merge(sections, rows)) |> Map.put("unavailable_rows", length(dropped)), dropped}
    else
      {message, []}
    end
  end

  def retain_valid(message), do: {message, []}

  @spec scrub_changes(map(), MapSet.t()) :: {map(), MapSet.t()}
  def scrub_changes(changes, dropped_ids) when is_map(changes) do
    recovered =
      changes
      |> Map.get("upsert", [])
      |> Enum.filter(fn row ->
        is_map(row) and MapSet.member?(dropped_ids, row["id"]) and PayloadValidator.validate_row(row, row["sec"]) == :ok
      end)
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    dropped_ids = MapSet.difference(dropped_ids, recovered)

    changes =
      changes
      |> Map.update("upsert", [], fn rows -> sanitize_rows(rows, dropped_ids) end)
      |> Map.update("remove", [], &reject_ids(&1, dropped_ids))

    {changes, dropped_ids}
  end

  defp retain_section(section, rows, message) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {row, index}, acc -> retain_row(row, section, index, message, acc) end)
    |> then(fn {valid, dropped} -> {Enum.reverse(valid), dropped} end)
  end

  defp retain_section(_section, rows, _message), do: {rows, []}

  defp retain_row(row, section, index, message, {valid, dropped}) do
    case PayloadValidator.validate_row(row, section, message["epics"], message["features"]) do
      :ok ->
        {[row | valid], dropped}

      {:error, paths} ->
        paths = Enum.map(paths, &elem(&1, 0))
        {valid, [{section, index, row_id(row), paths} | dropped]}
    end
  end

  defp sanitize_rows(rows, dropped_ids) when is_list(rows) do
    Enum.map(rows, fn row ->
      if is_map(row) do
        row
        |> Map.update("deps", [], &reject_ids(&1, dropped_ids))
        |> Map.update("children", [], &reject_ids(&1, dropped_ids))
        |> Map.update("dep_states", %{}, &reject_keys(&1, dropped_ids))
      else
        row
      end
    end)
  end

  defp sanitize_rows(rows, _dropped_ids), do: rows
  defp reject_ids(ids, dropped_ids) when is_list(ids), do: Enum.reject(ids, &MapSet.member?(dropped_ids, &1))
  defp reject_ids(ids, _dropped_ids), do: ids
  defp reject_keys(states, dropped_ids) when is_map(states), do: Map.drop(states, MapSet.to_list(dropped_ids))
  defp reject_keys(states, _dropped_ids), do: states
  defp row_id(row), do: if(is_map(row), do: Map.get(row, "id"), else: nil)
end
