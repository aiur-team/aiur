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

  Every measure is preserved across the contributor dimensions (provider, run,
  ticket, agent family, backend, exact resolved model, auth mode, account
  generation, currency, occurrence-price partition/revision, and
  token-relationship revision) and rolled up into one exact compatible-currency
  API-equivalent total per currency that reconciles, in both directions, to its
  preserved contributors. Unlike monetary bases and unlike currencies never
  combine, and unknown or contradictory pricing can never become a zero total.

  ## Exactness boundary

  API-equivalent pricing is linear in token count, so re-pricing a pre-summed
  aggregate cell is exact whenever the cell's full price-lookup key is known.
  DASH-024 does not retain codex `context_tier` or claude
  `cache_write_duration`; those token dimensions are reported as explicit
  unknown API-equivalent coverage rather than priced at a guessed partition (see
  `Aiur.Usage.GroupedScopes.PriceAdapter`).
  """

  alias Aiur.Usage.GroupedScopes.{PriceAdapter, Scope}
  alias Aiur.Usage.PriceTable
  alias Aiur.UsageAggregate.Key

  @schema_version 1
  @default_currency "USD"
  @default_page_limit 50
  @max_page_limit 500

  @dims_dimensions %{
    by_provider: :provider,
    by_run: :run_id,
    by_ticket: :ticket,
    by_agent_family: :agent_family,
    by_backend: :backend,
    by_model: :resolved_model,
    by_auth_mode: :auth_mode,
    by_account_generation: :account_generation,
    by_relationship_revision: :relationship_revision,
    by_pricing_date: :pricing_date
  }

  @type source :: %{required(:cells) => map(), required(:metadata) => map()} | nil

  @doc """
  Projects `source` restricted to `scope` into an immutable grouped snapshot.

  Options:

    * `:currency` — requested API-equivalent currency (default `"USD"`).
    * `:price_table` — a `Aiur.Usage.PriceTable` catalog (default
      `PriceTable.default/0`). Passing it in keeps the layer pure and lets the
      caller pin the pricing authority in its cache key.
  """
  @spec project(source(), Scope.t(), keyword()) :: map()
  def project(source, %Scope{} = scope, opts \\ []) do
    currency = Keyword.get(opts, :currency, @default_currency)

    case resolve_price_table(opts) do
      {:ok, price_table} -> do_project(source, scope, currency, price_table)
      {:error, reason} -> unavailable(scope, currency, {:price_table, reason})
    end
  end

  defp resolve_price_table(opts) do
    case Keyword.fetch(opts, :price_table) do
      {:ok, catalog} -> {:ok, catalog}
      :error -> PriceTable.default()
    end
  end

  defp do_project(source, scope, currency, price_table) do
    case validate_source(source) do
      {:error, reason} ->
        unavailable(scope, currency, reason)

      {:ok, cells, metadata} ->
        selected = select(cells, scope)
        token_entries = token_entries(selected, currency, price_table)
        money_entries = money_entries(selected)
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

  defp token_entries(selected, currency, price_table) do
    for {{dims, {:token, dimension}}, count} <- selected do
      %{dims: dims, dimension: dimension, count: count, priced: price(dims, dimension, count, currency, price_table)}
    end
  end

  defp price(dims, dimension, count, currency, price_table) do
    if PriceAdapter.priced_dimension?(dimension) do
      PriceAdapter.price(dims, dimension, count, currency, price_table)
    else
      :excluded
    end
  end

  defp money_entries(selected) do
    for {{dims, {:money, basis, currency}}, amount} <- selected do
      %{dims: dims, basis: basis, currency: currency, amount: amount}
    end
  end

  # --- snapshot assembly --------------------------------------------------

  defp build_snapshot(scope, currency, price_table, metadata, selected, token_entries, money_entries) do
    totals = totals(token_entries, money_entries)
    contributors = contributors(token_entries, money_entries, totals)
    reconciliation = reconciliation(totals, contributors)
    coverage = coverage(selected, token_entries, metadata, totals)

    %{
      schema_version: @schema_version,
      scope: Scope.public(scope),
      currency: currency,
      state: state(metadata, selected, coverage),
      authority: authority(metadata, price_table),
      health: Map.get(metadata, :health),
      freshness: Map.get(metadata, :freshness),
      retained_interval: retained_interval(metadata),
      tokens: totals.tokens,
      provider_reported_estimate: %{by_currency: totals.provider_reported},
      api_equivalent_estimate: %{
        rollup: totals.api_amount,
        coverage: totals.api_coverage
      },
      contributors: contributors,
      reconciliation: reconciliation,
      tier_join_keys: tier_join_keys(selected),
      coverage: coverage
    }
  end

  # --- totals & buckets ---------------------------------------------------

  defp empty_acc do
    %{tokens: %{}, provider_reported: %{}, api_amount: %{}, api_known: 0, api_unknown: 0, api_reasons: MapSet.new()}
  end

  defp totals(token_entries, money_entries) do
    empty_acc()
    |> then(fn acc -> Enum.reduce(token_entries, acc, &add_token(&2, &1)) end)
    |> then(fn acc -> Enum.reduce(money_entries, acc, &add_money(&2, &1)) end)
    |> finalize()
  end

  defp add_token(acc, %{dimension: dimension, count: count, priced: priced}) do
    acc = update_in(acc.tokens, &Map.update(&1, dimension, count, fn v -> v + count end))
    apply_price(acc, priced)
  end

  defp apply_price(acc, {:ok, %{amount: amount, currency: currency}}) do
    acc
    |> update_in([:api_amount], &Map.update(&1, currency, amount, fn v -> Decimal.add(v, amount) end))
    |> Map.update!(:api_known, &(&1 + 1))
  end

  defp apply_price(acc, {:unknown, reason}) do
    acc
    |> Map.update!(:api_unknown, &(&1 + 1))
    |> Map.update!(:api_reasons, &MapSet.put(&1, reason))
  end

  defp apply_price(acc, :excluded), do: acc

  defp add_money(acc, %{currency: currency, amount: amount}) do
    update_in(acc.provider_reported, &Map.update(&1, currency, amount, fn v -> Decimal.add(v, amount) end))
  end

  defp finalize(acc) do
    %{
      tokens: acc.tokens,
      provider_reported: acc.provider_reported,
      api_amount: acc.api_amount,
      api_coverage: %{
        known: acc.api_known,
        unknown: acc.api_unknown,
        reasons: acc.api_reasons |> MapSet.to_list() |> Enum.sort(),
        status: coverage_status(acc.api_known, acc.api_unknown)
      }
    }
  end

  defp coverage_status(0, 0), do: :none
  defp coverage_status(_known, 0), do: :known
  defp coverage_status(0, _unknown), do: :unknown
  defp coverage_status(_known, _unknown), do: :partial

  # --- contributors -------------------------------------------------------

  defp contributors(token_entries, money_entries, totals) do
    dims_buckets =
      Map.new(@dims_dimensions, fn {label, dimension} ->
        {label, bucket(token_entries, money_entries, &Map.fetch!(&1.dims, dimension), &Map.fetch!(&1.dims, dimension))}
      end)

    dims_buckets
    |> Map.put(:by_price_partition, bucket(token_entries, [], &price_partition/1, &skip/1))
    |> Map.put(:by_currency, by_currency(money_entries, totals.api_amount))
  end

  defp price_partition(%{priced: {:ok, %{price_revision: revision}}}), do: revision
  defp price_partition(%{priced: {:unknown, _reason}}), do: :unknown
  defp price_partition(%{priced: :excluded}), do: :skip

  defp skip(_entry), do: :skip

  # Monetary-only view: provider-reported money keyed by its own currency, plus
  # the known API-equivalent amounts keyed by their (requested) currency. Token
  # counts are not a per-currency measure and never enter this dimension.
  defp by_currency(money_entries, api_amount) do
    money_entries
    |> Enum.reduce(%{}, fn entry, acc ->
      Map.update(acc, entry.currency, add_money(empty_acc(), entry), &add_money(&1, entry))
    end)
    |> then(fn acc ->
      Enum.reduce(api_amount, acc, fn {currency, amount}, acc ->
        Map.update(acc, currency, %{empty_acc() | api_amount: %{currency => amount}}, fn bucket ->
          %{bucket | api_amount: Map.update(bucket.api_amount, currency, amount, &Decimal.add(&1, amount))}
        end)
      end)
    end)
    |> Enum.map(fn {key, acc} -> present(key, finalize(acc)) end)
    |> Enum.sort_by(&sort_key(&1.key))
  end

  defp bucket(token_entries, money_entries, token_key, money_key) do
    %{}
    |> then(fn acc -> Enum.reduce(token_entries, acc, &accumulate(&2, token_key.(&1), :token, &1)) end)
    |> then(fn acc -> Enum.reduce(money_entries, acc, &accumulate(&2, money_key.(&1), :money, &1)) end)
    |> Enum.map(fn {key, acc} -> present(key, finalize(acc)) end)
    |> Enum.sort_by(&sort_key(&1.key))
  end

  defp present(key, finalized) do
    %{
      key: key,
      tokens: finalized.tokens,
      provider_reported: finalized.provider_reported,
      api_equivalent: %{amount: finalized.api_amount, coverage: finalized.api_coverage}
    }
  end

  defp accumulate(acc, :skip, _kind, _entry), do: acc

  defp accumulate(acc, key, :token, entry) do
    Map.update(acc, key, add_token(empty_acc(), entry), &add_token(&1, entry))
  end

  defp accumulate(acc, key, :money, entry) do
    Map.update(acc, key, add_money(empty_acc(), entry), &add_money(&1, entry))
  end

  # Canonical, restart-stable ordering across the mixed key types a dimension
  # can carry (atoms, strings, tuples, dates, nil).
  defp sort_key(key), do: :erlang.term_to_binary(key)

  # --- reconciliation -----------------------------------------------------

  # Each dimension reconciles exactly the measures it structurally carries: the
  # identity dimensions carry all three, `by_price_partition` carries only the
  # API-equivalent money (it excludes provider-reported money and the
  # unpriced provider-reported-total token), and `by_currency` carries only the
  # monetary bases (token counts are not a per-currency measure).
  @reconciliation_measures %{
    by_price_partition: [:api],
    by_currency: [:provider_reported, :api]
  }

  defp reconciliation(totals, contributors) do
    by_dimension =
      Map.new(contributors, fn {label, entries} ->
        {label, reconciles?(totals, entries, Map.get(@reconciliation_measures, label, [:tokens, :provider_reported, :api]))}
      end)

    %{reconciled?: Enum.all?(by_dimension, fn {_label, ok?} -> ok? end), by_dimension: by_dimension}
  end

  defp reconciles?(totals, entries, measures) do
    summed = Enum.reduce(entries, %{tokens: %{}, provider_reported: %{}, api_amount: %{}}, &sum_entry/2)

    Enum.all?(measures, fn
      :tokens -> summed.tokens == totals.tokens
      :provider_reported -> normalize_money(summed.provider_reported) == normalize_money(totals.provider_reported)
      :api -> normalize_money(summed.api_amount) == normalize_money(totals.api_amount)
    end)
  end

  defp sum_entry(entry, summed) do
    %{
      tokens: Map.merge(summed.tokens, entry.tokens, fn _dimension, a, b -> a + b end),
      provider_reported: merge_money(summed.provider_reported, entry.provider_reported),
      api_amount: merge_money(summed.api_amount, entry.api_equivalent.amount)
    }
  end

  defp merge_money(left, right), do: Map.merge(left, right, fn _currency, a, b -> Decimal.add(a, b) end)

  defp normalize_money(money), do: Map.new(money, fn {key, amount} -> {key, Decimal.to_string(amount, :normal)} end)

  # --- tier join keys -----------------------------------------------------

  defp tier_join_keys(selected) do
    selected
    |> Enum.map(fn {{dims, _measure}, _value} -> dims end)
    |> Enum.filter(&exact_tier_group?/1)
    |> Enum.map(&%{provider: &1.provider, backend: &1.backend, account_generation: &1.account_generation})
    |> Enum.uniq()
    |> Enum.sort_by(&sort_key({&1.provider, &1.backend, &1.account_generation}))
  end

  defp exact_tier_group?(%{backend: :unknown}), do: false
  defp exact_tier_group?(%{account_generation: nil}), do: false
  defp exact_tier_group?(_dims), do: true

  # --- coverage & state ---------------------------------------------------

  defp coverage(selected, token_entries, metadata, totals) do
    %{
      selected_cells: length(selected),
      api_equivalent: totals.api_coverage,
      unknown_attribution: unknown_attribution(selected),
      unknown_pricing_tokens: unknown_pricing_tokens(token_entries),
      projection: projection_coverage(metadata),
      source: Map.get(metadata, :source_coverage, %{})
    }
  end

  defp unknown_attribution(selected) do
    Enum.reduce(selected, %{run_id: 0, ticket: 0, account_generation: 0, resolved_model: 0, pricing_date: 0}, fn
      {{dims, _measure}, _value}, acc ->
        acc
        |> bump(:run_id, is_nil(dims.run_id))
        |> bump(:ticket, dims.ticket == :unknown)
        |> bump(:account_generation, is_nil(dims.account_generation))
        |> bump(:resolved_model, is_nil(dims.resolved_model))
        |> bump(:pricing_date, is_nil(dims.pricing_date))
    end)
  end

  defp unknown_pricing_tokens(token_entries) do
    token_entries
    |> Enum.filter(&match?({:unknown, _reason}, &1.priced))
    |> Enum.reduce(%{}, fn %{priced: {:unknown, reason}, count: count}, acc ->
      Map.update(acc, reason, count, &(&1 + count))
    end)
  end

  defp projection_coverage(metadata) do
    coverage = Map.get(metadata, :coverage, %{})

    %{
      folded_records: Map.get(coverage, :folded_records, 0),
      partial_records: Map.get(coverage, :partial_records, 0),
      reasons: coverage |> Map.get(:reasons, []) |> normalize_reasons()
    }
  end

  defp normalize_reasons(%MapSet{} = reasons), do: reasons |> MapSet.to_list() |> Enum.sort()
  defp normalize_reasons(reasons) when is_list(reasons), do: Enum.sort(reasons)
  defp normalize_reasons(_reasons), do: []

  defp bump(acc, key, true), do: Map.update!(acc, key, &(&1 + 1))
  defp bump(acc, _key, false), do: acc

  defp retained_interval(metadata) do
    case Map.get(metadata, :source_coverage) do
      %{lower: lower, upper: upper} = coverage ->
        %{earliest: lower, latest: upper, status: Map.get(coverage, :status, :unknown)}

      _missing ->
        %{earliest: nil, latest: nil, status: :missing}
    end
  end

  defp state(metadata, selected, coverage) do
    cond do
      match?({:unavailable, _reason}, Map.get(metadata, :health)) -> :unavailable
      Map.get(metadata, :freshness, %{})[:status] == :unavailable -> :unavailable
      match?({:degraded, _reason}, Map.get(metadata, :health)) -> :partial
      Map.get(metadata, :freshness, %{})[:status] == :stale -> :stale
      selected == [] -> :known_empty
      partial_coverage?(coverage) -> :partial
      true -> :ok
    end
  end

  defp partial_coverage?(coverage) do
    coverage.api_equivalent.status in [:partial, :unknown] or
      coverage.projection.partial_records > 0 or
      Enum.any?(Map.values(coverage.unknown_attribution), &(&1 > 0)) or
      Map.get(coverage.source, :status, :full) != :full
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
      contributors: empty_contributors(),
      reconciliation: %{reconciled?: true, by_dimension: %{}},
      tier_join_keys: [],
      coverage: %{selected_cells: 0}
    }
  end

  defp empty_contributors do
    labels = Map.keys(@dims_dimensions) ++ [:by_price_partition, :by_currency]
    Map.new(labels, fn label -> {label, []} end)
  end

  @doc false
  @spec token_dimensions() :: [atom()]
  def token_dimensions, do: Key.token_dimensions()
end
