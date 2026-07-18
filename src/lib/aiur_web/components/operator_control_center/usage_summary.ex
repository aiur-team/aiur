defmodule AiurWeb.OperatorControlCenter.UsageSummary do
  @moduledoc """
  Renders the DASH-031 authenticated usage and cost summary from the named view
  produced by `AiurWeb.OperatorControlCenter.UsageSummaryPresenter`.

  A denied connection renders only the value-free locked panel; no token,
  monetary, tier, coverage, or generation fact is ever emitted for it. When
  authorized, the panel keeps the two monetary bases (provider-reported estimate
  and API-equivalent estimate) in separate regions, marks subscription
  API-equivalent totals with `*` behind a native keyboard/touch-accessible
  disclosure, and offers bounded, server-paged drill-down.
  """

  use Phoenix.Component

  attr(:view, :map, required: true)
  attr(:announcement, :string, default: nil)
  attr(:drill_down, :map, default: nil)
  attr(:drill_trigger, :string, default: nil)

  @spec usage_summary(map()) :: Phoenix.LiveView.Rendered.t()
  def usage_summary(assigns) do
    assigns = assign(assigns, :state, Map.get(assigns.view, :state, :loading))

    ~H"""
    <section class="section-card usage-summary-card" aria-labelledby="usage-summary-title">
      <header class="section-header usage-summary-header">
        <div>
          <p class="section-eyebrow">Accounting</p>
          <h2 id="usage-summary-title" tabindex="-1">Usage and cost</h2>
        </div>
        <div class="usage-summary-badges" :if={@state in [:ready, :partial, :stale]}>
          <span class={["usage-summary-badge", "health-#{@view.health.status}"]}>
            Health: {@view.health.label}
          </span>
          <span class={["usage-summary-badge", "freshness-#{@view.freshness.status}"]}>
            {@view.freshness.label}
          </span>
        </div>
      </header>

      <p id="usage-summary-status" class="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {@announcement}
      </p>

      <div :if={@state == :locked} class="usage-summary-state locked-panel" role="note">
        <h3>{@view.accessible_name}</h3>
        <p>{@view.reason}</p>
        <p class="usage-summary-hint">{@view.authentication_path}</p>
      </div>

      <div :if={@state == :loading} class="usage-summary-state empty-state">
        Loading usage and cost…
      </div>

      <div :if={@state == :empty} class="usage-summary-state empty-state">
        No usage has been recorded for this scope.
      </div>

      <div :if={@state == :unavailable} class="usage-summary-state error-card" role="alert">
        <h3>Usage and cost summary unavailable</h3>
        <p>The usage and cost facts cannot be read right now.</p>
      </div>

      <div :if={@state == :stale} class="usage-summary-state readonly-banner" role="status">
        <span aria-hidden="true">◉</span>
        <span>
          <b>Stale summary.</b>
          Showing the last known-good usage for this scope; refresh is {String.downcase(@view.freshness.label)}.
        </span>
      </div>

      <div :if={@state in [:ready, :partial, :stale]} class="usage-summary-body">
        <p class="usage-summary-scope">
          Scope: <b>{@view.scope.label}</b>
          <span :if={@view.scope.rejected_tickets > 0} class="usage-summary-note">
            ({@view.scope.rejected_tickets} non-joinable tickets excluded)
          </span>
        </p>

        <div class="usage-summary-grid">
          {tokens_panel(assigns)}
          {api_equivalent_panel(assigns)}
          {provider_reported_panel(assigns)}
          {tier_panel(assigns)}
          {coverage_panel(assigns)}
        </div>

        {drill_down_panel(assigns)}
      </div>
    </section>
    """
  end

  # --- tokens --------------------------------------------------------------

  defp tokens_panel(assigns) do
    ~H"""
    <section class="usage-summary-panel" aria-labelledby="usage-tokens-title">
      <h3 id="usage-tokens-title">Tokens</h3>
      <p :if={not @view.tokens.any?} class="usage-summary-note">No tokens recorded.</p>
      <table :if={@view.tokens.any?} class="usage-summary-table">
        <caption class="sr-only">Token counts by dimension</caption>
        <thead>
          <tr><th scope="col">Dimension</th><th scope="col">Tokens</th></tr>
        </thead>
        <tbody>
          <tr :for={entry <- @view.tokens.entries}>
            <th scope="row">{entry.label}</th>
            <td>{entry.count}</td>
          </tr>
        </tbody>
        <tfoot>
          <tr><th scope="row">Total</th><td>{@view.tokens.total}</td></tr>
        </tfoot>
      </table>
    </section>
    """
  end

  # --- API-equivalent estimate ---------------------------------------------

  defp api_equivalent_panel(assigns) do
    ~H"""
    <section class="usage-summary-panel" aria-labelledby="usage-api-title">
      <h3 id="usage-api-title">API-equivalent estimate</h3>
      <p class="usage-summary-note">An estimate priced at published per-token API rates — not billed spend.</p>

      <p :if={not @view.api_equivalent.any?} class="usage-summary-note">
        No priceable usage in scope.
      </p>

      <ul :if={@view.api_equivalent.any?} class="usage-summary-money">
        <li :for={entry <- @view.api_equivalent.by_currency}>
          <span class="usage-summary-amount">{entry.amount} {entry.currency}</span>
          <span :if={entry.subscription_marked?} class="usage-summary-mark" aria-hidden="true">
            {@view.disclosure.marker}
          </span>
          <span :if={entry.subscription_marked?} class="sr-only">(subscription estimate)</span>
        </li>
      </ul>

      <p class="usage-summary-coverage">
        Pricing coverage: {@view.api_equivalent.coverage.label}
      </p>

      <details :if={@view.disclosure.required?} class="usage-disclosure">
        <summary class="usage-control">{@view.disclosure.marker} {@view.disclosure.title}</summary>
        <p>{@view.disclosure.body}</p>
      </details>
    </section>
    """
  end

  # --- provider-reported estimate ------------------------------------------

  defp provider_reported_panel(assigns) do
    ~H"""
    <section class="usage-summary-panel" aria-labelledby="usage-provider-title">
      <h3 id="usage-provider-title">Provider-reported estimate</h3>
      <p class="usage-summary-note">As reported by the provider — a separate estimate, not billed spend.</p>
      <p :if={not @view.provider_reported.any?} class="usage-summary-note">None reported.</p>
      <ul :if={@view.provider_reported.any?} class="usage-summary-money">
        <li :for={entry <- @view.provider_reported.by_currency}>
          <span class="usage-summary-amount">{entry.amount} {entry.currency}</span>
        </li>
      </ul>
    </section>
    """
  end

  # --- tier ----------------------------------------------------------------

  defp tier_panel(assigns) do
    ~H"""
    <section class="usage-summary-panel" aria-labelledby="usage-tier-title">
      <h3 id="usage-tier-title">Plan tier</h3>
      <p class="usage-summary-note">{@view.tier.note}</p>
      <ul :if={@view.tier.entries != []} class="usage-summary-tiers">
        <li :for={entry <- @view.tier.entries} class={"tier-#{entry.status}"}>
          <span class="usage-summary-tier-provider">{entry.provider} / {entry.backend}</span>
          <span class="usage-summary-tier-label">{entry.tier_label}</span>
        </li>
      </ul>
    </section>
    """
  end

  # --- coverage ------------------------------------------------------------

  defp coverage_panel(assigns) do
    ~H"""
    <section class="usage-summary-panel" aria-labelledby="usage-coverage-title">
      <h3 id="usage-coverage-title">Coverage</h3>
      <dl class="usage-summary-facts">
        <div class="usage-summary-fact">
          <dt>Source coverage</dt>
          <dd>{@view.coverage.source_label}</dd>
        </div>
        <div class="usage-summary-fact">
          <dt>Retained interval</dt>
          <dd>
            <span :if={@view.retained_interval.earliest}>
              <time>{@view.retained_interval.earliest}</time>–<time>{@view.retained_interval.latest}</time>
            </span>
            <span>{@view.retained_interval.label}</span>
          </dd>
        </div>
        <div class="usage-summary-fact">
          <dt>Totals reconcile</dt>
          <dd>{if @view.reconciliation.reconciled?, do: "Yes", else: "No — contributors do not sum to the total"}</dd>
        </div>
        <div class="usage-summary-fact" :if={@view.coverage.unknown_contributors?}>
          <dt>Unknown contributors</dt>
          <dd>Some usage could not be attributed and is named unknown, not zero.</dd>
        </div>
      </dl>
    </section>
    """
  end

  # --- drill-down ----------------------------------------------------------

  @drill_dimensions [
    {:by_provider, "Provider"},
    {:by_ticket, "Ticket"},
    {:by_agent_family, "Agent family"},
    {:by_model, "Model"},
    {:by_account_generation, "Account generation"}
  ]

  defp drill_down_panel(assigns) do
    assigns = assign(assigns, :drill_dimensions, @drill_dimensions)

    ~H"""
    <section class="usage-summary-drill" aria-labelledby="usage-drill-title">
      <h3 id="usage-drill-title">Drill down</h3>
      <div class="usage-drill-controls" role="group" aria-label="Drill down by dimension">
        <button
          :for={{dimension, label} <- @drill_dimensions}
          type="button"
          class="usage-control"
          id={"usage-drill-#{dimension}"}
          phx-click="usage-drill-down"
          phx-value-dimension={dimension}
          aria-expanded={to_string(@drill_trigger == to_string(dimension))}
          aria-controls="usage-drill-region"
        >
          {label}
        </button>
      </div>

      <div id="usage-drill-region" class="usage-drill-region" :if={@drill_down}>
        <div class="usage-drill-region-header">
          <h4>{@drill_down.label} — {@drill_down.total} contributors</h4>
          <button type="button" class="usage-control" phx-click="usage-drill-close">Close</button>
        </div>

        <table class="usage-summary-table">
          <caption class="sr-only">Contributors by {@drill_down.label}</caption>
          <thead>
            <tr>
              <th scope="col">{@drill_down.label}</th>
              <th scope="col">Provider-reported</th>
              <th scope="col">API-equivalent</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={item <- @drill_down.items}>
              <th scope="row">{item.key_label}</th>
              <td>{money_cell(item.provider_reported)}</td>
              <td>
                {money_cell(item.api_equivalent)}
                <span :if={Enum.any?(item.api_equivalent, & &1.subscription_marked?)} aria-hidden="true">*</span>
              </td>
            </tr>
          </tbody>
        </table>

        <button
          :if={@drill_down.has_more}
          type="button"
          class="usage-control"
          phx-click="usage-drill-more"
          phx-value-dimension={@drill_down.dimension}
          phx-value-cursor={@drill_down.next_cursor}
        >
          Load more ({@drill_down.total - length(@drill_down.items)} remaining)
        </button>
      </div>
    </section>
    """
  end

  defp money_cell([]), do: "—"

  defp money_cell(entries) do
    Enum.map_join(entries, ", ", fn entry -> "#{entry.amount} #{entry.currency}" end)
  end
end
