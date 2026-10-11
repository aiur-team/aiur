defmodule AiurWeb.OperatorControlCenter.UsageSummaryPresenter.Labels do
  @moduledoc "Labels, status sub-views and announcement sentences for `AiurWeb.OperatorControlCenter.UsageSummaryPresenter`."

  alias Aiur.CodingAgent

  @doc false
  @spec scope_label(term()) :: String.t()
  def scope_label(:this_run), do: "This run"
  def scope_label(:explicit_ticket_set), do: "Selected build"
  def scope_label(:intersection), do: "This run and selected build"
  def scope_label(_kind), do: "Scope unknown"

  @doc false
  @spec token_label(term()) :: String.t()
  def token_label(dimension) do
    dimension |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  @doc false
  @spec model_label(term()) :: String.t()
  def model_label(nil), do: "Unknown"
  def model_label(:unknown), do: "Unknown"
  def model_label(label) when is_binary(label), do: label
  def model_label(label), do: to_string(label)

  @doc false
  @spec provider_route_labels(term(), term()) :: {String.t(), String.t()}
  def provider_route_labels(provider, upstream_provider) when is_binary(upstream_provider) do
    provider = provider_label(provider)
    {"#{provider} -> #{upstream_provider}", "#{provider} routed through #{upstream_provider}"}
  end

  def provider_route_labels(provider, nil) when provider in [:openrouter, "openrouter"] do
    {"OpenRouter -> upstream unknown", "OpenRouter routed through upstream provider unknown"}
  end

  def provider_route_labels(provider, _upstream_provider) do
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

  @doc false
  @spec money_label([map()]) :: String.t()
  def money_label([]), do: "Unknown"

  def money_label(entries) do
    Enum.map_join(entries, " + ", fn entry ->
      marker = if entry.subscription_marked?, do: "*", else: ""
      "#{entry.amount} #{entry.currency}#{marker}"
    end)
  end

  # --- disclosure ----------------------------------------------------------

  @doc false
  @spec disclosure(MapSet.t()) :: map()
  def disclosure(subscription_currencies) do
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

  @doc false
  @spec present_tier(term(), map()) :: map()
  # Join actual plan/tier only on an exact known (provider, backend, generation).
  # Unknown, mixed, and mismatched generations remain unjoined, and a combined
  # total never receives a synthetic cross-provider tier.
  def present_tier(join_keys, tier_facts) when is_list(join_keys) do
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

  def present_tier(_join_keys, _tier_facts), do: %{entries: [], joined_count: 0, unjoined_count: 0, combined_tier: :none, note: ""}

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

  @doc false
  @spec present_coverage(map()) :: map()
  # Source coverage is surfaced separately from the totals so missing or partial
  # source coverage can never read as zero usage.
  def present_coverage(coverage) do
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

  @doc false
  @spec present_money_coverage(map()) :: map()
  def present_money_coverage(coverage) do
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

  @doc false
  @spec present_retained_interval(map()) :: map()
  def present_retained_interval(interval) do
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

  # --- health / freshness --------------------------------------------------

  @doc false
  @spec present_health(term()) :: map()
  # Health arrives as `:healthy`, `{:degraded, reason}`, `{:unavailable, reason}`,
  # or nil across the ledger/aggregate layers; name each without inferring.
  def present_health(:healthy), do: %{status: :healthy, reason: nil, label: "Healthy"}
  def present_health({:degraded, reason}), do: %{status: :degraded, reason: reason, label: "Degraded"}
  def present_health({:unavailable, reason}), do: %{status: :unavailable, reason: reason, label: "Unavailable"}
  def present_health(_health), do: %{status: :unknown, reason: nil, label: "Unknown"}

  @doc false
  @spec present_freshness(term()) :: map()
  def present_freshness(%{status: status}), do: %{status: status, label: freshness_label(status)}
  def present_freshness(_freshness), do: %{status: :unknown, label: "Unknown"}

  defp freshness_label(:fresh), do: "Fresh"
  defp freshness_label(:partial), do: "Partial"
  defp freshness_label(:stale), do: "Healthy"
  defp freshness_label(:empty), do: "Empty"
  defp freshness_label(:unavailable), do: "Unavailable"
  defp freshness_label(_status), do: "Unknown"

  @doc false
  @spec contributor_key_label(atom(), term()) :: String.t()
  def contributor_key_label(_dimension, nil), do: "Unknown"
  def contributor_key_label(:by_ticket, :unknown), do: "Unknown ticket"
  def contributor_key_label(_dimension, :unknown), do: "Unknown"
  def contributor_key_label(_dimension, key) when is_atom(key), do: key |> to_string() |> String.replace("_", " ")
  def contributor_key_label(_dimension, key) when is_binary(key), do: key

  def contributor_key_label(_dimension, {owner, repo, number}) when is_binary(owner),
    do: "#{owner}/#{repo}##{number}"

  def contributor_key_label(_dimension, key), do: inspect(key)

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

  @doc false
  @spec dimension_label(atom()) :: String.t()
  def dimension_label(dimension), do: Map.get(@dimension_labels, dimension, to_string(dimension))

  # --- announcement helpers ------------------------------------------------

  @doc false
  @spec scope_sentence(atom(), map()) :: String.t()
  def scope_sentence(_state, view), do: "#{view.scope.label} usage."

  @doc false
  @spec tokens_sentence(map()) :: String.t()
  def tokens_sentence(%{any?: false}), do: "No tokens recorded."
  def tokens_sentence(%{total: total}), do: "#{total} total tokens."

  @doc false
  @spec api_equivalent_sentence(map()) :: String.t()
  def api_equivalent_sentence(%{any?: false}), do: "API-equivalent estimate unavailable."

  def api_equivalent_sentence(%{by_currency: by_currency}) do
    parts =
      Enum.map_join(by_currency, ", ", fn entry ->
        marker = if entry.subscription_marked?, do: " (subscription estimate)", else: ""
        "#{entry.amount} #{entry.currency}#{marker}"
      end)

    "API-equivalent estimate #{parts}."
  end

  @doc false
  @spec provider_reported_sentence(map()) :: String.t()
  def provider_reported_sentence(%{any?: false}), do: ""

  def provider_reported_sentence(%{by_currency: by_currency}) do
    parts = Enum.map_join(by_currency, ", ", fn entry -> "#{entry.amount} #{entry.currency}" end)
    "Provider-reported estimate #{parts}."
  end

  @doc false
  @spec routes_sentence(map()) :: String.t()
  def routes_sentence(%{any?: false}), do: ""

  def routes_sentence(%{entries: entries}) do
    {announced, remainder} = Enum.split(entries, 3)
    labels = Enum.map(announced, & &1.accessible_label)
    labels = if remainder == [], do: labels, else: labels ++ ["and #{length(remainder)} more"]
    "Provider routes: #{Enum.join(labels, "; ")}."
  end

  @doc false
  @spec tier_sentence(map()) :: String.t()
  def tier_sentence(%{joined_count: 0, unjoined_count: 0}), do: ""
  def tier_sentence(%{note: note}), do: note

  @doc false
  @spec coverage_sentence(map()) :: String.t()
  def coverage_sentence(%{source_label: label, unknown_contributors?: true}),
    do: "Source coverage #{label}; some contributors are unknown."

  def coverage_sentence(%{source_label: label}), do: "Source coverage #{label}."
end
