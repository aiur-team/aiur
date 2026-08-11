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

  attr(:writable, :boolean, required: true)

  @spec readonly_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def readonly_banner(assigns) do
    ~H"""
    <div :if={!@writable} class="readonly-banner" role="status">
      <span aria-hidden="true">◉</span>
      <span><b>Read-only dashboard.</b> Command, message, and pause controls are hidden.</span>
    </div>
    """
  end

  attr(:decisions, :list, default: [])
  attr(:retained_counts, :map, required: true)
  # Routes outside the dashboard LiveView cannot patch into /decisions; they
  # live-navigate instead. Same live session either way, so no full page load.
  attr(:navigate, :boolean, default: false)

  @spec decisions_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def decisions_banner(assigns) do
    # `awaiting`, not `open`: a Command already deferred to the Executor is
    # still open — the unit stays blocked — but it is no longer on the
    # operator's queue, and the inbox no longer lists it. Counting it here would
    # put a number on the banner that the page underneath contradicts.
    assigns =
      assigns
      |> assign(:blocking, Map.get(assigns.retained_counts, :awaiting_blocking))
      |> assign(:open, Map.get(assigns.retained_counts, :awaiting))
      |> assign(:health, get_in(assigns.retained_counts, [:health, :status]))

    ~H"""
    <.link
      :if={is_integer(@open) and @open > 0}
      patch={!@navigate && "/decisions"}
      navigate={@navigate && "/decisions"}
      class={["decisions-banner", @blocking > 0 && "blocking"]}
      aria-label={"#{@open} retained Commands awaiting the operator, #{@blocking} blocking"}
    >
      <span class="decision-banner-icon" aria-hidden="true">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
          <path d="M12 9v4M12 17h.01" />
        </svg>
      </span>
      <span class="decision-banner-body">
        <strong>{banner_title(@blocking, @open)}</strong>
      </span>
      <span class="decision-banner-cta">
        Issue commands
        <span class="cta-chevron" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
            <path d="m9 6 6 6-6 6" />
          </svg>
        </span>
      </span>
    </.link>
    <%!-- The banner is on every route now, so this degraded copy has to be true
          on every route. It used to promise "the priority overview is still
          shown", which is a Commands-page fact: on Analytics, Build Order and
          Stream Deck there is no priority overview to fall back to, and a
          degraded surface that states a wrong reason is worse than one that
          only says the number is missing. --%>
    <div :if={!is_integer(@open)} class="readonly-banner" role="status" aria-live="polite">
      <span aria-hidden="true">◉</span>
      <span>
        <b>Retained Command counts unavailable.</b>
        This page cannot show how many units are awaiting commands. Open Commands to work the queue directly.
      </span>
    </div>
    <div :if={@health == :partial and is_integer(@open)} class="readonly-banner" role="status" aria-live="polite">
      <span aria-hidden="true">◉</span>
      <span><b>Partial retained Command counts.</b> Counts cover the validated audit prefix only.</span>
    </div>
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

  attr(:error, :map, required: true)

  @spec error(map()) :: Phoenix.LiveView.Rendered.t()
  def error(assigns) do
    ~H"""
    <section :if={@error} class="error-card" role="alert">
      <h2>Snapshot unavailable</h2>
      <p><strong>{@error.code}:</strong> {@error.message}</p>
    </section>
    """
  end

  attr(:freshness, :map, default: %{})

  @spec stale_snapshot(map()) :: Phoenix.LiveView.Rendered.t()
  def stale_snapshot(assigns) do
    ~H"""
    <div :if={@freshness[:status] == :stale} class="readonly-banner" role="status" aria-live="polite">
      <span aria-hidden="true">◉</span>
      <span>
        <b>Fleet snapshot is stale.</b>
        {stale_reason(@freshness[:reason])} Showing the last known-good fleet as of {@freshness[:age_seconds]}s ago.
      </span>
    </div>
    """
  end

  defp stale_reason(:snapshot_timeout), do: "The Orchestrator is busy."
  defp stale_reason(:orchestrator_unavailable), do: "The Orchestrator is unavailable."
  defp stale_reason(_reason), do: ""

  defp banner_title(_blocking, 1), do: "1 unit awaiting commands"
  defp banner_title(_blocking, open), do: "#{open} units awaiting commands"

  defp active?(_filters, :all, all_active), do: all_active
  defp active?(filters, key, _all_active), do: MapSet.member?(filters, key)
end
