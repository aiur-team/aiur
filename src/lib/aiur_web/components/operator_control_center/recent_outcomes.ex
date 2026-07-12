defmodule AiurWeb.OperatorControlCenter.RecentOutcomes do
  @moduledoc false

  use Phoenix.Component

  attr(:outcomes, :list, required: true)
  attr(:provider_health, :any, default: :ok)
  attr(:reconciliation, :any, default: nil)
  attr(:analytics, :map, required: true)

  @spec recent_outcomes(map()) :: Phoenix.LiveView.Rendered.t()
  def recent_outcomes(assigns) do
    ~H"""
    <section id="recent-outcomes" class="recent-section" aria-labelledby="recent-outcomes-title">
      <div class="recent-subtitle-row">
        <p class="recent-subtitle" id="recent-outcomes-title">Recent repository merges</p>
        <div class="recent-subtitle-actions">
          <span :if={partial?(@reconciliation)} class="chip attention">Partial reconciliation</span>
          <span :if={page_cap(@reconciliation)} class="chip">{page_cap(@reconciliation)}</span>
          <a :if={analytics_path(@analytics)} class="link-pill" href={analytics_path(@analytics)}>
            Open analytics report
          </a>
        </div>
      </div>
      <div :if={@provider_health == :unavailable} class="empty-state compact">
        Recent outcomes provider is currently unavailable.
      </div>
      <div :if={@provider_health == :degraded} class="empty-state compact">
        Recent outcomes are degraded; showing the last validated prefix.
      </div>
      <div :if={@provider_health != :unavailable and @outcomes == []} class="empty-state compact">
        No recent repository merges are recorded.
      </div>
      <div class="outcome-list">
        <article :for={outcome <- @outcomes} class="outcome-card">
          <span class="severity-rail"></span>
          <header>
            <span class="pull-request-number mono">PR #{outcome.number}</span>
            <span class="chip good"><span class="chip-dot"></span>Merged</span>
            <span :if={outcome.ticket_id} class="chip">{outcome.ticket_id}</span>
            <span :if={is_nil(outcome.ticket_id)} class="chip">No ticket attribution</span>
          </header>
          <h3>{outcome.title || "Untitled pull request"}</h3>
          <p :if={outcome.summary}>{outcome.summary}</p>
          <footer>
            <span :if={outcome.merged_by} class="actor-tag"><span class="actor-glyph human">GH</span>{outcome.merged_by}</span>
            <span class="timeline-time mono">{format_datetime(outcome.merged_at)}</span>
            <span :if={outcome.live_observed?} class="chip accent">Observed live</span>
            <span :if={observer_run(outcome)} class="chip">Observer run {observer_run(outcome)}</span>
            <span :if={outcome.backfilled?} class="chip">Backfilled</span>
            <a :if={trusted_url(outcome.url)} class="link-pill" href={trusted_url(outcome.url)} target="_blank" rel="noopener noreferrer">View PR ↗</a>
          </footer>
        </article>
      </div>
    </section>
    """
  end

  defp partial?(%{partial?: value}), do: value == true
  defp partial?(_reconciliation), do: false

  defp page_cap(%{partial?: true, pages_fetched: pages}) when is_integer(pages) and pages > 0,
    do: "#{pages}-page cap"

  defp page_cap(_reconciliation), do: nil

  defp analytics_path(%{available?: true, path: "/analytics"}), do: "/analytics"
  defp analytics_path(_analytics), do: nil

  defp observer_run(%{live_observed?: true, observed_run_id: run_id}) when is_binary(run_id),
    do: String.slice(run_id, 0, 12)

  defp observer_run(_outcome), do: nil

  defp trusted_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> value
      _uri -> nil
    end
  end

  defp trusted_url(_value), do: nil
  defp format_datetime(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp format_datetime(value) when is_binary(value), do: value
  defp format_datetime(_value), do: "unknown"
end
