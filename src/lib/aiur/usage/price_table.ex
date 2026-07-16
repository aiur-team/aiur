defmodule Aiur.Usage.PriceTable do
  @moduledoc """
  Pure, immutable occurrence-time token price resolution.

  A lookup joins every retained pricing dimension exactly. Effective dates are
  inclusive; the next revision in the exact series is the exclusive bound.
  """

  alias Aiur.Usage.PriceTable.Data

  @version 1
  @providers [:codex, :claude]
  @dimensions [:input, :cached_input, :cache_creation_input, :output, :reasoning_output]
  @fields [
    :provider,
    :resolved_model,
    :token_dimension,
    :relationship_revision,
    :currency,
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

  @type entry :: %{
          provider: :codex | :claude,
          resolved_model: String.t(),
          token_dimension: atom(),
          relationship_revision: String.t(),
          currency: String.t(),
          price: Decimal.t(),
          token_unit: pos_integer(),
          effective_date: Date.t(),
          price_revision: String.t(),
          source_url: String.t(),
          source_reviewed_at: Date.t(),
          pricing_scope: String.t()
        }
  @type catalog :: %{version: 1, revision: String.t(), entries: [entry()]}

  @spec default() :: {:ok, catalog()} | {:error, atom()}
  def default, do: new(Data.catalog_revision(), Data.entries())

  @spec new(String.t(), [map()]) :: {:ok, catalog()} | {:error, atom()}
  def new(revision, entries) when is_list(entries) do
    with {:ok, revision} <- scalar(revision, :invalid_price_table_revision),
         {:ok, normalized} <- normalize_entries(entries),
         :ok <- validate_intervals(normalized),
         :ok <- validate_revisions(normalized) do
      {:ok, %{version: @version, revision: revision, entries: normalized}}
    end
  end

  def new(_revision, _entries), do: {:error, :invalid_price_table}

  @spec lookup(catalog(), map()) :: {:ok, map()} | {:error, atom()}
  def lookup(%{version: @version, entries: entries}, query) when is_list(entries) and is_map(query) do
    with {:ok, date} <- lookup_date(value_of(query, :pricing_effective_date)),
         {:ok, series} <- exact_series(entries, query),
         {:ok, entry, next_date} <- interval(series, date) do
      {:ok, Map.put(entry, :expires_before, next_date)}
    end
  end

  def lookup(_catalog, _query), do: {:error, :invalid_price_table}

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

  defp exact_series(entries, query) do
    filters = [
      {:provider, value_of(query, :provider), :unknown_price_provider},
      {:resolved_model, value_of(query, :resolved_model), :unknown_price_model},
      {:currency, value_of(query, :currency), :unsupported_price_currency},
      {:relationship_revision, value_of(query, :relationship_revision), :unknown_price_relationship_revision},
      {:token_dimension, value_of(query, :token_dimension), :unknown_price_dimension}
    ]

    Enum.reduce_while(filters, {:ok, entries}, fn {field, expected, reason}, {:ok, candidates} ->
      matching = Enum.filter(candidates, &(Map.fetch!(&1, field) == expected))
      if matching == [], do: {:halt, {:error, reason}}, else: {:cont, {:ok, matching}}
    end)
  end

  defp interval(series, date) do
    sorted = Enum.sort_by(series, & &1.effective_date, Date)

    case Enum.split_while(sorted, &(Date.compare(&1.effective_date, date) in [:lt, :eq])) do
      {[], _future} -> {:error, :price_not_yet_effective}
      {eligible, future} -> {:ok, List.last(eligible), next_date(future)}
    end
  end

  defp next_date([next | _rest]), do: next.effective_date
  defp next_date([]), do: nil

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
    {entry.provider, entry.resolved_model, entry.token_dimension, entry.relationship_revision, entry.currency}
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

  defp lookup_date(%Date{} = value), do: {:ok, value}
  defp lookup_date(nil), do: {:error, :missing_pricing_effective_date}
  defp lookup_date(_value), do: {:error, :invalid_pricing_effective_date}

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
