defmodule Aiur.GitHub.CIPollBatchTerminal do
  @moduledoc false

  @spec open?(map()) :: boolean()
  def open?(node), do: node |> Map.get("state") |> to_string() |> String.downcase() == "open"

  @spec select([map()]) :: {:open, map()} | {:terminal, map()} | :incomplete | :none
  def select(connections) do
    nodes = Enum.flat_map(connections, &Map.get(&1, "nodes", []))

    case Enum.find(nodes, &open?/1) do
      nil ->
        terminal_or_incomplete(nodes, connections)

      node ->
        {:open, node}
    end
  end

  defp terminal_or_incomplete(nodes, connections) do
    cond do
      Enum.any?(connections, &(get_in(&1, ["pageInfo", "hasNextPage"]) == true)) ->
        :incomplete

      node = List.first(nodes) ->
        {:terminal, node}

      true ->
        :none
    end
  end
end
