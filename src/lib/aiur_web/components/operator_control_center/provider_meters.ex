defmodule AiurWeb.OperatorControlCenter.ProviderMeters do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.TimeFormat

  attr(:view, :map, required: true)
  attr(:announcement, :string, default: nil)
  attr(:time_zone, :string, default: "Etc/UTC")

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
        <.provider_card :for={card <- @view.cards} card={card} time_zone={@time_zone} />
      </div>
    </section>
    """
  end

  attr(:card, :map, required: true)
  attr(:time_zone, :string, default: "Etc/UTC")

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
        <div :if={@card.identity.state == :unverified}>
          <dt>Observation scope</dt><dd>Current host · account unverified</dd>
        </div>
        <div><dt>Health</dt><dd>{@card.health.label}</dd></div>
        <div :if={@card.health.age_label}><dt>Observation age</dt><dd>{@card.health.age_label}</dd></div>
        <div :if={@card.observed_at}>
          <dt>Last observation</dt>
          <dd><.timestamp value={@card.observed_at} time_zone={@time_zone} /></dd>
        </div>
      </dl>

      <div :if={@card.account_usage} class="provider-meter-account-usage">
        <div class="provider-meter-account-usage-header">
          <span class="provider-meter-account-count">×{@card.account_usage.count}</span>
          <span :if={is_number(@card.account_usage.total_percent)}>
            Average weekly use: {Float.round(@card.account_usage.total_percent, 1)}%
          </span>
          <span :if={!is_number(@card.account_usage.total_percent)}>Average weekly use: unknown</span>
        </div>
        <div class="provider-meter-account-bar" role="img" aria-label={@card.account_usage.title} title={@card.account_usage.title}>
          <span
            :for={account <- @card.account_usage.accounts}
            class={["provider-meter-account-segment", "account-color-#{rem(account.index, 6)}"]}
            style={"width: #{100 / @card.account_usage.count}%"}
            title={account_usage_title(account)}
          >
            <span :if={is_number(account.percent)} class="provider-meter-account-fill" style={"width: #{account.percent}%"}></span>
          </span>
        </div>
        <ul class="provider-meter-account-labels">
          <li :for={account <- @card.account_usage.accounts}>
            <b>{account.name}</b>: {account_percent(account.percent)} · {account.freshness}
            <span :if={account.age_seconds}>({account.age_seconds}s old)</span>
          </li>
        </ul>
      </div>

      <p :if={@card.state == :loading} class="provider-meter-state empty-state">
        Loading account meters…
      </p>

      <div :if={@card.state == :signed_out} class="provider-meter-state readonly-banner" role="status">
        <span aria-hidden="true">◉</span>
        <span>
          <b>Not signed in.</b>
          No OAuth token is available for this account. Sign in to Claude Code to
          read its meters.
        </span>
      </div>

      <div :if={@card.state == :error} class="provider-meter-state error-card" role="alert">
        <h4>Provider meter error</h4>
        <p>
          {@card.health.failure_label || "The provider meter could not be read."} No earlier
          known-good values are available for this account.
        </p>
      </div>

      <div :if={@card.state == :unavailable} class="provider-meter-state error-card" role="alert">
        <h4>Account meters unavailable</h4>
        <p>The provider account meters cannot be read right now.</p>
      </div>

      <ul :if={visible_windows(@card.windows, @card.account_usage) != []} class="provider-meter-windows">
        <.window :for={window <- visible_windows(@card.windows, @card.account_usage)} window={window} time_zone={@time_zone} />
      </ul>
    </article>
    """
  end

  attr(:window, :map, required: true)
  attr(:time_zone, :string, default: "Etc/UTC")

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
        aria-label={window_meter_aria_label(@window)}
      >
        <span class="provider-meter-track" aria-hidden="true">
          <span class="provider-meter-fill" style={"width: #{@window.meter.now}%"}></span>
        </span>
        <span class="provider-meter-value">
          {@window.meter.now}% used
        </span>
      </div>

      <p :if={@window.coverage == :unsupported} class="provider-meter-coverage">
        Not supported for this account.
      </p>
      <p :if={@window.coverage == :empty_supported} class="provider-meter-coverage">
        Supported; no data reported yet.
      </p>

      <dl class="provider-meter-window-facts compact">
        <div><dt>Coverage</dt><dd>{@window.coverage_label}</dd></div>
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
          <dd><.timestamp value={@window.resets_at} time_zone={@time_zone} /></dd>
        </div>
      </dl>
    </li>
    """
  end

  defp window_meter_aria_label(%{name: name}), do: "#{name} usage"

  defp account_usage_title(account) do
    percent = account_percent(account.percent)
    age = if account.age_seconds, do: "#{account.age_seconds}s old", else: "age unknown"
    "#{account.name}: #{percent}, #{account.freshness}, #{age}"
  end

  defp account_percent(value) when is_number(value), do: "#{value}%"
  defp account_percent(_value), do: "unknown"

  defp visible_windows(windows, nil), do: windows

  defp visible_windows(windows, _account_usage) do
    Enum.reject(windows, &String.starts_with?(&1.limit_id, "seven_day"))
  end

  attr(:value, :any, default: nil)
  attr(:class, :string, default: nil)
  attr(:time_zone, :string, default: "Etc/UTC")

  defp timestamp(assigns) do
    ~H"""
    <time :if={is_struct(@value, DateTime)} class={@class} datetime={TimeFormat.iso8601(@value, @time_zone)}>
      {TimeFormat.iso8601(@value, @time_zone)}
    </time>
    <span :if={!is_struct(@value, DateTime)} class={@class}>Time unknown</span>
    """
  end
end
