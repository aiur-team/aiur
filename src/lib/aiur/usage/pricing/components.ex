defmodule Aiur.Usage.Pricing.Components do
  @moduledoc false

  @dimensions [:input, :cached_input, :cache_creation_input, :output, :reasoning_output]

  @type component :: %{
          required(:token_dimension) => atom(),
          required(:tokens) => non_neg_integer(),
          required(:relationship) => :additive | :subset | :mutually_exclusive,
          optional(:parent_dimension) => atom(),
          optional(:relationship_group) => String.t()
        }

  @spec build(map(), map()) :: {:ok, [component()]} | {:error, atom()}
  def build(%{dimensions: relationships}, tokens)
      when is_map(relationships) and is_map(tokens) do
    with :ok <- complete_relationships(relationships),
         :ok <- known_relationships(relationships),
         :ok <- complete_tokens(relationships, tokens),
         {:ok, selected} <- select_alternatives(relationships, tokens),
         :ok <- active_subset_parents(relationships, selected) do
      components(relationships, tokens, selected)
    end
  end

  def build(_definition, _tokens), do: {:error, :invalid_relationship_definition}

  defp complete_relationships(relationships) do
    if Enum.all?(@dimensions, &Map.has_key?(relationships, &1)),
      do: :ok,
      else: {:error, :invalid_relationship_definition}
  end

  defp known_relationships(relationships) do
    if Enum.any?(@dimensions, &(Map.fetch!(relationships, &1) == :unknown)),
      do: {:error, :unknown_relationship},
      else: :ok
  end

  defp complete_tokens(relationships, tokens) do
    @dimensions
    |> Enum.reject(&match?({:mutually_exclusive, _group}, Map.fetch!(relationships, &1)))
    |> Enum.find(&(not is_integer(Map.get(tokens, &1))))
    |> case do
      nil -> :ok
      _dimension -> {:error, :missing_dimension}
    end
  end

  defp select_alternatives(relationships, tokens) do
    relationships
    |> alternative_groups()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {_group, members}, {:ok, selected} ->
      case selected_alternative(members, tokens) do
        {:ok, dimension} -> {:cont, {:ok, MapSet.put(selected, dimension)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp alternative_groups(relationships) do
    Enum.reduce(@dimensions, %{}, fn dimension, groups ->
      case Map.fetch!(relationships, dimension) do
        {:mutually_exclusive, group} -> Map.update(groups, group, [dimension], &[dimension | &1])
        _relationship -> groups
      end
    end)
  end

  defp selected_alternative(members, tokens) do
    present = Enum.filter(members, &is_integer(Map.get(tokens, &1)))
    positive = Enum.filter(present, &(Map.fetch!(tokens, &1) > 0))

    cond do
      present == [] -> {:error, :missing_dimension}
      length(positive) > 1 -> {:error, :contradictory_relationship}
      positive != [] -> {:ok, hd(positive)}
      true -> {:ok, Enum.find(@dimensions, &(&1 in present))}
    end
  end

  defp active_subset_parents(relationships, selected) do
    if Enum.any?(@dimensions, &inactive_subset_parent?(&1, relationships, selected)),
      do: {:error, :contradictory_relationship},
      else: :ok
  end

  defp inactive_subset_parent?(dimension, relationships, selected) do
    case Map.fetch!(relationships, dimension) do
      {:subset_of, parent} -> not active?(parent, relationships, selected)
      _relationship -> false
    end
  end

  defp components(relationships, tokens, selected) do
    Enum.reduce_while(@dimensions, {:ok, []}, fn dimension, {:ok, components} ->
      add_component(dimension, relationships, tokens, selected, components)
    end)
    |> then(fn
      {:ok, components} -> {:ok, Enum.reverse(components)}
      error -> error
    end)
  end

  defp add_component(dimension, relationships, tokens, selected, components) do
    if active?(dimension, relationships, selected),
      do: prepend_component(component(dimension, relationships, tokens), components),
      else: {:cont, {:ok, components}}
  end

  defp prepend_component({:ok, component}, components),
    do: {:cont, {:ok, [component | components]}}

  defp prepend_component({:error, reason}, _components), do: {:halt, {:error, reason}}

  defp active?(dimension, relationships, selected) do
    case Map.fetch!(relationships, dimension) do
      {:mutually_exclusive, _group} -> MapSet.member?(selected, dimension)
      _relationship -> true
    end
  end

  defp component(dimension, relationships, tokens) do
    value = Map.fetch!(tokens, dimension)
    children = direct_children(dimension, relationships)
    child_total = Enum.sum(Enum.map(children, &Map.fetch!(tokens, &1)))
    remainder = value - child_total

    if remainder < 0,
      do: {:error, :invalid_parent_remainder},
      else: {:ok, metadata(dimension, Map.fetch!(relationships, dimension), remainder)}
  end

  defp direct_children(parent, relationships) do
    Enum.filter(@dimensions, fn dimension ->
      Map.fetch!(relationships, dimension) == {:subset_of, parent}
    end)
  end

  defp metadata(dimension, :additive, tokens) do
    %{token_dimension: dimension, tokens: tokens, relationship: :additive}
  end

  defp metadata(dimension, {:subset_of, parent}, tokens) do
    %{
      token_dimension: dimension,
      tokens: tokens,
      relationship: :subset,
      parent_dimension: parent
    }
  end

  defp metadata(dimension, {:mutually_exclusive, group}, tokens) do
    %{
      token_dimension: dimension,
      tokens: tokens,
      relationship: :mutually_exclusive,
      relationship_group: group
    }
  end
end
