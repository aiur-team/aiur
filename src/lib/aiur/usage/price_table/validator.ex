defmodule Aiur.Usage.PriceTable.Validator do
  @moduledoc false

  alias Aiur.Usage.PriceTable.ProviderDimensions

  # Registry-derived at compile time so a new metered backend needs no edit here.
  @providers Aiur.CodingAgent.provider_families()
  @dimensions [:input, :cached_input, :cache_creation_input, :output, :reasoning_output]
  @context_tiers [:short_context, :long_context, :not_applicable]
  @cache_write_durations [:five_minutes, :one_hour, :not_applicable]
  @fields [
    :provider,
    :resolved_model,
    :token_dimension,
    :relationship_revision,
    :currency,
    :context_tier,
    :cache_write_duration,
    :price,
    :token_unit,
    :effective_date,
    :price_revision,
    :source_url,
    :source_reviewed_at,
    :pricing_scope
  ]
  @currency ~r/^[A-Z]{3}$/
  @decimal ~r/^\d+(?:\.\d+)?$/

  @spec validate(term(), term()) :: {:ok, String.t(), [map()]} | {:error, atom()}
  def validate(revision, entries) when is_list(entries) do
    with {:ok, revision} <- scalar(revision, :invalid_price_table_revision),
         {:ok, normalized} <- normalize_entries(entries),
         :ok <- validate_intervals(normalized),
         :ok <- validate_revisions(normalized) do
      {:ok, revision, normalized}
    end
  end

  def validate(_revision, _entries), do: {:error, :invalid_price_table}

  defp normalize_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, normalized} ->
      case normalize_entry(entry) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end)
  end

  defp normalize_entry(value) when is_map(value) do
    with :ok <- only_keys(value),
         {:ok, provider} <- enum(value_of(value, :provider), @providers, :invalid_price_provider),
         {:ok, model} <- scalar(value_of(value, :resolved_model), :invalid_price_model),
         {:ok, dimension} <- enum(value_of(value, :token_dimension), @dimensions, :invalid_price_dimension),
         {:ok, relationship} <- scalar(value_of(value, :relationship_revision), :invalid_price_relationship_revision),
         {:ok, currency} <- currency(value_of(value, :currency)),
         {:ok, context_tier} <-
           enum(value_of(value, :context_tier), @context_tiers, :invalid_price_context_tier),
         {:ok, cache_write_duration} <-
           enum(
             value_of(value, :cache_write_duration),
             @cache_write_durations,
             :invalid_cache_write_duration
           ),
         :ok <- ProviderDimensions.validate(provider, dimension, context_tier, cache_write_duration),
         {:ok, price} <- price(value_of(value, :price)),
         {:ok, unit} <- token_unit(value_of(value, :token_unit)),
         {:ok, effective_date} <- date(value_of(value, :effective_date), :invalid_price_effective_date),
         {:ok, revision} <- scalar(value_of(value, :price_revision), :invalid_price_revision),
         {:ok, source} <- source(value_of(value, :source_url)),
         {:ok, reviewed_at} <- date(value_of(value, :source_reviewed_at), :invalid_price_source_reviewed_at),
         {:ok, scope} <- scalar(value_of(value, :pricing_scope), :invalid_pricing_scope) do
      {:ok,
       %{
         provider: provider,
         resolved_model: model,
         token_dimension: dimension,
         relationship_revision: relationship,
         currency: currency,
         context_tier: context_tier,
         cache_write_duration: cache_write_duration,
         price: price,
         token_unit: unit,
         effective_date: effective_date,
         price_revision: revision,
         source_url: source,
         source_reviewed_at: reviewed_at,
         pricing_scope: scope
       }}
    end
  end

  defp normalize_entry(_value), do: {:error, :invalid_price_entry}

  defp validate_intervals(entries) do
    entries
    |> Enum.group_by(&series_key/1)
    |> Enum.any?(fn {_key, series} ->
      series |> Enum.map(& &1.effective_date) |> Enum.uniq() |> length() != length(series)
    end)
    |> if(do: {:error, :ambiguous_price_interval}, else: :ok)
  end

  defp validate_revisions(entries) do
    entries
    |> Enum.group_by(& &1.price_revision)
    |> Enum.any?(fn {_revision, values} ->
      values |> Enum.map(&revision_metadata/1) |> Enum.uniq() |> length() != 1
    end)
    |> if(do: {:error, :price_revision_conflict}, else: :ok)
  end

  defp series_key(entry) do
    {
      entry.provider,
      entry.resolved_model,
      entry.token_dimension,
      entry.relationship_revision,
      entry.currency,
      entry.context_tier,
      entry.cache_write_duration
    }
  end

  defp revision_metadata(entry) do
    {entry.effective_date, entry.source_url, entry.source_reviewed_at, entry.pricing_scope}
  end

  defp price(value) when is_float(value), do: {:error, :float_not_allowed}

  defp price(value) when is_binary(value) and byte_size(value) in 1..128 do
    if String.valid?(value) and Regex.match?(@decimal, value),
      do: {:ok, Decimal.new(value)},
      else: {:error, :invalid_price}
  end

  defp price(_value), do: {:error, :invalid_price}

  defp currency(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@currency, value),
      do: {:ok, value},
      else: {:error, :invalid_price_currency}
  end

  defp currency(_value), do: {:error, :invalid_price_currency}

  defp source(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> {:ok, value}
      _uri -> {:error, :invalid_price_source}
    end
  end

  defp source(_value), do: {:error, :invalid_price_source}

  defp token_unit(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp token_unit(_value), do: {:error, :invalid_price_token_unit}

  defp date(%Date{} = value, _error), do: {:ok, value}
  defp date(_value, error), do: {:error, error}

  defp scalar(value, error) when is_binary(value) and byte_size(value) in 1..256 do
    if String.valid?(value) and value == String.trim(value), do: {:ok, value}, else: {:error, error}
  end

  defp scalar(_value, error), do: {:error, error}

  defp enum(value, allowed, error) when is_atom(value), do: if(value in allowed, do: {:ok, value}, else: {:error, error})

  defp enum(value, allowed, error) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, error}
      atom -> {:ok, atom}
    end
  end

  defp enum(_value, _allowed, error), do: {:error, error}

  defp only_keys(value) do
    strings = Enum.map(@fields, &Atom.to_string/1)

    if length(Map.keys(value)) == length(@fields) and Enum.all?(Map.keys(value), &(&1 in @fields or &1 in strings)),
      do: :ok,
      else: {:error, :invalid_price_fields}
  end

  defp value_of(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
