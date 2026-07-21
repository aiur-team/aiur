defmodule AiurWeb.OperatorControlCenter.CurrentRunOutcomes do
  @moduledoc """
  Renders the Units-page `Finished this run` region from a presented DASH-032
  current-run outcome view. Cards are keyed by outcome id so live inserts and
  enrichment keep focus, scroll, and screen-reader stability. This component
  displays only the presented facts; it never qualifies, filters, or classifies
  outcomes.
  """

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.CurrentRunOutcomesPresenter

  attr(:view, :map, required: true)
  attr(:announcement, :string, default: nil)

  @spec current_run_outcomes(map()) :: Phoenix.LiveView.Rendered.t()
  def current_run_outcomes(assigns) do
    view = assigns.view
    assigns = assign(assigns, :state, Map.get(view, :state, :loading))

    ~H"""
    <section
      id="current-run-outcomes"
      class="section-card current-run-outcomes-card"
      aria-labelledby="current-run-outcomes-title"
    >
      <header class="section-header current-run-outcomes-header">
        <div>
          <p class="section-eyebrow">Current run</p>
          <h2 id="current-run-outcomes-title" tabindex="-1">{@view.heading}</h2>
          <p>Repository merges from this run.</p>
        </div>
        <div class="recent-subtitle-actions">
          <span :if={@state == :partial} class="chip attention">Partial</span>
          <span :if={@state == :stale} class="chip attention">Stale</span>
          <span :if={@view.truncated?} class="chip">{truncation_label(@view)}</span>
        </div>
      </header>

      <p
        id="current-run-outcomes-status"
        class="sr-only"
        role="status"
        aria-live="polite"
        aria-atomic="true"
      >
        {@announcement}
      </p>

      <div :if={@state == :loading} class="empty-state compact">
        Loading current-run outcomes…
      </div>

      <div :if={@state == :new_run} class="empty-state compact">
        A new run is starting. Previous-run outcomes are cleared and none have qualified yet.
      </div>

      <div :if={@state == :unavailable} class="current-run-outcomes-state error-card" role="alert">
        <h3>Current-run outcomes unavailable</h3>
        <p>{unavailable_message(@view)}</p>
      </div>

      <div :if={@state == :stale} class="current-run-outcomes-state readonly-banner" role="status">
        <span aria-hidden="true">◉</span>
        <span>
          <b>Stale outcomes.</b>
          Showing the last validated snapshot for this run; a refresh could not be confirmed.
        </span>
      </div>

      <div :if={@state == :partial} class="empty-state compact">
        These outcomes may be incomplete; a source was degraded, truncated, or still reconciling.
      </div>

      <div :if={@state == :healthy_empty} class="empty-state compact">
        No repository merges have finished this run yet.
      </div>

      <div :if={@view.outcomes != []} class="outcome-list current-run-outcome-list">
        <article
          :for={outcome <- @view.outcomes}
          id={outcome.id}
          class="outcome-card"
          data-severity="good"
        >
          <span class="severity-rail"></span>
          <header>
            <span :if={outcome.number} class="pull-request-number mono">PR #{outcome.number}</span>
            <span class="chip good"><span class="chip-dot"></span>Merged</span>
            <span :if={outcome.ticket_identity} class="chip">{outcome.ticket_identity}</span>
          </header>
          <h3>{outcome.title || "Untitled pull request"}</h3>
          <p :if={outcome.summary}>{outcome.summary}</p>
          <footer>
            <span class="timeline-time mono">{format_datetime(outcome.merged_at)}</span>
            <span :if={outcome.live_observed?} class="chip accent">Observed live</span>
            <span :if={outcome.backfilled?} class="chip">Backfilled</span>
            <span :if={outcome.observed_run_id} class="chip">Observer run {outcome.observed_run_id}</span>
            <a
              :if={outcome.url}
              class="link-pill"
              href={outcome.url}
              target="_blank"
              rel="noopener noreferrer"
            >View PR ↗</a>
          </footer>
        </article>
      </div>
    </section>
    """
  end

  defp truncation_label(%{limit: limit}) when is_integer(limit) and limit > 0, do: "Showing first #{limit}"
  defp truncation_label(_view), do: "Truncated"

  defp unavailable_message(view) do
    case Map.get(view, :health, %{})[:reasons] do
      [_ | _] = reasons ->
        "Outcome facts are unavailable: #{CurrentRunOutcomesPresenter.reasons_text(reasons)}."

      _ ->
        "The current-run outcomes cannot be read right now."
    end
  end

  defp format_datetime(%DateTime{} = datetime),
    do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp format_datetime(value) when is_binary(value), do: value
  defp format_datetime(_value), do: "unknown"
end
