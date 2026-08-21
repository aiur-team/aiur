defmodule AiurWeb.OperatorControlCenter.Overview do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.{DecisionPath, FleetFilters}

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
  # Routes outside the dashboard LiveView cannot patch into /commands; they
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
      patch={!@navigate && DecisionPath.inbox(:all)}
      navigate={@navigate && DecisionPath.inbox(:all)}
      class={["decisions-banner", @blocking > 0 && "blocking"]}
      aria-label={"#{@open} Commands awaiting you, #{@blocking} blocking"}
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
        <b>Command counts unavailable.</b>
        This page cannot show how many units are awaiting commands. Open Commands to work the queue directly.
      </span>
    </div>
    <div :if={@health == :partial and is_integer(@open)} class="readonly-banner" role="status" aria-live="polite">
      <span aria-hidden="true">◉</span>
      <span><b>Partial Command counts.</b> Counts are at least this high.</span>
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
    <section :if={reportable?(@error)} class="error-card" role="alert">
      <h2>{error_title(@error[:code])}</h2>
      <p>{error_detail(@error[:code], @error[:message])}</p>
      <p class="error-code"><strong>{@error[:code]}:</strong> {@error[:message]}</p>
    </section>
    """
  end

  # A run that has not published its first fleet snapshot is an expected moment
  # after a restart, not something the operator has to be told about: the Units
  # catalog below already reports that the fleet view is unavailable. Only the
  # notice goes — `snapshot_unpublished` still travels in the payload, where the
  # API contract and the catalog's own stale state read it.
  defp reportable?(%{code: "snapshot_unpublished"}), do: false
  defp reportable?(error), do: not is_nil(error)

  # A published-but-aged fleet view is never "unavailable": it is last-known-good
  # data with an age. Only a producer with nothing published reaches `error/1`.
  defp error_title("orchestrator_unavailable"), do: "No fleet data"
  defp error_title("snapshot_unavailable"), do: "Could not read the fleet"
  defp error_title(_code), do: "No fleet data"

  # Every detail line must be derivable from the code it is given. Naming a
  # subsystem that was never observed is the defect this component exists to
  # remove: an unverified "the Orchestrator is not reachable" is the same shape
  # as the "current-run membership is healthy" that once explained a missing
  # snapshot.
  defp error_detail("orchestrator_unavailable", _message),
    do: "The Orchestrator is not reachable and there is no earlier fleet data to show."

  # `snapshot_unavailable` is raised by the read-model composition itself, not by
  # the Orchestrator, so it says nothing about whether the Orchestrator is alive.
  defp error_detail("snapshot_unavailable", _message),
    do:
      "The fleet view could not be built, so there is nothing to show. " <>
        "This does not report on the Orchestrator itself, which may still be running."

  defp error_detail(_code, _message),
    do: "No fleet data. The reported fault is shown below."

  defp banner_title(_blocking, 1), do: "1 unit awaiting commands"
  defp banner_title(_blocking, open), do: "#{open} units awaiting commands"

  defp active?(_filters, :all, all_active), do: all_active
  defp active?(filters, key, _all_active), do: MapSet.member?(filters, key)
end
