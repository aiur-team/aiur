defmodule AiurWeb.OperatorControlCenter.ProviderMeters do
  @moduledoc false

  use Phoenix.Component

  attr(:view, :map, required: true)
  attr(:announcement, :string, default: nil)

  @spec provider_meters(map()) :: Phoenix.LiveView.Rendered.t()
  def provider_meters(assigns) do
    ~H"""
    <section class="section-card provider-meters-card" aria-labelledby="provider-meters-title">
      <header class="section-header provider-meters-header">
        <div>
          <p class="section-eyebrow">Provider accounts</p>
          <h2 id="provider-meters-title" tabindex="-1">Account meters</h2>
        </div>
      </header>

      <p
        id="provider-meters-status"
        class="sr-only"
        role="status"
        aria-live="polite"
        aria-atomic="true"
      >
        {@announcement}
      </p>

      <div :if={@view.state == :locked} class="provider-meters-state readonly-banner" role="status">
        <span aria-hidden="true">◉</span>
        <span>
          <b>{@view.locked.accessible_name}.</b>
          {@view.locked.reason}
          <span :if={@view.locked.authentication_path}>{@view.locked.authentication_path}</span>
        </span>
      </div>

      <div :if={@view.state == :authorized} class="provider-meters-grid">
        <.provider_card :for={card <- @view.cards} card={card} />
      </div>
    </section>
    """
  end

  attr(:card, :map, required: true)

  defp provider_card(assigns) do
    ~H"""
    <article
      class={["provider-meter-card", "provider-#{@card.provider}", "state-#{@card.state}"]}
      aria-labelledby={"provider-meter-#{@card.provider}-title"}
    >
      <header class="provider-meter-header">
        <h3 id={"provider-meter-#{@card.provider}-title"}>{@card.provider_label}</h3>
        <span :if={@card.state != :unknown} class={["provider-meter-badge", "state-#{@card.state}"]}>{@card.status_label}</span>
      </header>

      <dl class="provider-meter-identity compact">
        <div><dt>Backend</dt><dd>{@card.backend_label}</dd></div>
        <div><dt>Auth mode</dt><dd>{@card.auth_mode.label}</dd></div>
        <div :if={@card.plan.state == :known}>
          <dt>Plan</dt>
          <dd>{@card.plan.tier_label}</dd>
        </div>
        <div :if={@card.identity.state == :known}>
          <dt>Account generation</dt>
          <dd class="mono">{@card.identity.generation_label}</dd>
        </div>
        <div><dt>Health</dt><dd>{@card.health.label}</dd></div>
        <div><dt>Freshness</dt><dd>{@card.freshness.label}</dd></div>
        <div :if={@card.state == :stale && @card.health.age_label}>
          <dt>Observation age</dt>
          <dd>{@card.health.age_label}</dd>
        </div>
        <div :if={@card.observed_at}>
          <dt>Last observation</dt>
          <dd><.timestamp value={@card.observed_at} /></dd>
        </div>
      </dl>

      <p :if={@card.state == :loading} class="provider-meter-state empty-state">
        Loading account meters…
      </p>

      <div :if={@card.state == :error} class="provider-meter-state error-card" role="alert">
        <h4>Provider meter error</h4>
        <p>
          {@card.health.failure_label || "The provider meter could not be read."} No last
          known-good values are available for this account.
        </p>
      </div>

      <div :if={@card.state == :unavailable} class="provider-meter-state error-card" role="alert">
        <h4>Account meters unavailable</h4>
        <p>The provider account meters cannot be read right now.</p>
      </div>

      <div :if={@card.state == :stale} class="provider-meter-state readonly-banner" role="status">
        <span aria-hidden="true">◉</span>
        <span>
          <b>Stale meters.</b>
          Showing the last known-good values for this account.
          <span :if={@card.health.age_label}>Observation is {@card.health.age_label}.</span>
          <span :if={@card.health.failure_label}>Last refresh {String.downcase(@card.health.failure_label)}.</span>
        </span>
      </div>

      <ul :if={@card.windows != []} class="provider-meter-windows">
        <.window :for={window <- @card.windows} window={window} />
      </ul>
    </article>
    """
  end

  attr(:window, :map, required: true)

  defp window(assigns) do
    ~H"""
    <li class={["provider-meter-window", "coverage-#{@window.coverage}"]}>
      <div class="provider-meter-window-header">
        <span class="provider-meter-window-name">{@window.name}</span>
        <span class="provider-meter-window-kind">{@window.kind_label}</span>
        <span
          :if={@window.standing_label}
          class={["provider-meter-standing", "standing-#{@window.standing}"]}
        >
          {@window.standing_label}
        </span>
      </div>

      <div
        :if={@window.meter.kind == :exact}
        class="provider-meter-bar"
        role="progressbar"
        aria-valuemin={@window.meter.min}
        aria-valuemax={@window.meter.max}
        aria-valuenow={@window.meter.now}
        aria-label={"#{@window.name} usage"}
      >
        <span class="provider-meter-track" aria-hidden="true">
          <span class="provider-meter-fill" style={"width: #{@window.meter.now}%"}></span>
        </span>
        <span class="provider-meter-value">{@window.meter.now}% used</span>
      </div>

      <p :if={@window.coverage == :unsupported} class="provider-meter-coverage">
        Not supported for this account.
      </p>
      <p :if={@window.coverage == :empty_supported} class="provider-meter-coverage">
        Supported; no data reported yet.
      </p>

      <dl class="provider-meter-window-facts compact">
        <div><dt>Coverage</dt><dd>{@window.coverage_label}</dd></div>
        <div :if={@window.freshness_label}>
          <dt>Freshness</dt>
          <dd>{@window.freshness_label}</dd>
        </div>
        <div :if={is_number(@window.remaining_percent)}>
          <dt>Remaining</dt>
          <dd class="num">{@window.remaining_percent}%</dd>
        </div>
        <div :if={@window.credits}>
          <dt>Credits</dt>
          <dd>
            {@window.credits.label}<span :if={is_number(@window.credits.amount)}> ({@window.credits.amount})</span>
          </dd>
        </div>
        <div :if={@window.spend_control}>
          <dt>Spend control</dt>
          <dd>
            {@window.spend_control.label}<span :if={is_number(@window.spend_control.limit)}> ({@window.spend_control.limit})</span>
          </dd>
        </div>
        <div :if={@window.resets_at}>
          <dt>Resets</dt>
          <dd><.timestamp value={@window.resets_at} /></dd>
        </div>
        <div :if={@window.expires_at}>
          <dt>Freshness horizon</dt>
          <dd><.timestamp value={@window.expires_at} /></dd>
        </div>
      </dl>
    </li>
    """
  end

  attr(:value, :any, default: nil)
  attr(:class, :string, default: nil)

  defp timestamp(assigns) do
    ~H"""
    <time :if={is_struct(@value, DateTime)} class={@class} datetime={DateTime.to_iso8601(@value)}>
      {DateTime.to_iso8601(@value)}
    </time>
    <span :if={!is_struct(@value, DateTime)} class={@class}>Time unknown</span>
    """
  end
end
