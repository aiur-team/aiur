defmodule AiurWeb.OperatorControlCenter.FleetTable do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.{FleetFilters, Overview}

  attr(:fleet, :map, required: true)
  attr(:decisions, :list, default: [])
  attr(:now, :any, required: true)
  attr(:filters, :any, default: FleetFilters.default())

  @spec fleet_table(map()) :: Phoenix.LiveView.Rendered.t()
  def fleet_table(assigns) do
    assigns =
      assigns
      |> assign(:rows, FleetFilters.visible_rows(assigns.fleet, assigns.filters))
      |> assign(:total_rows, length(FleetFilters.rows(assigns.fleet)))
      |> assign(:decision_links, decision_links(assigns.decisions))

    ~H"""
    <section class="section-card fleet-card" aria-labelledby="fleet-title">
      <h2 id="fleet-title" class="sr-only">Fleet state</h2>
      <Overview.fleet_overview fleet={@fleet} filters={@filters} />

      <div :if={@total_rows == 0} class="empty-state">No tracker-active tickets are in the fleet projection.</div>
      <div :if={@total_rows > 0 and @rows == []} class="empty-state">No units match the selected fleet filters.</div>
      <div :if={@rows != []} class="table-wrap">
        <table class="fleet-table">
          <thead>
            <tr>
              <th>Ticket</th>
              <th>State</th>
              <th>Waiting</th>
              <th>Latest</th>
              <th>Elapsed</th>
              <th>Commands</th>
              <th><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @rows}
              class={["fleet-row", row_class(row)]}
              phx-click={row.bucket == :running && "show-agent-log"}
              phx-value-issue={row.bucket == :running && row.issue_identifier}
            >
              <td data-label="Ticket">
                <div class="fleet-ticket">
                  <span class="fleet-state-glyph" title={humanize(row.work_state)}>{state_glyph(row)}</span>
                  <span>
                    <strong>{row.title || row.issue_identifier}</strong>
                    <span class="ticket-id">{row.issue_identifier}</span>
                  </span>
                </div>
              </td>
              <td data-label="State">
                <span class={state_chip_class(row.state)}>{humanize(row.state || row.bucket)}</span>
                <span class="fleet-latest-meta">{ci_review(row)}</span>
              </td>
              <td data-label="Waiting"><span class={waiting_chip_class(row.waiting_reason)}>{humanize(row.waiting_reason)}</span></td>
              <td data-label="Latest">
                <span class="fleet-latest" title={latest(row)}>{latest(row)}</span>
                <span :if={row[:last_event_at]} class="fleet-latest-meta mono">{row.last_event_at}</span>
              </td>
              <td class="mono num" data-label="Elapsed">{runtime(row, @now)}</td>
              <td class="num" data-label="Commands">
                <span :if={row.open_decision_count > 0} class="chip attention">! {row.open_decision_count}</span>
                <span :if={row.open_decision_count == 0} class="muted">—</span>
              </td>
              <td data-label="Actions">
                <div class="fleet-actions">
                  <.link
                    :if={decision_id = @decision_links[row.issue_identifier]}
                    patch={"/decisions/#{decision_id}"}
                    class="fleet-action decision"
                    title="Open pending Command"
                    aria-label="Open pending Command"
                    onclick="event.stopPropagation()"
                  >!</.link>
                  <button
                    :if={row.bucket == :running}
                    type="button"
                    class="fleet-action"
                    phx-click="show-agent-log"
                    phx-value-issue={row.issue_identifier}
                    title="Read agent conversation"
                    aria-label="Read agent conversation"
                    onclick="event.stopPropagation()"
                  >⌁</button>
                  <a
                    :if={trusted_url(row[:url])}
                    class="fleet-action"
                    href={trusted_url(row[:url])}
                    target="_blank"
                    rel="noopener noreferrer"
                    title="Open tracker ticket"
                    aria-label="Open tracker ticket"
                    onclick="event.stopPropagation()"
                  >↗</a>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp decision_links(decisions) do
    Enum.reduce(decisions, %{}, fn decision, links ->
      case decision.ticket[:identifier] do
        identifier when is_binary(identifier) -> Map.put_new(links, identifier, decision.decision_id)
        _identifier -> links
      end
    end)
  end

  defp row_class(%{waiting_reason: :unresponsive}), do: "blocked-row"
  defp row_class(%{open_decision_count: count}) when count > 0, do: "awaiting-row"
  defp row_class(_row), do: nil

  defp state_glyph(%{waiting_reason: :unresponsive}), do: "!"
  defp state_glyph(%{work_state: state}) when state in [:working, "working"], do: "●"
  defp state_glyph(%{work_state: state}) when state in [:paused, "paused"], do: "Ⅱ"
  defp state_glyph(%{bucket: :retrying}), do: "↻"
  defp state_glyph(_row), do: "○"

  defp latest(row), do: row[:last_message] || humanize(row[:last_event]) || "No recent agent update"

  defp runtime(%{runtime_seconds: seconds}, _now) when is_integer(seconds), do: format_duration(seconds)

  defp runtime(%{started_at: started_at}, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, datetime, _offset} -> format_duration(max(DateTime.diff(now, datetime, :second), 0))
      _error -> "—"
    end
  end

  defp runtime(_row, _now), do: "—"

  defp format_duration(seconds) do
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    if hours > 0, do: "#{hours}h #{minutes}m", else: "#{minutes}m"
  end

  defp state_chip_class(state) do
    value = state |> to_string() |> String.downcase()

    cond do
      String.contains?(value, ["fail", "block", "error"]) -> "chip blocking"
      String.contains?(value, ["run", "progress", "active"]) -> "chip good"
      true -> "chip"
    end
  end

  defp waiting_chip_class(:active), do: "chip good"
  defp waiting_chip_class(:unresponsive), do: "chip blocking"
  defp waiting_chip_class(_reason), do: "chip attention"

  defp ci_review(%{ci: %{decision: decision, pr_number: number} = ci, review: review}) do
    prefix = if number, do: "PR ##{number}", else: "CI"
    draft_marker = if Map.get(ci, :draft?), do: "DRAFT ", else: ""

    "#{prefix} #{draft_marker}#{humanize(decision)} · #{review_label(review)}"
  end

  defp ci_review(%{review: review}), do: review_label(review)
  defp ci_review(_row), do: "Review not started"
  defp review_label(:awaiting), do: "Review awaiting"
  defp review_label(_review), do: "Review not started"

  defp trusted_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> value
      _uri -> nil
    end
  end

  defp trusted_url(_value), do: nil
  defp humanize(nil), do: nil
  defp humanize(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
