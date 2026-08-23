defmodule AiurWeb.OperatorControlCenter.BuildOrderAnalytics do
  @moduledoc """
  Current-session analytics pane for the selected Build Order, rendered under
  Waves & Epics.

  This pane narrows the live session to the selected Build Order's members. A
  materialized summary will provide cross-session reporting without reparsing
  retained telemetry on each refresh.

  Two things follow from that scope and are stated in the copy rather than left
  for the reader to assume. Every time axis is elapsed *active* time with the
  idle stretches between sessions elided, so a three-week build reads in the
  hours it actually ran. And the daemon/executor baseline is shared orchestration
  overhead for whatever else ran alongside, not cost this build incurred alone.

  The pane is read-only: the interactive legend, sort, and range controls belong
  to the live page, which owns those events.
  """

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.Analytics.{Charts, Presenter, Styles}

  attr(:scope, :map, required: true)
  attr(:model, :any, default: nil)
  attr(:unavailable, :any, default: nil)
  attr(:loading, :boolean, default: false)
  attr(:time_domain, :any, default: nil)

  slot(:inner_block)

  @spec build_order_analytics(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_analytics(assigns) do
    assigns =
      assigns
      |> assign(:selected, selected_keys(assigns.model))
      |> assign(:chart_model, chart_model(assigns.model, assigns.time_domain))
      |> assign(:state, pane_state(assigns))

    ~H"""
    <section class="bo-analytics analytics-root" aria-labelledby="build-order-analytics-title">
      {Phoenix.HTML.raw("<style>" <> Styles.css() <> "</style>")}

      <div class="an-controls">
        <div>
          <h4 id="build-order-analytics-title" class="an-card-title">Analytics</h4>
        </div>
      </div>

      <div :if={!is_nil(@chart_model) and !is_nil(@time_domain)} class="an-zoombar" role="status">
        <span>Zoomed to {Charts.time_domain_label(@chart_model, @time_domain)}</span>
        <button type="button" phx-click="reset-time-domain">Reset</button>
      </div>

      <div :if={not is_nil(@state)} class="an-empty" role="status">
        <p><b>{@state.title}</b></p>
        <p>{@state.message}</p>
      </div>

      <div :if={not is_nil(@model)} class="an-kpis">
        <div :for={k <- kpi_items(@model, @scope)} class={["an-kpi", k.tone]}>
          <span class="an-kpi-label">{k.label}</span>
          <span class="an-kpi-val">{k.val}</span>
          <span class="an-kpi-sub">{k.sub}</span>
        </div>
      </div>

      <div :if={not is_nil(@model)} class="an-grid">
        <section class="an-card wide scroll">
          <div class="an-card-head">
            <div>
              <h5 class="an-card-title">Member lifecycle</h5>
              <p class="an-card-sub">Every member ticket observed this session — the wait rail into a work bar coloured by status, capped by an end marker.</p>
            </div>
          </div>
          <div id="build-order-gantt-chart" class="an-chart" phx-hook="TimeBrush">{Phoenix.HTML.raw(Charts.gantt(@chart_model))}</div>
        </section>

        <section class="an-card wide">
          <div class="an-card-head">
            <div>
              <h5 class="an-card-title">Per-member CPU</h5>
              <p class="an-card-sub">Stacked CPU over this session's active build time. The baseline layer is daemon/executor overhead shared with anything else running in the session, not cost this build incurred alone.</p>
            </div>
          </div>
          <div id="build-order-cpu-chart" class="an-chart" phx-hook="TimeBrush">{Phoenix.HTML.raw(Charts.cpu_stack(@chart_model, @selected))}</div>
        </section>

        <section class="an-card">
          <div class="an-card-head">
            <div>
              <h5 class="an-card-title">Concurrency vs cap</h5>
              <p class="an-card-sub">Members running at once against the global cap. The shaded band is capacity that went to something other than this build.</p>
            </div>
          </div>
          <div id="build-order-concurrency-chart" class="an-chart" phx-hook="TimeBrush">{Phoenix.HTML.raw(Charts.concurrency(@chart_model))}</div>
        </section>

        <section class="an-card">
          <div class="an-card-head">
            <div>
              <h5 class="an-card-title">Memory over active time</h5>
              <p class="an-card-sub">Aggregate resident memory for this build's members against the host ceiling.</p>
            </div>
          </div>
          <div id="build-order-memory-chart" class="an-chart" phx-hook="TimeBrush">{Phoenix.HTML.raw(Charts.memory(@chart_model))}</div>
        </section>

        <section class="an-card scroll">
          <div class="an-card-head">
            <div>
              <h5 class="an-card-title">Cost per member</h5>
              <p class="an-card-sub">CPU-seconds burned per member ticket in this session.</p>
            </div>
          </div>
          <div class="an-chart">{Phoenix.HTML.raw(Charts.cost(@model, @selected, :cpu))}</div>
        </section>

        <section class="an-card">
          <div class="an-card-head">
            <div>
              <h5 class="an-card-title">Burn-up</h5>
              <p class="an-card-sub">Members merged against the Build Order's full membership — including members that have not run yet.</p>
            </div>
          </div>
          <div id="build-order-burnup-chart" class="an-chart" phx-hook="TimeBrush">{Phoenix.HTML.raw(Charts.burnup(@chart_model))}</div>
        </section>
      </div>

      {render_slot(@inner_block)}
    </section>
    """
  end

  defp selected_keys(nil), do: MapSet.new()
  defp selected_keys(model), do: MapSet.new(model.actors, & &1.key)

  defp chart_model(nil, _time_domain), do: nil
  defp chart_model(model, time_domain), do: Charts.with_time_domain(model, time_domain)

  defp kpi_items(model, scope) do
    k = model.kpis

    [
      %{label: "Sessions", val: k.sessions, sub: "daemon boots observed", tone: nil},
      %{label: "Active time", val: hours(k.active_ms), sub: "idle gaps elided", tone: nil},
      %{label: "CPU burned", val: "#{k.cpu_hours}h", sub: "this session", tone: nil},
      %{label: "Peak concurrency", val: k.peak_conc, sub: "of #{Presenter.cap_label(model)}", tone: nil},
      %{label: "Members merged", val: "#{k.done} / #{k.total}", sub: "#{k.done_pct}% complete", tone: nil},
      %{
        label: "Capacity elsewhere",
        val: Presenter.wasted_slot_hours_label(k.wasted_slot_hours),
        sub: "slots not on #{member_word(scope)}",
        tone: "block"
      }
    ]
  end

  defp member_word(%{total: total}) when total > 0, do: "these #{total} members"
  defp member_word(_scope), do: "this build"

  # The one banner the pane can show, or `nil` when the charts speak for
  # themselves. A retained model wins over a loading flag so a background refresh
  # never replaces charts the operator is reading with a spinner.
  defp pane_state(%{model: model}) when not is_nil(model), do: nil

  defp pane_state(%{loading: true}) do
    state("Reading run telemetry", "Reducing the durable telemetry stream for this build's members.")
  end

  defp pane_state(%{scope: %{state: :empty_build}}) do
    state("No members yet", "This Build Order has no direct members, so there is nothing to aggregate.")
  end

  defp pane_state(%{scope: %{state: :unscopable, rejected: rejected}}) do
    state(
      "Members cannot be scoped",
      "#{rejected} member(s) have no joinable repository identity, so telemetry cannot be attributed to them."
    )
  end

  defp pane_state(%{scope: %{state: :pending}}) do
    state("Loading Build Order", "Waiting for a validated member set before reading telemetry.")
  end

  defp pane_state(%{scope: %{state: scope_state}}) when scope_state in [:invalid, :graph_unavailable, :none] do
    state(
      "Analytics unavailable",
      "The selected member graph is unavailable, so telemetry cannot be scoped to this build."
    )
  end

  defp pane_state(%{unavailable: :no_telemetry}) do
    state(
      "No telemetry for this Build Order yet",
      "No member of this Build Order has run with telemetry enabled yet. This pane populates once one does."
    )
  end

  defp pane_state(%{unavailable: reason}) when not is_nil(reason) do
    state("Telemetry unavailable", "The durable telemetry stream could not be read.")
  end

  defp pane_state(_assigns) do
    state("No telemetry for this Build Order yet", "This pane populates once a member ticket runs with telemetry enabled.")
  end

  defp state(title, message), do: %{title: title, message: message}

  defp hours(ms) when is_number(ms) and ms > 0, do: "#{Float.round(ms / 3_600_000, 1)}h"
  defp hours(_ms), do: "0h"
end
