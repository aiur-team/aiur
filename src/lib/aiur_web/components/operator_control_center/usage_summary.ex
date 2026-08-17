defmodule AiurWeb.OperatorControlCenter.UsageSummary do
  @moduledoc """
  Renders the DASH-031 authenticated usage and cost summary from the named view
  produced by `AiurWeb.OperatorControlCenter.UsageSummaryPresenter`.

  A denied connection renders only the value-free locked panel; no token,
  monetary, tier, coverage, or generation fact is ever emitted for it. When
  authorized, the panel renders a tokens-by-model chart (which models consumed
  how many tokens, as additive input/output dimensions) followed by a compact
  cost-by-provider-route table. It does not restore the former generic
  drill-down UI.
  """

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.Analytics.{Charts, Styles}

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
          <b>Not live.</b>
          Showing the usage we last read for this scope; refresh is {String.downcase(@view.freshness.label)}.
        </span>
      </div>

      <div :if={@state in [:ready, :partial, :stale]} class="usage-summary-body">
        <div class="usage-summary-grid">
          {models_chart_panel(assigns)}
          {provider_routes_panel(assigns)}
        </div>
      </div>
    </section>
    """
  end

  # --- tokens by model (chart) ----------------------------------------------

  defp models_chart_panel(assigns) do
    ~H"""
    <section class="usage-summary-chart analytics-root" aria-labelledby="usage-models-title">
      {Phoenix.HTML.raw("<style>" <> Styles.css() <> "</style>")}
      <div class="an-card">
        <div class="an-card-head">
          <div>
            <h3 id="usage-models-title" class="an-card-title">Tokens by model</h3>
          </div>
        </div>

        <p :if={not @view.models.any?} class="usage-summary-note">No tokens recorded.</p>

        <div :if={@view.models.any?} class="usage-token-grid">
          <div class="usage-token-line an-chart">{Phoenix.HTML.raw(Charts.model_tokens_timeline(@view.models))}</div>
          <div class="usage-token-bars an-chart">{Phoenix.HTML.raw(Charts.token_destination(@view.tokens))}</div>
        </div>
      </div>
    </section>
    """
  end

  # --- cost by provider route ---------------------------------------------

  defp provider_routes_panel(assigns) do
    ~H"""
    <section class="usage-summary-panel" aria-labelledby="usage-provider-routes-title">
      <h3 id="usage-provider-routes-title">Cost by provider route</h3>

      <p :if={not @view.routes.any?} class="usage-summary-note">No provider routes recorded.</p>

      <div
        :if={@view.routes.any?}
        class="usage-provider-routes-wrap"
        role="region"
        aria-label="Cost by provider route"
        tabindex="0"
      >
        <table class="usage-summary-table usage-provider-routes-table">
          <thead>
            <tr>
              <th scope="col">Route</th>
              <th scope="col">Provider-reported estimate</th>
              <th scope="col">API-equivalent estimate</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={route <- @view.routes.entries}>
              <th scope="row">
                <span aria-hidden="true">{route.label}</span>
                <span class="sr-only">{route.accessible_label}</span>
              </th>
              <td>{route.provider_reported_label}</td>
              <td>{route.api_equivalent_label}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end
end
