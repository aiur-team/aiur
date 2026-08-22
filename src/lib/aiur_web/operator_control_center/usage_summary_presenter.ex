defmodule AiurWeb.OperatorControlCenter.UsageSummaryPresenter do
  @moduledoc """
  Formats the DASH-030 `Aiur.Usage.GroupedScopes` grouped snapshot into a named,
  screen-reader-friendly authenticated usage and cost view (DASH-031).

  This presenter performs no aggregate math and no pricing: every token count,
  monetary estimate, coverage fact, reconciliation flag, and tier join comes
  straight from the daemon-owned grouped snapshot (and, for tier, from the
  protected provider-meter facts the caller supplies). It only formats and names
  those facts and keeps the distinct states (locked, loading, empty, partial,
  stale, unavailable, ready) and the distinct monetary bases (provider-reported
  estimate vs API-equivalent estimate) visibly separate. It also exposes a
  ranked `models` view (`view.models`) for the tokens-by-model chart and a
  structured `routes` view (`view.routes`) for cost-by-provider-route rows.
  Model totals use additive, non-overlapping token dimensions per model and are
  capped with an `Other` tail.

  ## Truthfulness invariants

    * Provider-reported and API-equivalent estimates are always separate and are
      never labelled billed or actual spend.
    * A currency total reconciles to its preserved contributors; the presenter
      surfaces `reconciliation.reconciled?` rather than recomputing it.
    * Subscription API-equivalent dollars are marked (`*`) and carry a disclosure
      explaining the token-price lookup basis and that the flat subscription fee
      is not allocated.
    * A tier is joined only on an exact known `(provider, backend, generation)`;
      unknown, mixed, and mismatched generations remain unjoined and a combined
      total never receives a synthetic cross-provider tier.
    * Unknown cost is named unknown, never `$0.00`; a degraded scope keeps its
      qualified last-known-good and is never reset to zero.

  ## Last-known-good retention

  `reconcile/2` decides which snapshot to display, mirroring
  `RunSummaryPresenter`: an available incoming snapshot is adopted; an
  unavailable incoming snapshot retains a healthy same-scope current snapshot
  labelled stale rather than presenting zeros.
  """

  alias Aiur.{CodingAgent, Usage.GroupedScopes}

  @type snapshot :: map()
  @type view :: map()
  @type tier_facts :: %{optional({atom(), atom(), String.t()}) => map()}

  @available_states [:ok, :partial, :stale, :known_empty]

  @doc "The value-free view a denied connection renders. Carries no protected fact."
  @spec locked_view(map()) :: view()
  def locked_view(capability \\ %{}) do
    %{
      state: :locked,
      accessible_name: Map.get(capability, :accessible_name, "Financial data locked"),
      reason: Map.get(capability, :reason, "Authentication is required to access financial data."),
      authentication_path: Map.get(capability, :authentication_path, "Sign in with the configured dashboard credentials.")
    }
  end

  @doc """
  Given the snapshot currently displayed (`current`, may be `nil`) and an
  `incoming` snapshot, return `{source, retained?}` where `source` is the
  snapshot to present and `retained?` is true when `source` is a stale
  last-known-good retained across an unavailable update.
  """
  @spec reconcile(snapshot() | nil, snapshot() | nil) :: {snapshot() | nil, boolean()}
  def reconcile(current, incoming) when is_map(incoming) do
    cond do
      available?(incoming) -> {incoming, false}
      is_map(current) and available?(current) and same_scope?(current, incoming) -> {current, true}
      true -> {incoming, false}
    end
  end

  def reconcile(current, _incoming), do: {current, false}

  @doc """
  Present `source` (may be `nil` for loading) as a named view.

  Options:

    * `:retained?` — mark `source` as a stale last-known-good (default `false`).
    * `:status_source` — when retained, the incoming unavailable snapshot whose
      health/freshness describe the failed refresh (values still come from
      `source`).
    * `:tier_facts` — a `%{{provider, backend, generation} => plan}` map of
      protected provider-meter plan facts to join exactly. Defaults to `%{}`, in
      which case every generation renders explicitly unjoined.
  """
  @spec present(snapshot() | nil, keyword()) :: view()
  def present(source, opts \\ [])

  def present(source, opts) when is_map(source) do
    retained? = Keyword.get(opts, :retained?, false)
    status_source = Keyword.get(opts, :status_source) || source
    tier_facts = Keyword.get(opts, :tier_facts, %{})

    subscription_currencies = subscription_currencies(source)

    %{
      state: state(source, retained?),
      retained?: retained?,
      currency: Map.get(source, :currency),
      scope: present_scope(Map.get(source, :scope, %{})),
      tokens: present_tokens(Map.get(source, :tokens, %{})),
      models: present_models(get_in(source, [:contributors, :by_model]) || []),
      routes: present_routes(get_in(source, [:contributors, :by_provider_route]) || [], subscription_currencies),
      providers: present_providers(get_in(source, [:contributors, :by_provider]) || [], subscription_currencies),
      api_equivalent: present_api_equivalent(Map.get(source, :api_equivalent_estimate, %{}), subscription_currencies),
      provider_reported: present_provider_reported(Map.get(source, :provider_reported_estimate, %{})),
      disclosure: disclosure(subscription_currencies),
      tier: present_tier(Map.get(source, :tier_join_keys, []), tier_facts),
      coverage: present_coverage(Map.get(source, :coverage, %{})),
      retained_interval: present_retained_interval(Map.get(source, :retained_interval, %{})),
      reconciliation: present_reconciliation(Map.get(source, :reconciliation, %{})),
      health: present_health(Map.get(status_source, :health)),
      freshness: present_freshness(Map.get(status_source, :freshness))
    }
  end

  def present(_source, _opts), do: %{state: :loading, retained?: false}

  @doc """
  A bounded page of one contributor dimension formatted for accessible
  drill-down. Delegates the server-bounded paging to
  `Aiur.Usage.GroupedScopes.drill_down/3` and names each entry.
  """
  @spec drill_down(snapshot(), atom(), keyword()) :: map()
  def drill_down(source, dimension, opts \\ [])

  def drill_down(source, dimension, opts) when is_map(source) do
    subscription_currencies = subscription_currencies(source)
    page = GroupedScopes.drill_down(source, dimension, opts)

    %{
      dimension: dimension,
      label: dimension_label(dimension),
      total: page.total,
      cursor: page.cursor,
      limit: page.limit,
      next_cursor: page.next_cursor,
      has_more: page.has_more,
      items: Enum.map(page.items, &present_contributor(&1, dimension, subscription_currencies))
    }
  end

  def drill_down(_source, dimension, _opts) do
    %{dimension: dimension, label: dimension_label(dimension), total: 0, cursor: 0, limit: 0, next_cursor: nil, has_more: false, items: []}
  end

  @doc "A single bounded screen-reader announcement summarising the presented `view`."
  @spec announcement(view()) :: String.t()
  def announcement(%{state: :locked}), do: "Usage and cost summary is locked. Authentication is required."
  def announcement(%{state: :loading}), do: "Loading the authenticated usage and cost summary."
  def announcement(%{state: :empty}), do: "No usage has been recorded for this scope."

  def announcement(%{state: :unavailable}), do: "Usage and cost summary is unavailable."

  def announcement(%{state: state} = view) when state in [:ready, :partial, :stale] do
    [
      scope_sentence(state, view),
      tokens_sentence(view.tokens),
      routes_sentence(view.routes),
      api_equivalent_sentence(view.api_equivalent),
      provider_reported_sentence(view.provider_reported),
      tier_sentence(view.tier),
      coverage_sentence(view.coverage),
      "Health #{view.health.label}, freshness #{view.freshness.label}."
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  def announcement(_view), do: "Usage and cost summary is unavailable."

  # --- state ---------------------------------------------------------------

  defp state(_source, true), do: :stale

  defp state(source, false) do
    case Map.get(source, :state) do
      :unavailable -> :unavailable
      :stale -> :stale
      :partial -> :partial
      :known_empty -> :empty
      :ok -> :ready
      _other -> :unavailable
    end
  end

  # --- scope ---------------------------------------------------------------

  defp present_scope(scope) do
    %{
      kind: Map.get(scope, :kind, :this_run),
      run_id: Map.get(scope, :run_id),
      status: Map.get(scope, :status, :empty),
      ticket_count: scope |> Map.get(:tickets, []) |> length(),
      rejected_tickets: Map.get(scope, :rejected_tickets, 0),
      label: scope_label(Map.get(scope, :kind, :this_run))
    }
  end

  defp scope_label(:this_run), do: "This run"
  defp scope_label(:explicit_ticket_set), do: "Selected build"
  defp scope_label(:intersection), do: "This run and selected build"
  defp scope_label(_kind), do: "Scope unknown"

  # --- tokens --------------------------------------------------------------

  defp present_tokens(tokens) when is_map(tokens) do
    entries =
      tokens
      |> Enum.map(fn {dimension, count} -> %{dimension: dimension, label: token_label(dimension), count: count} end)
      |> Enum.sort_by(& &1.dimension)

    %{entries: entries, total: entries |> Enum.map(& &1.count) |> Enum.sum(), any?: entries != []}
  end

  defp present_tokens(_tokens), do: %{entries: [], total: 0, any?: false}

  defp present_providers(entries, subscription_currencies) when is_list(entries) do
    Map.new(entries, fn entry ->
      provider = Map.get(entry, :key)
      {provider, present_contributor(entry, :by_provider, subscription_currencies)}
    end)
  end

  defp present_providers(_entries, _subscription_currencies), do: %{}

  defp token_label(dimension) do
    dimension |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  # --- models (tokens-by-model chart) ---------------------------------------

  # The additive, non-overlapping token dimensions, in stack order.
  # `reasoning_output` is a subset of `output` and `provider_reported_total` is
  # the provider's own (non-additive) total, so neither is stacked; stacking
  # them would double count against the other segments.
  @chart_dimensions [:cached_input, :cache_creation_input, :input, :output]
  @max_chart_models 8

  # One ranked bar per model (capped at `@max_chart_models` with the long tail
  # folded into an `Other` bar), each stacking the additive token dimensions.
  defp present_models(entries) when is_list(entries) do
    models =
      entries
      |> Enum.map(&present_model/1)
      |> Enum.reject(&(&1.total == 0))
      |> Enum.sort_by(& &1.total, :desc)

    {shown, rest} = Enum.split(models, @max_chart_models)
    shown = if rest == [], do: shown, else: shown ++ [aggregate_model(rest)]

    %{entries: shown, any?: shown != []}
  end

  defp present_models(_entries), do: %{entries: [], any?: false}

  defp present_model(entry) do
    tokens = Map.get(entry, :tokens, %{})

    segments =
      @chart_dimensions
      |> Enum.flat_map(fn dimension ->
        case Map.get(tokens, dimension) do
          count when is_integer(count) and count > 0 ->
            [%{dimension: dimension, label: token_label(dimension), count: count}]

          _absent ->
            []
        end
      end)

    %{
      label: model_label(Map.get(entry, :key)),
      total: Enum.reduce(segments, 0, &(&1.count + &2)),
      segments: segments
    }
  end

  # Fold the ranked remainder past the chart cap into a single `Other` bar so a
  # long tail of models never disappears from the totals.
  defp aggregate_model(models) do
    segments =
      @chart_dimensions
      |> Enum.map(&dimension_segment(&1, models))
      |> Enum.reject(&(&1.count == 0))

    %{label: "Other", total: Enum.reduce(segments, 0, &(&1.count + &2)), segments: segments}
  end

  defp dimension_segment(dimension, models) do
    count = Enum.reduce(models, 0, &(&2 + segment_count(&1.segments, dimension)))

    %{dimension: dimension, label: token_label(dimension), count: count}
  end

  defp segment_count(segments, dimension) do
    case Enum.find(segments, &(&1.dimension == dimension)) do
      nil -> 0
      segment -> segment.count
    end
  end

  defp model_label(nil), do: "Unknown"
  defp model_label(:unknown), do: "Unknown"
  defp model_label(label) when is_binary(label), do: label
  defp model_label(label), do: to_string(label)

  # --- provider routes -----------------------------------------------------

  defp present_routes(entries, subscription_currencies) when is_list(entries) do
    presented = Enum.map(entries, &present_route(&1, subscription_currencies))
    %{entries: presented, any?: presented != []}
  end

  defp present_routes(_entries, _subscription_currencies), do: %{entries: [], any?: false}

  defp present_route(entry, subscription_currencies) do
    key = Map.get(entry, :key, %{})
    provider = Map.get(key, :provider)
    upstream_provider = Map.get(key, :upstream_provider)
    provider_reported = money_by_currency(Map.get(entry, :provider_reported, %{}), subscription_currencies, false)
    api_equivalent = money_by_currency(get_in(entry, [:api_equivalent, :amount]) || %{}, subscription_currencies, true)
    {label, accessible_label} = provider_route_labels(provider, upstream_provider)

    %{
      key: key,
      provider: provider,
      upstream_provider: upstream_provider,
      label: label,
      accessible_label: accessible_label,
      tokens: present_tokens(Map.get(entry, :tokens, %{})),
      provider_reported: provider_reported,
      provider_reported_label: money_label(provider_reported),
      api_equivalent: api_equivalent,
      api_equivalent_label: money_label(api_equivalent)
    }
  end

  defp provider_route_labels(provider, upstream_provider) when is_binary(upstream_provider) do
    provider = provider_label(provider)
    {"#{provider} -> #{upstream_provider}", "#{provider} routed through #{upstream_provider}"}
  end

  defp provider_route_labels(provider, nil) when provider in [:openrouter, "openrouter"] do
    {"OpenRouter -> upstream unknown", "OpenRouter routed through upstream provider unknown"}
  end

  defp provider_route_labels(provider, _upstream_provider) do
    provider = provider_label(provider)
    {provider, provider}
  end

  defp provider_label(provider) when is_atom(provider) or is_binary(provider) do
    case CodingAgent.provider_descriptor(provider) do
      %{label: label} -> label
      _unknown -> fallback_provider_label(provider)
    end
  end

  defp provider_label(_provider), do: "Unknown"

  defp fallback_provider_label(provider) when is_atom(provider) do
    provider
    |> to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp fallback_provider_label(provider) when is_binary(provider), do: provider

  defp money_label([]), do: "Unknown"

  defp money_label(entries) do
    Enum.map_join(entries, " + ", fn entry ->
      marker = if entry.subscription_marked?, do: "*", else: ""
      "#{entry.amount} #{entry.currency}#{marker}"
    end)
  end

  # --- API-equivalent estimate ---------------------------------------------

  # One exact API-equivalent total per compatible currency. A currency whose
  # total includes subscription-basis usage carries the `*` disclosure marker.
  defp present_api_equivalent(estimate, subscription_currencies) do
    by_currency =
      estimate
      |> Map.get(:rollup, %{})
      |> Enum.map(fn {currency, amount} ->
        %{
          currency: currency,
          amount: format_amount(amount),
          subscription_marked?: MapSet.member?(subscription_currencies, currency)
        }
      end)
      |> Enum.sort_by(& &1.currency)

    %{
      estimate?: true,
      by_currency: by_currency,
      any?: by_currency != [],
      coverage: present_money_coverage(Map.get(estimate, :coverage, %{}))
    }
  end

  # --- provider-reported estimate ------------------------------------------

  defp present_provider_reported(estimate) do
    by_currency =
      estimate
      |> Map.get(:by_currency, %{})
      |> Enum.map(fn {currency, amount} -> %{currency: currency, amount: format_amount(amount)} end)
      |> Enum.sort_by(& &1.currency)

    %{estimate?: true, by_currency: by_currency, any?: by_currency != []}
  end

  # --- disclosure ----------------------------------------------------------

  defp disclosure(subscription_currencies) do
    %{
      required?: MapSet.size(subscription_currencies) > 0,
      marker: "*",
      title: "About subscription API-equivalent estimates",
      body:
        "Subscription usage is shown as an API-equivalent estimate: each retained token count is " <>
          "priced at the exact published per-token API rate. It is not billed spend, and your flat " <>
          "subscription fee is not allocated across this usage."
    }
  end

  # --- tier join -----------------------------------------------------------

  # Join actual plan/tier only on an exact known (provider, backend, generation).
  # Unknown, mixed, and mismatched generations remain unjoined, and a combined
  # total never receives a synthetic cross-provider tier.
  defp present_tier(join_keys, tier_facts) when is_list(join_keys) do
    entries = Enum.map(join_keys, &tier_entry(&1, tier_facts))

    %{
      entries: entries,
      joined_count: Enum.count(entries, &(&1.status == :joined)),
      unjoined_count: Enum.count(entries, &(&1.status == :unjoined)),
      # A combined total is never assigned a tier; each exact generation carries
      # its own.
      combined_tier: :none,
      note: tier_note(entries)
    }
  end

  defp present_tier(_join_keys, _tier_facts), do: %{entries: [], joined_count: 0, unjoined_count: 0, combined_tier: :none, note: ""}

  defp tier_entry(%{provider: provider, backend: backend, account_generation: generation}, tier_facts) do
    case Map.get(tier_facts, {provider, backend, generation}) do
      %{tier: tier} = plan when tier not in [nil, :unknown] ->
        %{
          provider: provider,
          backend: backend,
          generation: generation,
          status: :joined,
          tier: tier,
          tier_label: tier_label(tier),
          plan_source: Map.get(plan, :source),
          plan_freshness: Map.get(plan, :freshness)
        }

      _unjoinable ->
        %{
          provider: provider,
          backend: backend,
          generation: generation,
          status: :unjoined,
          tier: nil,
          tier_label: "Tier unavailable for this generation"
        }
    end
  end

  defp tier_label(:free), do: "Free"
  defp tier_label(:pro), do: "Pro"
  defp tier_label(:team), do: "Team"
  defp tier_label(:business), do: "Business"
  defp tier_label(:enterprise), do: "Enterprise"
  defp tier_label(_tier), do: "Unknown"

  defp tier_note([]), do: "No account generation in scope."

  defp tier_note(entries) do
    joined = Enum.count(entries, &(&1.status == :joined))

    cond do
      joined == 0 -> "No exact tier available; generations are unknown or unjoined."
      joined == 1 and length(entries) == 1 -> "Exact tier shown for the single account generation in scope."
      true -> "Exact tier shown per generation; the combined total is not assigned a single tier."
    end
  end

  # --- coverage ------------------------------------------------------------

  # Source coverage is surfaced separately from the totals so missing or partial
  # source coverage can never read as zero usage.
  defp present_coverage(coverage) do
    source = Map.get(coverage, :source, %{})
    unknown = Map.get(coverage, :unknown_attribution, %{})

    %{
      source_status: Map.get(source, :status, :unknown),
      source_label: coverage_status_label(Map.get(source, :status, :unknown)),
      api_equivalent: present_money_coverage(Map.get(coverage, :api_equivalent, %{})),
      unknown_pricing_tokens: Map.get(coverage, :unknown_pricing_tokens, %{}),
      projection: Map.get(coverage, :projection, %{folded_records: 0, partial_records: 0, reasons: []}),
      unknown_attribution: unknown,
      unknown_contributors?: Enum.any?(Map.values(unknown), &(is_integer(&1) and &1 > 0)),
      selected_cells: Map.get(coverage, :selected_cells, 0)
    }
  end

  defp present_money_coverage(coverage) do
    status = Map.get(coverage, :status, :none)

    %{
      status: status,
      label: money_coverage_label(status),
      known: Map.get(coverage, :known, 0),
      unknown: Map.get(coverage, :unknown, 0),
      reasons: Map.get(coverage, :reasons, [])
    }
  end

  defp money_coverage_label(:known), do: "Complete"
  defp money_coverage_label(:partial), do: "Partial — some tokens are unpriced"
  defp money_coverage_label(:unknown), do: "Unknown — no tokens could be priced"
  defp money_coverage_label(:none), do: "No priceable tokens in scope"
  defp money_coverage_label(_status), do: "Unknown"

  defp coverage_status_label(:full), do: "Full"
  defp coverage_status_label(:partial), do: "Partial"
  defp coverage_status_label(:empty), do: "Empty"
  defp coverage_status_label(_status), do: "Unknown"

  # --- retained interval ---------------------------------------------------

  defp present_retained_interval(interval) do
    %{
      earliest: Map.get(interval, :earliest),
      latest: Map.get(interval, :latest),
      status: Map.get(interval, :status, :missing),
      label: retained_interval_label(Map.get(interval, :status, :missing))
    }
  end

  defp retained_interval_label(:full), do: "Full period covered"
  defp retained_interval_label(:partial), do: "Part of the period covered"
  defp retained_interval_label(:missing), do: "Period coverage unavailable"
  defp retained_interval_label(_status), do: "Period coverage unknown"

  # --- reconciliation ------------------------------------------------------

  defp present_reconciliation(reconciliation) do
    %{
      reconciled?: Map.get(reconciliation, :reconciled?, false),
      by_dimension: Map.get(reconciliation, :by_dimension, %{})
    }
  end

  # --- health / freshness --------------------------------------------------

  # Health arrives as `:healthy`, `{:degraded, reason}`, `{:unavailable, reason}`,
  # or nil across the ledger/aggregate layers; name each without inferring.
  defp present_health(:healthy), do: %{status: :healthy, reason: nil, label: "Healthy"}
  defp present_health({:degraded, reason}), do: %{status: :degraded, reason: reason, label: "Degraded"}
  defp present_health({:unavailable, reason}), do: %{status: :unavailable, reason: reason, label: "Unavailable"}
  defp present_health(_health), do: %{status: :unknown, reason: nil, label: "Unknown"}

  defp present_freshness(%{status: status}), do: %{status: status, label: freshness_label(status)}
  defp present_freshness(_freshness), do: %{status: :unknown, label: "Unknown"}

  defp freshness_label(:fresh), do: "Fresh"
  defp freshness_label(:partial), do: "Partial"
  defp freshness_label(:stale), do: "Healthy"
  defp freshness_label(:empty), do: "Empty"
  defp freshness_label(:unavailable), do: "Unavailable"
  defp freshness_label(_status), do: "Unknown"

  # --- contributors (drill-down) -------------------------------------------

  defp present_contributor(entry, dimension, subscription_currencies) do
    %{
      key: Map.get(entry, :key),
      key_label: contributor_key_label(dimension, Map.get(entry, :key)),
      tokens: present_tokens(Map.get(entry, :tokens, %{})),
      provider_reported: money_by_currency(Map.get(entry, :provider_reported, %{}), subscription_currencies, false),
      api_equivalent: money_by_currency(get_in(entry, [:api_equivalent, :amount]) || %{}, subscription_currencies, true)
    }
  end

  defp money_by_currency(amounts, subscription_currencies, mark_subscription?) do
    amounts
    |> Enum.map(fn {currency, amount} ->
      %{
        currency: currency,
        amount: format_amount(amount),
        subscription_marked?: mark_subscription? and MapSet.member?(subscription_currencies, currency)
      }
    end)
    |> Enum.sort_by(& &1.currency)
  end

  defp contributor_key_label(_dimension, nil), do: "Unknown"
  defp contributor_key_label(:by_ticket, :unknown), do: "Unknown ticket"
  defp contributor_key_label(_dimension, :unknown), do: "Unknown"
  defp contributor_key_label(_dimension, key) when is_atom(key), do: key |> to_string() |> String.replace("_", " ")
  defp contributor_key_label(_dimension, key) when is_binary(key), do: key

  defp contributor_key_label(_dimension, {owner, repo, number}) when is_binary(owner),
    do: "#{owner}/#{repo}##{number}"

  defp contributor_key_label(_dimension, key), do: inspect(key)

  @dimension_labels %{
    by_provider: "Provider",
    by_run: "Run",
    by_ticket: "Ticket",
    by_agent_family: "Agent family",
    by_backend: "Backend",
    by_model: "Model",
    by_auth_mode: "Authentication mode",
    by_account_generation: "Account generation",
    by_relationship_revision: "Token-relationship revision",
    by_pricing_date: "Pricing date",
    by_price_partition: "Price partition",
    by_currency: "Currency"
  }

  defp dimension_label(dimension), do: Map.get(@dimension_labels, dimension, to_string(dimension))

  # --- announcement helpers ------------------------------------------------

  defp scope_sentence(_state, view), do: "#{view.scope.label} usage."

  defp tokens_sentence(%{any?: false}), do: "No tokens recorded."
  defp tokens_sentence(%{total: total}), do: "#{total} total tokens."

  defp api_equivalent_sentence(%{any?: false}), do: "API-equivalent estimate unavailable."

  defp api_equivalent_sentence(%{by_currency: by_currency}) do
    parts =
      Enum.map_join(by_currency, ", ", fn entry ->
        marker = if entry.subscription_marked?, do: " (subscription estimate)", else: ""
        "#{entry.amount} #{entry.currency}#{marker}"
      end)

    "API-equivalent estimate #{parts}."
  end

  defp provider_reported_sentence(%{any?: false}), do: ""

  defp provider_reported_sentence(%{by_currency: by_currency}) do
    parts = Enum.map_join(by_currency, ", ", fn entry -> "#{entry.amount} #{entry.currency}" end)
    "Provider-reported estimate #{parts}."
  end

  defp routes_sentence(%{any?: false}), do: ""

  defp routes_sentence(%{entries: entries}) do
    {announced, remainder} = Enum.split(entries, 3)
    labels = Enum.map(announced, & &1.accessible_label)
    labels = if remainder == [], do: labels, else: labels ++ ["and #{length(remainder)} more"]
    "Provider routes: #{Enum.join(labels, "; ")}."
  end

  defp tier_sentence(%{joined_count: 0, unjoined_count: 0}), do: ""
  defp tier_sentence(%{note: note}), do: note

  defp coverage_sentence(%{source_label: label, unknown_contributors?: true}),
    do: "Source coverage #{label}; some contributors are unknown."

  defp coverage_sentence(%{source_label: label}), do: "Source coverage #{label}."

  # --- shared helpers ------------------------------------------------------

  defp available?(snapshot), do: Map.get(snapshot, :state) in @available_states

  defp same_scope?(current, incoming) do
    Map.get(current, :scope) == Map.get(incoming, :scope)
  end

  # Subscription-basis API-equivalent currencies: any `by_auth_mode` contributor
  # keyed `:subscription` that priced a nonzero API-equivalent amount.
  defp subscription_currencies(source) do
    source
    |> get_in([:contributors, :by_auth_mode])
    |> case do
      entries when is_list(entries) ->
        entries
        |> Enum.filter(&(Map.get(&1, :key) == :subscription))
        |> Enum.flat_map(fn entry -> entry |> get_in([:api_equivalent, :amount]) |> Kernel.||(%{}) |> Map.keys() end)
        |> MapSet.new()

      _other ->
        MapSet.new()
    end
  end

  # Exact formatted decimal; never rounded, never coerced to a guessed zero.
  defp format_amount(%Decimal{} = amount), do: Decimal.to_string(amount, :normal)
  defp format_amount(amount) when is_binary(amount), do: amount
  defp format_amount(_amount), do: "unknown"
end
