defmodule Aiur.Usage.GroupedScopes do
  @moduledoc """
  Pure, bounded grouped-usage query layer (DASH-030).

  Projects DASH-024's crash-safe aggregate cells and DASH-011's exact pricing
  into scope-labelled, reconciled contributor summaries. It is a pure function
  layer with no process, no supervision child, and no storage or price-table
  file access: it consumes an aggregate snapshot (`%{cells: ..., metadata:
  ...}`) plus an explicit typed `Aiur.Usage.GroupedScopes.Scope`, and returns an
  immutable snapshot suitable for DASH-021's protected facade, the Units
  "this run" view, and DASH-023's selected-build adapter.

  ## What it returns

  For a requested scope it preserves canonical token counts and, separately
  labelled and never combined:

    * `provider_reported_estimate` monetary contributions (from the aggregate),
    * `api_equivalent_estimate` monetary contributions (re-priced exactly from
      the aggregate token cells through `Aiur.Usage.PriceTable`), and
    * explicit *unknown* monetary coverage.

  Every measure is preserved across the contributor dimensions (provider,
  upstream provider, structured provider route, run, ticket, agent family,
  backend, exact resolved model, auth mode, account generation, currency,
  occurrence-price partition/revision, and token-relationship revision) and
  rolled up into one exact compatible-currency API-equivalent total per
  currency that reconciles, in both directions, to its preserved contributors.
  Unlike monetary bases and unlike currencies never combine, and unknown or
  contradictory pricing can never become a zero total.

  ## Exactness boundary

  API-equivalent pricing is linear in token count, so re-pricing a pre-summed
  aggregate cell is exact whenever the cell's full price-lookup key is known.
  DASH-024 does not retain codex `context_tier` or claude
  `cache_write_duration`; those token dimensions are reported as explicit
  unknown API-equivalent coverage rather than priced at a guessed partition (see
  `Aiur.Usage.GroupedScopes.PriceAdapter`).

  A subset *parent* dimension is priced on its remainder (`parent − Σ subset
  children`) using the group's relationship revision, exactly as DASH-011's
  `Aiur.Usage.Pricing.Components`, so an overlapping child (claude
  `reasoning_output` ⊂ `output`) never double counts against the roll-up.
  """

  alias Aiur.Claude.Telemetry.UsageAdapter.Relationship
  alias Aiur.Usage.GroupedScopes.{Coverage, Projection, Scope}
  alias Aiur.Usage.Headless.Catalog
  alias Aiur.Usage.PriceTable
  alias Aiur.UsageAggregate.Key
  alias Aiur.UsageEnvelope.RelationshipRegistry

  @schema_version 1
  @default_currency "USD"
  @default_page_limit 50
  @max_page_limit 500

  @type source :: %{required(:cells) => map(), required(:metadata) => map()} | nil

  @doc """
  Projects `source` restricted to `scope` into an immutable grouped snapshot.

  Options:

    * `:currency` — requested API-equivalent currency (default `"USD"`).
    * `:price_table` — a `Aiur.Usage.PriceTable` catalog (default
      `PriceTable.default/0`). Passing it in keeps the layer pure and lets the
      caller pin the pricing authority in its cache key.
    * `:relationship_catalog` — a `Aiur.UsageEnvelope.RelationshipRegistry`
      catalog resolving each group's `(provider, relationship_revision)` to its
      subset structure, so a subset parent prices on its remainder rather than
      double counting an overlapping child. Defaults to the pinned catalog for
      the providers this layer prices.
  """
  @spec project(source(), Scope.t(), keyword()) :: map()
  def project(source, %Scope{} = scope, opts \\ []) do
    currency = Keyword.get(opts, :currency, @default_currency)
    relationships = Keyword.get_lazy(opts, :relationship_catalog, &default_relationship_catalog/0)

    case resolve_price_table(opts) do
      {:ok, price_table} -> do_project(source, scope, currency, price_table, relationships)
      {:error, reason} -> unavailable(scope, currency, {:price_table, reason})
    end
  end

  defp resolve_price_table(opts) do
    case Keyword.fetch(opts, :price_table) do
      {:ok, catalog} -> {:ok, catalog}
      :error -> PriceTable.default()
    end
  end

  # The subset structure the API-equivalent remainder needs is identical across
  # both pinned claude relationship revisions (`reasoning_output` ⊂ `output`);
  # codex components never price from the aggregate, so no codex revision is
  # required here. A caller may override to pin the authority in its cache key.
  defp default_relationship_catalog do
    {:ok, catalog} =
      RelationshipRegistry.register(
        Catalog.relationship_catalog(),
        Relationship.definition()
      )

    catalog
  end

  defp do_project(source, scope, currency, price_table, relationships) do
    case validate_source(source) do
      {:error, reason} ->
        unavailable(scope, currency, reason)

      {:ok, cells, metadata} ->
        selected = select(cells, scope)
        token_entries = Projection.token_entries(selected, currency, price_table, relationships)
        money_entries = Projection.money_entries(selected)
        build_snapshot(scope, currency, price_table, metadata, selected, token_entries, money_entries)
    end
  end

  # --- source validation & selection --------------------------------------

  defp validate_source(%{cells: cells, metadata: metadata})
       when is_map(cells) and is_map(metadata) do
    if metadata_unavailable?(metadata), do: {:error, :unavailable_projection}, else: {:ok, cells, metadata}
  end

  defp validate_source(_source), do: {:error, :missing_source}

  defp metadata_unavailable?(metadata) do
    match?({:unavailable, _reason}, Map.get(metadata, :health)) or
      Map.get(metadata, :freshness, %{})[:status] == :unavailable
  end

  defp select(cells, scope) do
    Enum.filter(cells, fn {{dims, _measure}, _value} -> Scope.matches?(scope, dims) end)
  end

  # --- snapshot assembly --------------------------------------------------

  defp build_snapshot(scope, currency, price_table, metadata, selected, token_entries, money_entries) do
    totals = Projection.totals(token_entries, money_entries)
    contributors = Projection.contributors(token_entries, money_entries, totals)
    reconciliation = Coverage.reconciliation(totals, contributors)
    coverage = Coverage.coverage(selected, token_entries, metadata, totals)

    %{
      schema_version: @schema_version,
      scope: Scope.public(scope),
      currency: currency,
      state: Coverage.state(metadata, selected, coverage),
      authority: authority(metadata, price_table),
      health: Map.get(metadata, :health),
      freshness: Map.get(metadata, :freshness),
      retained_interval: Coverage.retained_interval(metadata),
      tokens: totals.tokens,
      provider_reported_estimate: %{by_currency: totals.provider_reported},
      api_equivalent_estimate: %{
        rollup: totals.api_amount,
        coverage: totals.api_coverage
      },
      contributors: contributors,
      reconciliation: reconciliation,
      tier_join_keys: Projection.tier_join_keys(selected),
      coverage: coverage
    }
  end

  # --- authority & change notification ------------------------------------

  @doc """
  The full authority tuple a caller must fold into a cache key alongside the
  scope: every generation that can invalidate the result. Rejecting a stale
  asynchronous result is comparing this against the current source authority
  rather than relabelling it.
  """
  @spec authority(map(), PriceTable.catalog()) :: map()
  def authority(metadata, price_table) do
    %{
      schema_version: @schema_version,
      aggregate_generation: Map.get(metadata, :generation),
      source_position: Map.get(metadata, :source_position),
      source_generation: Map.get(metadata, :source_generation),
      price_table_revision: Map.get(price_table, :revision)
    }
  end

  @doc "A cache key combining the snapshot's scope and every authority generation."
  @spec cache_key(map()) :: {map(), map()}
  def cache_key(%{scope: scope, authority: authority}), do: {scope, authority}

  @doc """
  Whether `snapshot` still reflects `current_metadata`. A stale snapshot is
  rejected (its generation no longer matches), never silently relabelled.
  """
  @spec fresh?(map(), map()) :: boolean()
  def fresh?(%{authority: authority}, current_metadata) do
    authority.aggregate_generation == Map.get(current_metadata, :generation) and
      authority.source_position == Map.get(current_metadata, :source_position) and
      authority.source_generation == Map.get(current_metadata, :source_generation)
  end

  @doc """
  Whether two snapshots differ in a way a subscriber should observe — a change
  notification predicate for DASH-021's facade. Distinct authority, scope, or
  content is a change; identical inputs are not.
  """
  @spec changed?(map() | nil, map()) :: boolean()
  def changed?(nil, _current), do: true
  def changed?(previous, current), do: signature(previous) != signature(current)

  defp signature(snapshot) do
    Map.take(snapshot, [
      :schema_version,
      :scope,
      :authority,
      :state,
      :tokens,
      :provider_reported_estimate,
      :api_equivalent_estimate,
      :tier_join_keys
    ])
  end

  # --- bounded pagination / drill-down ------------------------------------

  @doc """
  A bounded page of one contributor dimension's summaries.

  Options: `:cursor` (opaque non-negative offset, default `0`) and `:limit`
  (default #{@default_page_limit}, capped at #{@max_page_limit}). Contributors
  are canonically ordered, so paging is deterministic and restart-stable.
  """
  @spec drill_down(map(), atom(), keyword()) :: map()
  def drill_down(%{contributors: contributors}, dimension, opts \\ []) do
    entries = Map.get(contributors, dimension, [])
    cursor = opts |> Keyword.get(:cursor, 0) |> max(0)
    limit = opts |> Keyword.get(:limit, @default_page_limit) |> clamp_limit()

    page = entries |> Enum.drop(cursor) |> Enum.take(limit)
    next = cursor + length(page)

    %{
      dimension: dimension,
      items: page,
      total: length(entries),
      cursor: cursor,
      limit: limit,
      next_cursor: if(next < length(entries), do: next, else: nil),
      has_more: next < length(entries)
    }
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_page_limit)
  defp clamp_limit(_limit), do: @default_page_limit

  # --- unavailable snapshot ----------------------------------------------

  defp unavailable(scope, currency, reason) do
    %{
      schema_version: @schema_version,
      scope: Scope.public(scope),
      currency: currency,
      state: :unavailable,
      reason: reason,
      authority: %{schema_version: @schema_version, aggregate_generation: nil, source_position: nil, source_generation: nil, price_table_revision: nil},
      health: nil,
      freshness: nil,
      retained_interval: %{earliest: nil, latest: nil, status: :missing},
      tokens: %{},
      provider_reported_estimate: %{by_currency: %{}},
      api_equivalent_estimate: %{rollup: %{}, coverage: %{known: 0, unknown: 0, reasons: [], status: :none}},
      contributors: Projection.empty_contributors(),
      reconciliation: %{reconciled?: true, by_dimension: %{}},
      tier_join_keys: [],
      coverage: Coverage.empty_coverage()
    }
  end

  @doc false
  @spec token_dimensions() :: [atom()]
  def token_dimensions, do: Key.token_dimensions()
end
