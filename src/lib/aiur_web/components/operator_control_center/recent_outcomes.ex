defmodule AiurWeb.OperatorControlCenter.RecentOutcomes do
  @moduledoc false

  use Phoenix.Component

  attr(:outcomes, :list, required: true)
  attr(:provider_health, :any, default: :ok)
  attr(:reconciliation, :any, default: nil)

  def recent_outcomes(assigns) do
    ~H"""
    <section id="recent-outcomes" class="recent-section" aria-labelledby="recent-outcomes-title">
      <div class="recent-subtitle-row">
        <p class="recent-subtitle" id="recent-outcomes-title">Merged this run</p>
        <span :if={partial?(@reconciliation)} class="chip attention">Partial reconciliation</span>
      </div>
      <div :if={@provider_health != :ok} class="empty-state compact">Recent outcomes provider is currently unavailable.</div>
      <div :if={@provider_health == :ok and @outcomes == []} class="empty-state compact">No merged pull requests are recorded for this run.</div>
      <div class="outcome-list">
        <article :for={outcome <- @outcomes} class="outcome-card">
          <span class="severity-rail"></span>
          <header>
            <span class="pull-request-number mono">PR #{outcome.number}</span>
            <span class="chip good"><span class="chip-dot"></span>Merged</span>
            <span :if={outcome.ticket_id} class="chip">{outcome.ticket_id}</span>
          </header>
          <h3>{outcome.title || "Untitled pull request"}</h3>
          <p :if={outcome.summary}>{outcome.summary}</p>
          <footer>
            <span :if={outcome.merged_by} class="actor-tag"><span class="actor-glyph human">GH</span>{outcome.merged_by}</span>
            <span class="timeline-time mono">{format_datetime(outcome.merged_at)}</span>
            <span :if={outcome.live_observed?} class="chip accent">Observed live</span>
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
