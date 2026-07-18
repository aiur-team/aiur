defmodule Aiur.Usage.GroupedScopes.PriceAdapter do
  @moduledoc false

  # Prices one DASH-024 aggregate token cell into an exact API-equivalent amount
  # through DASH-011's public `Aiur.Usage.PriceTable` boundary.
  #
  # API-equivalent pricing is linear in token count for a fixed price-lookup key
  # (`amount = price * tokens / token_unit`), so a pre-summed aggregate cell
  # prices *exactly* whenever every observation folded into it shares that key.
  # A cell already pins provider, resolved model, relationship revision, pricing
  # date and token dimension, and the caller pins the requested currency — that
  # is the whole lookup key except two occurrence-price-partition dimensions:
  #
  #   * codex `context_tier` (`:short_context` / `:long_context`), and
  #   * claude `cache_write_duration` (`:five_minutes` / `:one_hour`, only on
  #     `:cache_creation_input`).
  #
  # Both are per-observation and price-affecting, and DASH-024 does not retain
  # them (its cells fold them away). Where the price table requires a partition
  # the aggregate cannot supply, the tokens are reported as explicit *unknown*
  # API-equivalent coverage — never zero, never priced at a guessed tier. See
  # `Aiur.Usage.Pricing.Dimensions` for the authoritative provider rules this
  # mirrors, and follow-up issue for retaining the partitions upstream.
  #
  # `:provider_reported_total` is the provider's own summary token count, not a
  # priced component dimension, so it never contributes to the API-equivalent
  # estimate (pricing it would double count the component dimensions).

  alias Aiur.Usage.PriceTable
  alias Aiur.UsageAggregate.Key
  alias Aiur.UsageEnvelope.RelationshipRegistry

  @priced_dimensions Key.token_dimensions() -- [:provider_reported_total]

  @type priced :: %{amount: Decimal.t(), price_revision: String.t(), currency: String.t()}

  @doc "Whether a token dimension participates in API-equivalent pricing at all."
  @spec priced_dimension?(atom()) :: boolean()
  def priced_dimension?(dimension), do: dimension in @priced_dimensions

  @doc """
  Resolves the exact API-equivalent amount for `tokens` of one token dimension.

  `siblings` is the `%{dimension => count}` of the token cell's aggregate group
  (its identity dimensions), and `relationships` is the relationship registry
  the group's `(provider, relationship_revision)` resolves against. A subset
  *parent* is priced on its remainder (`parent − Σ subset children`) exactly as
  DASH-011's `Aiur.Usage.Pricing.Components`, so an overlapping child (claude
  `reasoning_output` ⊂ `output`) is never double counted.

  Returns `{:ok, priced}` with the amount and the occurrence-price
  partition/revision, or `{:unknown, reason}` when the price table cannot be
  joined exactly (unretained partition, unknown model/date/revision, a price not
  yet effective, or a relationship revision whose subset structure the registry
  cannot resolve — the remainder is then unknowable rather than guessed).
  """
  @spec price(Key.dims(), atom(), %{optional(atom()) => non_neg_integer()}, RelationshipRegistry.catalog(), String.t(), PriceTable.catalog()) ::
          {:ok, priced()} | {:unknown, atom()}
  def price(_dims, :provider_reported_total, _siblings, _relationships, _currency, _price_table),
    do: {:unknown, :not_a_priced_dimension}

  def price(dims, token_dimension, siblings, relationships, currency, price_table) do
    with {:ok, partition} <- partition_dimensions(dims.provider, token_dimension),
         {:ok, tokens} <- remainder(dims, token_dimension, siblings, relationships),
         query = lookup_query(dims, token_dimension, currency, partition),
         {:ok, entry} <- PriceTable.lookup(price_table, query) do
      amount = entry.price |> Decimal.mult(Decimal.new(tokens)) |> Decimal.div(Decimal.new(entry.token_unit))
      {:ok, %{amount: amount, price_revision: entry.price_revision, currency: currency}}
    else
      {:unknown, reason} -> {:unknown, reason}
      {:error, reason} -> {:unknown, reason}
    end
  end

  # Subtract subset-child token counts from a parent so it prices only its
  # remainder. The partition check runs first, so a provider whose components
  # never price from the aggregate (codex) keeps its own `:unknown` reason and
  # never reaches this. Remainder is exact at the aggregate level because
  # `Σ(parent_r − child_r) = parent_cell − child_cell`. A negative remainder can
  # only come from an inconsistent (degraded/corrupt) source where a child cell
  # exceeds its parent; that is explicit unknown coverage, never a negative
  # amount, matching DASH-011's `:invalid_parent_remainder`.
  defp remainder(dims, token_dimension, siblings, relationships) do
    with {:ok, edges} <-
           RelationshipRegistry.subset_children(relationships, dims.provider, dims.relationship_revision) do
      children = Map.get(edges, token_dimension, [])
      subtract = Enum.reduce(children, 0, fn child, sum -> sum + Map.get(siblings, child, 0) end)
      remainder = Map.fetch!(siblings, token_dimension) - subtract

      if remainder < 0, do: {:unknown, :invalid_parent_remainder}, else: {:ok, remainder}
    end
  end

  # Codex never retains its context tier, so no codex component can be priced
  # from the aggregate. Claude retains no cache-write duration, which only
  # discriminates the cache-creation dimension; every other claude dimension has
  # a fully known (`:not_applicable`) partition and prices exactly.
  defp partition_dimensions(:codex, _token_dimension), do: {:unknown, :unretained_context_tier}

  defp partition_dimensions(:claude, :cache_creation_input),
    do: {:unknown, :unretained_cache_write_duration}

  defp partition_dimensions(:claude, _token_dimension),
    do: {:ok, %{context_tier: :not_applicable, cache_write_duration: :not_applicable}}

  defp lookup_query(dims, token_dimension, currency, partition) do
    Map.merge(
      %{
        provider: dims.provider,
        resolved_model: dims.resolved_model,
        token_dimension: token_dimension,
        relationship_revision: dims.relationship_revision,
        currency: currency,
        pricing_effective_date: dims.pricing_date
      },
      partition
    )
  end
end
