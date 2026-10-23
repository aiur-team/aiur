defmodule Aiur.BuildOrder.Index.PackRows do
  @moduledoc false
  alias Aiur.BuildOrder.Index

  @spec read(term(), map(), map()) :: term()
  def read(reader, all, epics) when is_function(reader, 1),
    do: Index.safe_read(:packs, fn -> reader.(%{all: all, epics: epics}) end)

  def read(part, _all, _epics), do: part

  @spec merge(map(), term()) :: map()
  def merge(all, %{rows: rows, aliases: aliases}) do
    all = Map.new(all, fn {id, row} -> {id, Map.put(row, :was, Map.get(aliases, row.num))} end)
    all = Enum.reduce(rows, all, &Map.put(&2, &1.id, %{&1 | epic: &1.epic || "unsorted"}))

    Enum.reduce(rows, all, &append_children/2)
  end

  def merge(all, _packs), do: all
  defp append_children(row, all), do: Enum.reduce(row.deps, all, &append_child(&2, &1, row.id))

  defp append_child(all, dependency, id) do
    case all[dependency] do
      nil -> all
      row -> Map.put(all, dependency, %{row | children: Enum.uniq(row.children ++ [id])})
    end
  end
end
