defmodule Aiur.Experiments.Packs.DeliverySpeed.Tokens do
  @moduledoc false
  alias Aiur.UsageEnvelope.RelationshipRegistry

  @spec total(list(), map()) :: non_neg_integer() | nil
  def total(cells, catalog) do
    groups =
      cells
      |> Enum.filter(fn {{_dims, measure}, _value} -> match?({:token, _}, measure) end)
      |> Enum.group_by(fn {{dims, _measure}, _value} -> dims end)

    counts = Enum.map(groups, fn {dims, entries} -> group_total(dims, entries, catalog) end)
    if counts != [] and Enum.all?(counts, &is_integer/1), do: Enum.sum(counts)
  end

  defp group_total(dims, entries, catalog) do
    tokens = Map.new(entries, fn {{_dims, {:token, dimension}}, value} -> {dimension, value} end) |> Map.delete(:provider_reported_total)

    with true <- map_size(tokens) > 0,
         {:ok, edges} <- RelationshipRegistry.subset_children(catalog, dims.provider, dims.relationship_revision),
         true <- Enum.all?(edges, fn {parent, children} -> Map.get(tokens, parent, 0) >= Enum.sum(Enum.map(children, &Map.get(tokens, &1, 0))) end) do
      children = Enum.flat_map(edges, &elem(&1, 1))
      tokens |> Map.drop(children) |> Map.values() |> Enum.sum()
    else
      _unknown -> nil
    end
  end
end
