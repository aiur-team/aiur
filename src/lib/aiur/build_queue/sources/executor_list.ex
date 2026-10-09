defmodule Aiur.BuildQueue.Sources.ExecutorList do
  @moduledoc "Ordered membership and explicit edges from the local queue store."
  @behaviour Aiur.BuildQueue.Source

  @impl true
  def members(%{kind: :list, id: id}, %{items: items, edges: edges}) do
    items = items |> Enum.filter(&(&1.queue_id == id)) |> Enum.sort_by(& &1.position)
    ids = MapSet.new(items, & &1.issue_id)
    edges = Enum.filter(edges, &(&1.source == :list and MapSet.member?(ids, &1.dependent)))
    {:ok, items, edges, :current}
  end

  def members(_, _), do: {:unavailable, :not_list}
end
