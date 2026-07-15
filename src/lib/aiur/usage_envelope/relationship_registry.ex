defmodule Aiur.UsageEnvelope.RelationshipRegistry do
  @moduledoc """
  Immutable token-relationship definitions used to reconcile usage envelopes.

  A definition is selected by provider, source, source version, and the exact
  revision pinned on the envelope. Registering a newer revision never changes
  how a retained envelope is interpreted.
  """

  alias Aiur.UsageEnvelope

  @version 1
  @dimensions [:input, :cached_input, :cache_creation_input, :output, :reasoning_output]
  @input_dimensions [:input, :cached_input, :cache_creation_input]
  @output_dimensions [:output, :reasoning_output]
  @providers [:codex, :claude]
  @definition_fields [
    :provider,
    :source,
    :source_version,
    :revision,
    :provider_total_authoritative,
    :dimensions
  ]

  @type dimension :: :input | :cached_input | :cache_creation_input | :output | :reasoning_output
  @type relationship :: :additive | :unknown | {:subset_of, dimension()} | {:mutually_exclusive, String.t()}
  @type definition :: %{
          provider: :codex | :claude,
          source: String.t(),
          source_version: String.t(),
          revision: String.t(),
          provider_total_authoritative: boolean(),
          dimensions: %{required(dimension()) => relationship()}
        }
  @type catalog :: %{version: 1, entries: %{optional(tuple()) => definition()}}
  @type reconciliation :: %{
          canonical_total: non_neg_integer() | nil,
          input_total: non_neg_integer() | nil,
          output_total: non_neg_integer() | nil,
          provider_total: non_neg_integer() | nil,
          derived_total: non_neg_integer() | nil,
          relationship_revision: String.t(),
          status: atom(),
          coverage: :full | :partial | :unknown,
          coverage_reasons: [atom()],
          discrepancy: integer() | nil
        }

  @spec new([map()]) :: {:ok, catalog()} | {:error, atom()}
  def new(definitions \\ [])

  def new(definitions) when is_list(definitions) do
    Enum.reduce_while(definitions, {:ok, %{version: @version, entries: %{}}}, fn definition, {:ok, catalog} ->
      case register(catalog, definition) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def new(_definitions), do: {:error, :invalid_relationship_catalog}

  @spec register(catalog(), map()) :: {:ok, catalog()} | {:error, atom()}
  def register(%{version: @version, entries: entries} = catalog, definition)
      when is_map(entries) and is_map(definition) do
    with {:ok, normalized} <- normalize_definition(definition),
         key = definition_key(normalized),
         :ok <- revision_available(entries, key, normalized) do
      {:ok, %{catalog | entries: Map.put(entries, key, normalized)}}
    end
  end

  def register(_catalog, _definition), do: {:error, :invalid_relationship_catalog}

  @spec resolve(catalog(), UsageEnvelope.t()) :: {:ok, definition()} | {:error, atom()}
  def resolve(%{version: @version, entries: entries}, %UsageEnvelope{} = envelope)
      when is_map(entries) do
    key = {envelope.provider, envelope.source, envelope.source_version, envelope.relationship_revision}

    case Map.fetch(entries, key) do
      {:ok, definition} ->
        with {:ok, normalized} <- normalize_definition(definition),
             true <- definition_key(normalized) == key do
          {:ok, normalized}
        else
          _invalid -> {:error, :invalid_relationship_catalog}
        end

      :error ->
        {:error, :missing_historic_relationship_revision}
    end
  end

  def resolve(_catalog, _envelope), do: {:error, :invalid_relationship_catalog}

  @spec reconcile(catalog(), UsageEnvelope.t()) :: {:ok, reconciliation()} | {:error, atom()}
  def reconcile(catalog, %UsageEnvelope{} = envelope) do
    case resolve(catalog, envelope) do
      {:ok, definition} -> {:ok, reconcile_definition(definition, envelope)}
      {:error, :missing_historic_relationship_revision} -> {:ok, missing_revision(envelope)}
      {:error, reason} -> {:error, reason}
    end
  end

  def reconcile(_catalog, _envelope), do: {:error, :invalid_envelope}

  defp reconcile_definition(definition, envelope) do
    input = category_total(definition.dimensions, envelope.tokens, @input_dimensions)
    output = category_total(definition.dimensions, envelope.tokens, @output_dimensions)
    dimensions = combine_totals(input, output)
    provider_total = envelope.tokens.provider_reported_total
    authoritative? = definition.provider_total_authoritative and is_integer(provider_total)
    derived_total = value_or_nil(dimensions)
    discrepancy = discrepancy(provider_total, derived_total)

    {canonical_total, status} =
      cond do
        authoritative? and is_integer(discrepancy) and discrepancy != 0 ->
          {provider_total, :authoritative_discrepancy}

        authoritative? ->
          {provider_total, :authoritative}

        is_integer(derived_total) ->
          {derived_total, if(discrepancy in [nil, 0], do: :derived, else: :derived_discrepancy)}

        true ->
          {nil, :unreconciled}
      end

    relationship_reasons =
      [reason_or_nil(input), reason_or_nil(output)]
      |> Enum.reject(&is_nil/1)

    reasons =
      relationship_reasons
      |> maybe_append(envelope.update_kind == :partial, :partial_update)
      |> maybe_append(is_integer(discrepancy) and discrepancy != 0, :provider_total_discrepancy)
      |> Enum.uniq()

    %{
      canonical_total: canonical_total,
      input_total: value_or_nil(input),
      output_total: value_or_nil(output),
      provider_total: provider_total,
      derived_total: derived_total,
      relationship_revision: definition.revision,
      status: status,
      coverage: coverage(canonical_total, reasons),
      coverage_reasons: reasons,
      discrepancy: discrepancy
    }
  end

  defp category_total(relationships, tokens, dimensions) do
    with :ok <- validate_subsets(relationships, tokens, dimensions),
         {:ok, additive} <- additive_total(relationships, tokens, dimensions),
         {:ok, alternatives} <- mutually_exclusive_total(relationships, tokens, dimensions),
         :ok <- known_relationships(relationships, dimensions) do
      {:ok, additive + alternatives}
    end
  end

  defp validate_subsets(relationships, tokens, dimensions) do
    dimensions
    |> Enum.filter(&match?({:subset_of, _}, Map.fetch!(relationships, &1)))
    |> Enum.reduce_while(:ok, fn dimension, :ok ->
      {:subset_of, parent} = Map.fetch!(relationships, dimension)
      value = Map.fetch!(tokens, dimension)
      parent_value = Map.fetch!(tokens, parent)

      cond do
        is_nil(value) -> {:cont, :ok}
        is_nil(parent_value) -> {:halt, {:error, :missing_dimension}}
        value <= parent_value -> {:cont, :ok}
        true -> {:halt, {:error, :contradictory_relationship}}
      end
    end)
  end

  defp additive_total(relationships, tokens, dimensions) do
    dimensions
    |> Enum.filter(&(Map.fetch!(relationships, &1) == :additive))
    |> Enum.reduce_while({:ok, 0}, fn dimension, {:ok, total} ->
      case Map.fetch!(tokens, dimension) do
        value when is_integer(value) -> {:cont, {:ok, total + value}}
        nil -> {:halt, {:error, :missing_dimension}}
      end
    end)
  end

  defp mutually_exclusive_total(relationships, tokens, dimensions) do
    dimensions
    |> Enum.reduce(%{}, fn dimension, groups ->
      case Map.fetch!(relationships, dimension) do
        {:mutually_exclusive, group} -> Map.update(groups, group, [dimension], &[dimension | &1])
        _relationship -> groups
      end
    end)
    |> Enum.reduce_while({:ok, 0}, fn {_group, members}, {:ok, total} ->
      values = Enum.map(members, &Map.fetch!(tokens, &1))
      present = Enum.filter(values, &is_integer/1)
      nonzero = Enum.filter(present, &(&1 > 0))

      cond do
        present == [] -> {:halt, {:error, :missing_dimension}}
        length(nonzero) > 1 -> {:halt, {:error, :contradictory_relationship}}
        true -> {:cont, {:ok, total + Enum.sum(nonzero)}}
      end
    end)
  end

  defp known_relationships(relationships, dimensions) do
    if Enum.any?(dimensions, &(Map.fetch!(relationships, &1) == :unknown)),
      do: {:error, :unknown_relationship},
      else: :ok
  end

  defp combine_totals({:ok, input}, {:ok, output}), do: {:ok, input + output}
  defp combine_totals({:error, reason}, _output), do: {:error, reason}
  defp combine_totals(_input, {:error, reason}), do: {:error, reason}

  defp value_or_nil({:ok, value}), do: value
  defp value_or_nil({:error, _reason}), do: nil
  defp reason_or_nil({:ok, _value}), do: nil
  defp reason_or_nil({:error, reason}), do: reason

  defp discrepancy(provider_total, derived_total)
       when is_integer(provider_total) and is_integer(derived_total),
       do: provider_total - derived_total

  defp discrepancy(_provider_total, _derived_total), do: nil

  defp coverage(nil, _reasons), do: :unknown
  defp coverage(_total, []), do: :full
  defp coverage(_total, _reasons), do: :partial

  defp missing_revision(envelope) do
    %{
      canonical_total: nil,
      input_total: nil,
      output_total: nil,
      provider_total: envelope.tokens.provider_reported_total,
      derived_total: nil,
      relationship_revision: envelope.relationship_revision,
      status: :unreconciled,
      coverage: :unknown,
      coverage_reasons: [:missing_historic_relationship_revision],
      discrepancy: nil
    }
  end

  defp normalize_definition(value) do
    with :ok <- only_keys(value, @definition_fields),
         {:ok, provider} <- enum(value_of(value, :provider), @providers, :invalid_relationship_provider),
         {:ok, source} <- scalar(value_of(value, :source)),
         {:ok, source_version} <- scalar(value_of(value, :source_version)),
         {:ok, revision} <- scalar(value_of(value, :revision)),
         authoritative? when is_boolean(authoritative?) <-
           value_of(value, :provider_total_authoritative),
         {:ok, dimensions} <- dimensions(value_of(value, :dimensions)) do
      {:ok,
       %{
         provider: provider,
         source: source,
         source_version: source_version,
         revision: revision,
         provider_total_authoritative: authoritative?,
         dimensions: dimensions
       }}
    else
      false -> {:error, :invalid_provider_total_authority}
      nil -> {:error, :invalid_provider_total_authority}
      {:error, reason} -> {:error, reason}
      _value -> {:error, :invalid_provider_total_authority}
    end
  end

  defp dimensions(value) when is_map(value) do
    with :ok <- only_keys(value, @dimensions),
         {:ok, normalized} <- normalize_relationships(value),
         :ok <- validate_relationship_parents(normalized) do
      {:ok, normalized}
    end
  end

  defp dimensions(_value), do: {:error, :invalid_relationship_dimensions}

  defp normalize_relationships(value) do
    Enum.reduce_while(@dimensions, {:ok, %{}}, fn dimension, {:ok, normalized} ->
      case relationship(value_of(value, dimension)) do
        {:ok, relationship} -> {:cont, {:ok, Map.put(normalized, dimension, relationship)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp relationship(:additive), do: {:ok, :additive}
  defp relationship("additive"), do: {:ok, :additive}
  defp relationship(:unknown), do: {:ok, :unknown}
  defp relationship("unknown"), do: {:ok, :unknown}

  defp relationship({:subset_of, parent}) when parent in @dimensions,
    do: {:ok, {:subset_of, parent}}

  defp relationship({:mutually_exclusive, group}) do
    with {:ok, group} <- scalar(group), do: {:ok, {:mutually_exclusive, group}}
  end

  defp relationship(_value), do: {:error, :invalid_dimension_relationship}

  defp validate_relationship_parents(relationships) do
    Enum.reduce_while(relationships, :ok, fn
      {dimension, {:subset_of, dimension}}, :ok ->
        {:halt, {:error, :invalid_dimension_relationship}}

      {dimension, {:subset_of, parent}}, :ok ->
        if category(dimension) == category(parent),
          do: {:cont, :ok},
          else: {:halt, {:error, :invalid_dimension_relationship}}

      {_dimension, _relationship}, :ok ->
        {:cont, :ok}
    end)
    |> validate_alternative_categories(relationships)
    |> validate_subset_cycles(relationships)
  end

  defp validate_alternative_categories(:ok, relationships) do
    relationships
    |> Enum.reduce(%{}, fn
      {dimension, {:mutually_exclusive, group}}, groups ->
        Map.update(groups, group, MapSet.new([category(dimension)]), &MapSet.put(&1, category(dimension)))

      {_dimension, _relationship}, groups ->
        groups
    end)
    |> Enum.all?(fn {_group, categories} -> MapSet.size(categories) == 1 end)
    |> if(do: :ok, else: {:error, :invalid_dimension_relationship})
  end

  defp validate_alternative_categories(error, _relationships), do: error

  defp validate_subset_cycles(:ok, relationships) do
    Enum.reduce_while(@dimensions, :ok, fn dimension, :ok ->
      case follow_subset(dimension, relationships, MapSet.new([dimension])) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_subset_cycles(error, _relationships), do: error

  defp follow_subset(dimension, relationships, seen) do
    case Map.fetch!(relationships, dimension) do
      {:subset_of, parent} ->
        if MapSet.member?(seen, parent),
          do: {:error, :invalid_dimension_relationship},
          else: follow_subset(parent, relationships, MapSet.put(seen, parent))

      _relationship ->
        :ok
    end
  end

  defp category(dimension) when dimension in @input_dimensions, do: :input
  defp category(dimension) when dimension in @output_dimensions, do: :output

  defp revision_available(entries, key, definition) do
    case Map.fetch(entries, key) do
      :error -> :ok
      {:ok, ^definition} -> :ok
      {:ok, _different} -> {:error, :relationship_revision_conflict}
    end
  end

  defp definition_key(definition) do
    {definition.provider, definition.source, definition.source_version, definition.revision}
  end

  defp enum(value, allowed, error) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: {:error, error}
  end

  defp enum(value, allowed, error) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, error}
      atom -> {:ok, atom}
    end
  end

  defp enum(_value, _allowed, error), do: {:error, error}

  defp scalar(value) when is_binary(value) and byte_size(value) in 1..256 do
    if value == String.trim(value), do: {:ok, value}, else: {:error, :invalid_relationship_scalar}
  end

  defp scalar(_value), do: {:error, :invalid_relationship_scalar}

  defp only_keys(value, allowed) do
    allowed_strings = Enum.map(allowed, &Atom.to_string/1)

    if Enum.sort(Map.keys(value)) |> length() == length(allowed) and
         Enum.all?(Map.keys(value), &(&1 in allowed or &1 in allowed_strings)),
       do: :ok,
       else: {:error, :invalid_relationship_fields}
  end

  defp value_of(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp maybe_append(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_append(reasons, false, _reason), do: reasons
end
