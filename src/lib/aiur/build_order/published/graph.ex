defmodule Aiur.BuildOrder.Published.Graph do
  @moduledoc """
  Waves and the critical path for `build-order.v1`.

  Both reuse `Aiur.BuildOrder.GraphAnalysis`: the published document cannot
  disagree with the dashboard about what blocks what. A dependency cycle stays
  bounded at wave one, and a ticket outside the analysed node bound keeps the
  default wave rather than disappearing from the document.
  """

  alias Aiur.BuildOrder.GraphAnalysis

  @type edge :: {String.t(), String.t()}
  @type ticket :: map()

  @spec waves([String.t()], [edge()], [ticket()]) :: [map()]
  def waves(ticket_ids, edges, tickets) do
    %GraphAnalysis{topological_order: order, reverse_adjacency: reverse} = GraphAnalysis.analyze(ticket_ids, edges)

    depths =
      Enum.reduce(order, %{}, fn id, depths ->
        depth = 1 + max_depth(Map.get(reverse, id, []), depths)
        Map.put(depths, id, depth)
      end)

    ticket_ids
    |> Enum.group_by(fn id -> Map.get(depths, id, 1) end)
    |> Enum.sort_by(fn {index, _ids} -> index end)
    |> Enum.map(fn {index, ids} -> wave_record(index, Enum.sort(ids), tickets) end)
  end

  @spec critical_path([String.t()], [edge()], [ticket()], keyword()) :: map()
  def critical_path(ticket_ids, edges, tickets, opts \\ []) do
    if Keyword.get(opts, :available?, true) do
      %GraphAnalysis{topological_order: order, reverse_adjacency: reverse} = GraphAnalysis.analyze(ticket_ids, edges)
      weights = Map.new(tickets, fn ticket -> {ticket["id"], ticket["estimate_hours"]} end)

      {paths, _totals} =
        Enum.reduce(order, {%{}, %{}}, fn id, {paths, totals} ->
          {blocker_path, blocker_hours} = best_predecessor(Map.get(reverse, id, []), paths, totals)
          path = blocker_path ++ [id]
          hours = blocker_hours + weight(weights, id)
          {Map.put(paths, id, {path, hours}), Map.put(totals, id, hours)}
        end)

      {best_path, hours} =
        paths
        |> Map.values()
        |> Enum.max_by(fn {path, hours} -> {hours, length(path)} end, fn -> {[], 0} end)

      known? = best_path != [] and Enum.all?(best_path, &is_number(Map.get(weights, &1)))

      %{
        "status" => "known",
        "tickets" => best_path,
        "hours" => if(known?, do: hours, else: nil),
        "reason" => nil
      }
    else
      # An unreadable projection publishes no path and no hour claim: a reader
      # must not render a partial chain as a known critical path.
      %{
        "status" => "unknown",
        "tickets" => [],
        "hours" => nil,
        "reason" => Keyword.get(opts, :reason)
      }
    end
  end

  defp best_predecessor(blockers, paths, totals) do
    blockers
    |> Enum.sort()
    |> Enum.reduce({[], 0}, fn blocker, best ->
      candidate = Map.get(paths, blocker, {[], Map.get(totals, blocker, 0)})
      if elem(candidate, 1) > elem(best, 1), do: candidate, else: best
    end)
  end

  defp weight(weights, id) do
    case Map.get(weights, id) do
      value when is_number(value) -> value
      _unknown -> 0
    end
  end

  defp max_depth(predecessors, depths),
    do: predecessors |> Enum.map(&Map.get(depths, &1, 0)) |> Enum.max(fn -> 0 end)

  defp wave_record(index, ids, tickets) do
    starts = ids |> Enum.map(&fact(&1, tickets, "started_at")) |> Enum.reject(&is_nil/1)
    ends = ids |> Enum.map(&fact(&1, tickets, "ended_at"))

    %{
      "index" => index,
      "tickets" => ids,
      "starts_at" => min_or_nil(starts),
      "ends_at" => if(Enum.all?(ends, &is_binary/1), do: max_or_nil(ends), else: nil)
    }
  end

  defp fact(id, tickets, field) do
    case Enum.find(tickets, &(&1["id"] == id)) do
      nil -> nil
      ticket -> ticket[field]
    end
  end

  defp min_or_nil([]), do: nil
  defp min_or_nil(values), do: Enum.min(values)

  defp max_or_nil([]), do: nil
  defp max_or_nil(values), do: Enum.max(values)
end
