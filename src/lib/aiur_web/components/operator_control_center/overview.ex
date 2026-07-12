defmodule AiurWeb.OperatorControlCenter.Overview do
  @moduledoc false

  use Phoenix.Component

  attr(:now, :any, required: true)
  attr(:tracker_kind, :string, required: true)
  attr(:agent_kind, :string, required: true)

  def topbar(assigns) do
    ~H"""
    <header class="topbar">
      <a class="brand-mini" href="/" aria-label="Aiur Operator Control Center">
        <img class="brand-mini-logo" src="/aiur-logo.png" alt="" />
        <span class="brand-wordmark"><b>aiur</b> / operator control</span>
      </a>
      <div class="toolbar">
        <span class="status-badge status-badge-live"><span class="status-badge-dot"></span>Live</span>
        <span class="status-badge status-badge-offline"><span class="status-badge-dot"></span>Offline</span>
        <span class="status-badge"><span class="status-key">ITS</span> {@tracker_kind}</span>
        <span class="status-badge"><span class="status-key">Agent</span> {@agent_kind}</span>
        <time class="status-badge mono num" datetime={datetime_value(@now)}>{clock_value(@now)}</time>
        <button id="theme-toggle" class="tool-btn" type="button" phx-hook="ThemeToggle" aria-label="Toggle color theme">
          <span class="theme-icon" aria-hidden="true">◐</span>Theme
        </button>
      </div>
    </header>
    """
  end

  attr(:writable, :boolean, required: true)

  def readonly_banner(assigns) do
    ~H"""
    <div :if={!@writable} class="readonly-banner" role="status">
      <span aria-hidden="true">◉</span>
      <span><b>Read-only dashboard.</b> Decision, message, and pause controls are hidden.</span>
    </div>
    """
  end

  attr(:decisions, :list, required: true)

  def decisions_banner(assigns) do
    blocking = Enum.count(assigns.decisions, &(&1.blocking and &1.lifecycle == :recorded))
    open = Enum.count(assigns.decisions, &(&1.lifecycle == :recorded))
    first = List.first(assigns.decisions)

    assigns = assign(assigns, blocking: blocking, open: open, first: first)

    ~H"""
    <.link
      :if={@first}
      patch={"/decisions/#{@first.decision_id}"}
      class={["decisions-banner", @blocking > 0 && "blocking"]}
    >
      <span class="decision-banner-icon" aria-hidden="true">!</span>
      <span class="decision-banner-body">
        <strong>{banner_title(@blocking, @open)}</strong>
        <span>{banner_detail(@blocking, @open)}</span>
      </span>
      <span class="decision-banner-cta">Review decisions <span aria-hidden="true">→</span></span>
    </.link>
    """
  end

  attr(:overview, :map, required: true)

  def overview(assigns) do
    ~H"""
    <section class="overview-strip" aria-label="Run overview">
      <.stat href="/decisions" tone={if @overview.blocking_decisions > 0, do: "block", else: "good"} value={@overview.blocking_decisions} label="Blocking decisions" />
      <span class="stat-divider"></span>
      <.stat href="/" tone="good" value={@overview.running} label="Running" />
      <span class="stat-divider"></span>
      <.stat href="/" tone={if @overview.queued_or_retrying > 0, do: "attn", else: "good"} value={@overview.queued_or_retrying} label="Queued / retrying" />
      <span class="stat-divider"></span>
      <.stat href="#recent-outcomes" tone="good" value={@overview.merged_this_run} label="Merged this run" />
    </section>
    """
  end

  attr(:live_action, :atom, required: true)
  attr(:decision_count, :integer, required: true)
  attr(:fleet_count, :integer, required: true)

  def tabs(assigns) do
    ~H"""
    <nav class="control-tabs" aria-label="Control Center surfaces">
      <.link patch="/" class={["control-tab", @live_action == :index && "is-active"]}>
        Fleet <span class="count num">{@fleet_count}</span>
      </.link>
      <.link patch="/decisions" class={["control-tab", @live_action in [:decisions, :decision] && "is-active"]}>
        Decision inbox <span class={["count num", @decision_count > 0 && "attn"]}>{@decision_count}</span>
      </.link>
    </nav>
    """
  end

  attr(:error, :map, required: true)

  def error(assigns) do
    ~H"""
    <section :if={@error} class="error-card" role="alert">
      <h2>Fleet snapshot unavailable</h2>
      <p><strong>{@error.code}:</strong> {@error.message}</p>
    </section>
    """
  end

  attr(:href, :string, required: true)
  attr(:tone, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:label, :string, required: true)

  defp stat(assigns) do
    ~H"""
    <a class="stat" data-tone={@tone} href={@href}>
      <span class="stat-dot"></span>
      <strong class="stat-value num">{@value}</strong>
      <span class="stat-label">{@label}</span>
    </a>
    """
  end

  defp banner_title(1, _open), do: "1 decision is blocking an agent"
  defp banner_title(blocking, _open) when blocking > 1, do: "#{blocking} decisions are blocking agents"
  defp banner_title(_blocking, 1), do: "1 decision is awaiting you"
  defp banner_title(_blocking, open), do: "#{open} decisions are awaiting you"

  defp banner_detail(blocking, open) when blocking > 0,
    do: "#{open} awaiting input in total · answer the blocking decision first"

  defp banner_detail(_blocking, _open), do: "Nothing is blocking · answer at your pace to keep agents moving"

  defp clock_value(%DateTime{} = now), do: Calendar.strftime(now, "%H:%M:%S")
  defp clock_value(_now), do: "--:--:--"
  defp datetime_value(%DateTime{} = now), do: DateTime.to_iso8601(now)
  defp datetime_value(_now), do: nil
end
