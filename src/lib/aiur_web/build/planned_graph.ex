defmodule AiurWeb.Build.PlannedGraph do
  @moduledoc "Uncapped dependency levels and failure closures for planned queue rows."
  alias Aiur.BuildOrder.DependencyChain

  @spec build([{map(), map()}], [{map(), map()}]) :: map()
  def build(planned, live) do
    items = Map.new(planned, fn {item, _queue} -> {item.number, item} end)

    dependents =
      Enum.reduce(live, %{}, fn {item, _queue}, graph ->
        Enum.reduce(item.prerequisites, graph, fn edge, acc -> Map.update(acc, edge.number, [item.number], &[item.number | &1]) end)
      end)

    failed = failures(planned, dependents)
    blocked = failed |> Map.keys() |> Enum.flat_map(&DependencyChain.reachable(&1, dependents)) |> MapSet.new()
    waves = Enum.reduce(planned, %{}, fn {item, _queue}, memo -> elem(wave(item.number, items, memo, MapSet.new()), 1) end)
    %{waves: waves, failed: failed, blocked: blocked}
  end

  defp failures(planned, dependents) do
    Enum.reduce(planned, %{}, fn {item, _queue}, acc ->
      case Enum.find(item.prerequisites, &(&1.verdict == :failed)) do
        nil ->
          acc

        edge ->
          direct = dependents |> Map.fetch!(edge.number) |> Enum.uniq() |> Enum.sort()
          blocks = direct ++ (DependencyChain.reachable(edge.number, dependents) -- direct)
          Map.put(acc, item.number, %{by: edge.number, blocks: blocks})
      end
    end)
  end

  defp wave(number, items, memo, path) do
    cond do
      Map.has_key?(memo, number) ->
        {memo[number], memo}

      MapSet.member?(path, number) ->
        {1, memo}

      true ->
        path = MapSet.put(path, number)

        {level, memo} =
          Enum.reduce(items[number].prerequisites, {0, memo}, fn edge, {level, acc} ->
            {contribution, acc} = contribution(edge, items, acc, path)
            {max(level, contribution), acc}
          end)

        {level + 1, Map.put(memo, number, level + 1)}
    end
  end

  defp contribution(%{verdict: :satisfied}, _items, memo, _path), do: {0, memo}

  defp contribution(edge, items, memo, path) do
    if Map.has_key?(items, edge.number), do: wave(edge.number, items, memo, path), else: {1, memo}
  end
end
