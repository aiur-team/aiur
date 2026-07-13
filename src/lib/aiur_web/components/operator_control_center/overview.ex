defmodule AiurWeb.OperatorControlCenter.Overview do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.FleetFilters

  @fleet_stats [
    {:running, "Active", "good"},
    {:blocked, "Blocked", "block"},
    {:paused, "Paused", "attn"},
    {:stuck, "Stuck", "attn"},
    {:finished, "Finished", "good"},
    {:all, "Total", "faint"}
  ]

  attr(:now, :any, required: true)
  attr(:tracker_kind, :string, required: true)
  attr(:agent_kind, :string, required: true)

  @spec topbar(map()) :: Phoenix.LiveView.Rendered.t()
  def topbar(assigns) do
    ~H"""
    <header class="topbar">
      <a class="brand-mini" href="/" aria-label="Aiur Executor Control Center">
        <img class="brand-mini-logo" src="/aiur-logo.png" alt="" />
        <span class="brand-wordmark"><b>aiur</b> / Executor Control Center</span>
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

  @spec readonly_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def readonly_banner(assigns) do
    ~H"""
    <div :if={!@writable} class="readonly-banner" role="status">
      <span aria-hidden="true">◉</span>
      <span><b>Read-only dashboard.</b> Decision, message, and pause controls are hidden.</span>
    </div>
    """
  end

  attr(:decisions, :list, required: true)

  @spec decisions_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def decisions_banner(assigns) do
    blocking = Enum.count(assigns.decisions, &(&1.blocking and &1.lifecycle == :recorded))
    open = Enum.count(assigns.decisions, &(&1.lifecycle == :recorded))
    first = Enum.find(assigns.decisions, &(&1.lifecycle == :recorded))

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

  attr(:fleet, :map, required: true)
  attr(:filters, :any, required: true)

  @spec fleet_overview(map()) :: Phoenix.LiveView.Rendered.t()
  def fleet_overview(assigns) do
    assigns =
      assigns
      |> assign(:counts, FleetFilters.counts(assigns.fleet))
      |> assign(:stats, @fleet_stats)
      |> assign(:all_active, MapSet.equal?(assigns.filters, MapSet.new(FleetFilters.all())))

    ~H"""
    <section class="overview-strip" aria-label="Fleet filters">
      <button
        :for={{key, label, tone} <- @stats}
        type="button"
        class={["stat", active?(@filters, key, @all_active) && "is-active"]}
        data-tone={tone}
        phx-click="toggle-fleet-filter"
        phx-value-filter={key}
        aria-pressed={to_string(active?(@filters, key, @all_active))}
      >
        <span class="stat-dot"></span>
        <strong class="stat-value num">{@counts[key]}</strong>
        <span class="stat-label">{label}</span>
      </button>
    </section>
    """
  end

  attr(:live_action, :atom, required: true)
  attr(:decision_count, :integer, required: true)
  attr(:fleet_count, :integer, required: true)

  @spec tabs(map()) :: Phoenix.LiveView.Rendered.t()
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

  @spec error(map()) :: Phoenix.LiveView.Rendered.t()
  def error(assigns) do
    ~H"""
    <section :if={@error} class="error-card" role="alert">
      <h2>Fleet snapshot unavailable</h2>
      <p><strong>{@error.code}:</strong> {@error.message}</p>
    </section>
    """
  end

  defp banner_title(1, _open), do: "1 decision is blocking an agent"
  defp banner_title(blocking, _open) when blocking > 1, do: "#{blocking} decisions are blocking agents"
  defp banner_title(_blocking, 1), do: "1 decision is awaiting you"
  defp banner_title(_blocking, open), do: "#{open} decisions are awaiting you"

  defp banner_detail(blocking, open) when blocking > 0,
    do: "#{open} awaiting input in total · answer the blocking decision first"

  defp banner_detail(_blocking, _open), do: "Nothing is blocking · answer at your pace to keep agents moving"

  defp active?(_filters, :all, all_active), do: all_active
  defp active?(filters, key, _all_active), do: MapSet.member?(filters, key)

  defp clock_value(%DateTime{} = now), do: Calendar.strftime(now, "%H:%M:%S")
  defp clock_value(_now), do: "--:--:--"
  defp datetime_value(%DateTime{} = now), do: DateTime.to_iso8601(now)
  defp datetime_value(_now), do: nil
end
