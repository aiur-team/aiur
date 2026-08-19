defmodule AiurWeb.OperatorControlCenter.RunSummary do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.RunSummaryPresenter

  attr(:view, :map, required: true)
  attr(:announcement, :string, default: nil)

  @spec run_summary(map()) :: Phoenix.LiveView.Rendered.t()
  def run_summary(assigns) do
    view = assigns.view
    assigns = assign(assigns, :state, Map.get(view, :state, :loading))

    ~H"""
    <section class="section-card run-summary-card" aria-labelledby="run-summary-title">
      <header class="section-header run-summary-header">
        <div>
          <p class="section-eyebrow">Aiur run</p>
          <h2 id="run-summary-title" tabindex="-1">Current run</h2>
        </div>
        <div class="run-summary-badges" :if={@state in [:ready, :stale]}>
          <span class={["run-summary-badge", "health-#{@view.health.status}"]}>
            Health: {@view.health.label}
          </span>
          <span class={["run-summary-badge", "freshness-#{@view.freshness.status}"]}>
            {@view.freshness.label}
          </span>
        </div>
      </header>

      <p
        id="run-summary-status"
        class="sr-only"
        role="status"
        aria-live="polite"
        aria-atomic="true"
      >
        {@announcement}
      </p>

      <div :if={@state == :loading} class="run-summary-state empty-state">
        Loading current-run summary…
      </div>

      <div :if={@state == :empty} class="run-summary-state empty-state">
        No active Aiur run.
      </div>

      <div :if={@state == :unavailable} class="run-summary-state error-card" role="alert">
        <h3>Current-run summary unavailable</h3>
        <p>{unavailable_message(@view)}</p>
      </div>

      <div :if={@state in [:ready, :stale]} class="run-summary-grid">
        <section class="run-summary-panel" aria-labelledby="run-summary-counts-title">
          <h3 id="run-summary-counts-title">Units</h3>
          <dl class="run-summary-facts">
            <div class="run-summary-fact"><dt>Live</dt><dd>{@view.counts.live}</dd></div>
            <div class="run-summary-fact"><dt>Remaining</dt><dd>{@view.counts.remaining}</dd></div>
            <div class="run-summary-fact"><dt>Succeeded</dt><dd>{@view.counts.successful_terminal}</dd></div>
            <div class="run-summary-fact"><dt>Non-work terminal</dt><dd>{@view.counts.non_work_terminal}</dd></div>
            <div class="run-summary-fact"><dt>Unknown state</dt><dd>{@view.counts.unknown_state}</dd></div>
            <div class="run-summary-fact"><dt>Total in scope</dt><dd>{@view.counts.total}</dd></div>
          </dl>
        </section>

        <section class="run-summary-panel" aria-labelledby="run-summary-progress-title">
          <h3 id="run-summary-progress-title">Weighted progress</h3>
          {progress_body(assigns)}
        </section>

        <section class="run-summary-panel" aria-labelledby="run-summary-time-title">
          <h3 id="run-summary-time-title">Elapsed and ETA</h3>
          <dl class="run-summary-facts">
            <div class="run-summary-fact">
              <dt>Wall elapsed</dt>
              <dd>{@view.elapsed.label}</dd>
            </div>
            <div class="run-summary-fact">
              <dt>ETA</dt>
              <dd>{@view.eta.label}</dd>
            </div>
            <div class="run-summary-fact" :if={@view.eta.status == :available}>
              <dt>ETA confidence</dt>
              <dd>{@view.eta.confidence} ({@view.eta.sample_count} samples)</dd>
            </div>
            <div class="run-summary-fact">
              <dt>ETA formula</dt>
              <dd>{@view.eta.formula_version || "—"}</dd>
            </div>
          </dl>
        </section>
      </div>
    </section>
    """
  end

  # Weighted progress body: a determinate progressbar with aria-valuenow only
  # when the daemon reports an exact percentage. A known lower bound names its
  # coverage without an implied value; zero eligible weight is named too.
  defp progress_body(%{view: %{progress: %{kind: :exact, percent: percent}}} = assigns)
       when is_integer(percent) do
    assigns = assign(assigns, :percent, percent)

    ~H"""
    <div
      class="run-summary-progress"
      role="progressbar"
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={@percent}
      aria-label="Weighted run progress"
    >
      <span class="run-summary-progress-track" aria-hidden="true">
        <span
          class={progress_fill_class(@percent)}
          style={"width: #{@percent}%"}
        >
        </span>
      </span>
      <span class="run-summary-progress-value">{@percent}% complete (exact)</span>
    </div>
    """
  end

  defp progress_body(%{view: %{progress: %{kind: :lower_bound}}} = assigns) do
    ~H"""
    <div class="run-summary-progress run-summary-progress-partial">
      <p class="run-summary-progress-value">
        At least {@view.progress.lower_bound_percent}% complete (lower bound)
      </p>
      <p class="run-summary-progress-coverage">
        {coverage_text(@view.progress.coverage_percent)}
      </p>
    </div>
    """
  end

  defp progress_body(%{view: %{progress: %{kind: :partial}}} = assigns) do
    ~H"""
    <div class="run-summary-progress run-summary-progress-partial">
      <p class="run-summary-progress-value">
        {@view.progress.display_percent_label} complete from current inputs
      </p>
      <p class="run-summary-progress-coverage">
        {@view.progress.current_members_label}; {@view.progress.fact_status_detail}.
      </p>
    </div>
    """
  end

  defp progress_body(%{view: %{progress: %{kind: :pending}}} = assigns) do
    ~H"""
    <div class="run-summary-progress run-summary-progress-partial">
      <p class="run-summary-progress-value">{@view.progress.progress_status_label}.</p>
      <p class="run-summary-progress-coverage">
        {@view.progress.current_members_label}; {@view.progress.fact_status_detail}.
      </p>
    </div>
    """
  end

  defp progress_body(assigns) do
    ~H"""
    <div class="run-summary-progress run-summary-progress-partial">
      <p class="run-summary-progress-value">No weighted progress — zero eligible weight.</p>
    </div>
    """
  end

  defp coverage_text(nil), do: "Coverage unknown."
  defp coverage_text(percent), do: "#{percent}% of eligible weight measured."

  defp progress_fill_class(percent) do
    ["run-summary-progress-fill", if(percent == 100, do: "is-complete")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp unavailable_message(view) do
    case Map.get(view, :health, %{})[:reasons] do
      [_ | _] = reasons -> "Summary facts are unavailable: #{RunSummaryPresenter.reasons_text(reasons)}."
      _ -> "The current-run summary cannot be read right now."
    end
  end
end
