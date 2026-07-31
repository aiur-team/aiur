defmodule Aiur.Cost.Pricer do
  @moduledoc """
  Prices accumulated per-ticket token totals into a USD `Decimal` using the
  built-in `Aiur.Usage.PriceTable` catalog.

  Costs are computed from **absolute** cumulative token totals (input, cached
  input, output), not per-event deltas, so re-pricing on every update is
  idempotent and never double-counts. A dimension with zero tokens contributes
  zero without requiring a catalog entry; a non-zero dimension with no matching
  price makes the whole estimate unavailable (`{:error, reason}`) so the UI can
  show tokens without a misleading dollar figure.
  """

  alias Aiur.Usage.PriceTable

  @type meta :: %{
          provider: :codex | :claude,
          resolved_model: String.t(),
          relationship_revision: String.t(),
          pricing_effective_date: Date.t(),
          context_tier: atom() | nil
        }

  @type tokens :: %{
          input_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer()
        }

  @dimension_map [
    {:input_tokens, :input},
    {:cached_input_tokens, :cached_input},
    {:output_tokens, :output}
  ]

  @doc """
  Loads the default catalog once and memoizes it in `:persistent_term`.
  """
  @spec catalog() :: PriceTable.catalog() | nil
  def catalog do
    case :persistent_term.get({__MODULE__, :catalog}, :undefined) do
      :undefined ->
        catalog =
          case PriceTable.default() do
            {:ok, catalog} -> catalog
            {:error, _reason} -> nil
          end

        :persistent_term.put({__MODULE__, :catalog}, catalog)
        catalog

      catalog ->
        catalog
    end
  end

  @doc """
  Sums the priced value of every non-zero token dimension.
  """
  @spec usd(PriceTable.catalog() | nil, meta(), tokens()) :: {:ok, Decimal.t()} | {:error, atom()}
  def usd(nil, _meta, _tokens), do: {:error, :price_table_unavailable}

  def usd(catalog, meta, tokens) when is_map(catalog) and is_map(meta) do
    # Providers report `input_tokens` as the full prompt count *including* the
    # cached portion (cached_input ⊂ input). Bill the non-cached remainder at the
    # input rate and the cached tokens at the cached rate, so cached tokens are
    # priced exactly once. Matches `Aiur.Usage.Pricing.Components` subset logic.
    billable = billable_tokens(tokens)

    Enum.reduce_while(@dimension_map, {:ok, Decimal.new(0)}, fn {token_key, dimension}, {:ok, acc} ->
      count = Map.get(billable, token_key, 0)

      cond do
        not is_integer(count) or count <= 0 ->
          {:cont, {:ok, acc}}

        true ->
          case component_amount(catalog, meta, dimension, count) do
            {:ok, amount} -> {:cont, {:ok, Decimal.add(acc, amount)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  def usd(_catalog, _meta, _tokens), do: {:error, :invalid_pricing_meta}

  defp billable_tokens(tokens) do
    input = Map.get(tokens, :input_tokens, 0)
    cached = Map.get(tokens, :cached_input_tokens, 0)
    Map.put(tokens, :input_tokens, max(0, input - cached))
  end

  defp component_amount(catalog, meta, dimension, count) do
    query = %{
      provider: meta.provider,
      resolved_model: meta.resolved_model,
      token_dimension: dimension,
      relationship_revision: meta.relationship_revision,
      currency: "USD",
      pricing_effective_date: meta.pricing_effective_date,
      context_tier: context_tier(meta),
      cache_write_duration: :not_applicable
    }

    case PriceTable.lookup(catalog, query) do
      {:ok, entry} ->
        amount =
          entry.price
          |> Decimal.mult(Decimal.new(count))
          |> Decimal.div(Decimal.new(entry.token_unit))

        {:ok, amount}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Input / cached-input / output share the base (non cache-creation) price row.
  # Only Codex partitions that row by context tier; Claude rows are always
  # `:not_applicable`.
  defp context_tier(%{provider: :codex, context_tier: tier}) when tier in [:short_context, :long_context], do: tier
  defp context_tier(%{provider: :codex}), do: :short_context
  defp context_tier(_meta), do: :not_applicable
end
