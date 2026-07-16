defmodule Aiur.Usage.PriceTable do
  @moduledoc """
  Pure, immutable occurrence-time token price resolution.

  A lookup joins every retained pricing dimension exactly. Effective dates are
  inclusive; the next revision in the exact series is the exclusive bound.
  """

  alias Aiur.Usage.PriceTable.{Data, Validator}

  @version 1

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
  def new(revision, entries) do
    with {:ok, revision, normalized} <- Validator.validate(revision, entries) do
      {:ok, %{version: @version, revision: revision, entries: normalized}}
    end
  end

  @spec lookup(catalog(), map()) :: {:ok, map()} | {:error, atom()}
  def lookup(%{version: @version, entries: entries}, query) when is_list(entries) and is_map(query) do
    with {:ok, date} <- lookup_date(value_of(query, :pricing_effective_date)),
         {:ok, series} <- exact_series(entries, query),
         {:ok, entry, next_date} <- interval(series, date) do
      {:ok, Map.put(entry, :expires_before, next_date)}
    end
  end

  def lookup(_catalog, _query), do: {:error, :invalid_price_table}

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

  defp lookup_date(%Date{} = value), do: {:ok, value}
  defp lookup_date(nil), do: {:error, :missing_pricing_effective_date}
  defp lookup_date(_value), do: {:error, :invalid_pricing_effective_date}

  defp value_of(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
