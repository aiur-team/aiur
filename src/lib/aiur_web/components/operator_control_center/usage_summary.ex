defmodule AiurWeb.OperatorControlCenter.UsageSummary do
  @moduledoc """
  Renders the DASH-031 authenticated usage and cost summary from the named view
  produced by `AiurWeb.OperatorControlCenter.UsageSummaryPresenter`.

  A denied connection renders only the value-free locked panel; no token,
  monetary, tier, coverage, or generation fact is ever emitted for it. When
  authorized, the panel renders a tokens-by-model chart (which models consumed
  how many tokens, as additive input/output dimensions) rather than the former
  verbose token/cost tables, and offers bounded, server-paged drill-down.
  """

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.Analytics.{Charts, Styles}
  alias Phoenix.LiveView.JS

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
          {models_chart_panel(assigns)}
        </div>

        {drill_down_panel(assigns)}
      </div>
    </section>
    """
  end

  # --- tokens by model (chart) ----------------------------------------------

  defp models_chart_panel(assigns) do
    assigns = assign(assigns, :legend, Charts.model_token_legend())

    ~H"""
    <section class="usage-summary-chart analytics-root" aria-labelledby="usage-models-title">
      {Phoenix.HTML.raw("<style>" <> Styles.css() <> "</style>")}
      <div class="an-card">
        <div class="an-card-head">
          <div>
            <h3 id="usage-models-title" class="an-card-title">Tokens by model</h3>
            <p class="an-card-sub">
              Which models consumed how many tokens in this scope. Bars stack the additive
              input and output dimensions; reasoning output is part of output.
            </p>
          </div>
        </div>

        <p :if={not @view.models.any?} class="usage-summary-note">No tokens recorded.</p>

        <div :if={@view.models.any?}>
          <div class="an-chart">{Phoenix.HTML.raw(Charts.model_tokens(@view.models))}</div>
          <div class="an-legend">
            <div class="an-legend-head">
              <span class="an-legend-title">Token dimensions</span>
            </div>
            <div class="an-chips">
              <span :for={{dimension, label, color} <- @legend} class="an-chip on" title={Atom.to_string(dimension)}>
                <i style={"background:#{color}"}></i>{label}
              </span>
            </div>
          </div>
        </div>
      </div>
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
          <button
            type="button"
            class="usage-control"
            phx-click={JS.push("usage-drill-close") |> JS.focus(to: "#usage-drill-#{@drill_down.dimension}")}
          >
            Close
          </button>
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
