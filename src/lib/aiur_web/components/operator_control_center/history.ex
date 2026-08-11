defmodule AiurWeb.OperatorControlCenter.History do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.{DecisionPath, HistoryRowPresenter}

  attr(:entries, :list, required: true)
  attr(:decisions, :list, default: [])
  attr(:provider_health, :any, default: :ok)
  attr(:visible_count, :integer, default: 10)
  attr(:hidden_decision_ids, :list, default: [])

  @spec history(map()) :: Phoenix.LiveView.Rendered.t()
  def history(assigns) do
    visible_count = max(assigns.visible_count, 10)
    rows = assigns.decisions |> HistoryRowPresenter.rows(assigns.entries, assigns.hidden_decision_ids) |> Enum.take(visible_count + 1)
    {visible_rows, overflow} = Enum.split(rows, visible_count)

    assigns =
      assigns
      |> assign(:rows, visible_rows)
      |> assign(:empty?, visible_rows == [])
      |> assign(:has_more?, overflow != [])

    ~H"""
    <section class="recent-section" aria-labelledby="decision-history-title">
      <p class="recent-subtitle" id="decision-history-title">Command history</p>
      <div :if={@provider_health == :unavailable} class="empty-state compact">History provider is currently unavailable.</div>
      <div :if={@provider_health == :degraded} class="empty-state compact">
        Command history is degraded; showing the last validated prefix.
      </div>
      <div :if={@provider_health == :ok and @empty?} class="empty-state compact">No Command actions have been recorded.</div>
      <div :if={@rows != []} class="command-history-wrap">
        <table class="command-history-table">
          <thead>
            <tr>
              <th scope="col">Command</th>
              <th scope="col">Outcome</th>
              <th scope="col">Actor</th>
              <th scope="col">Time</th>
              <th scope="col">Details</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} data-severity={row.style}>
              <td class="history-command-cell">
                <span class="ticket-id">{row.ticket_identifier}</span>
                <.link patch={DecisionPath.detail(row.decision_id, :all)}>{row.question}</.link>
              </td>
              <td><span class={["history-outcome", row.style]}>{row.outcome}</span></td>
              <td>
                <span class="actor-tag">
                  <span class={["actor-glyph", actor_class(row.actor)]}>{actor_code(row.actor)}</span>{actor_label(row.actor)}
                </span>
              </td>
              <td class="timeline-time mono">{format_datetime(row.changed_at)}</td>
              <td class="history-details-cell">
                <p :if={row.detail}>{row.detail}</p>
                <div class="history-detail-tags">
                  <.result_chip label="dispatch" result={row.dispatch_result} />
                  <.result_chip label="ack" result={row.acknowledgement_result} />
                  <.result_chip label="revision" result={row.revision_result} />
                  <span :if={is_integer(row.confidence)} class="chip super">{row.confidence}% confidence</span>
                  <span :if={row.provenance_label} class="chip mono">{row.provenance_label}</span>
                  <span :if={row.superseded_by} class="chip attention">
                    Superseded by <span class="mono">{row.superseded_by}</span>
                  </span>
                  <span :if={row.revision_of} class="chip super">
                    Supersedes <span class="mono">{row.revision_of}</span>
                  </span>
                  <span :if={row.revised?} class="chip super">Revised</span>
                  <span :if={row.follow_up_required? and not row.follow_up_handled?} class="chip blocking">
                    Follow-up required
                  </span>
                  <span :if={row.follow_up_handled?} class="chip good">Follow-up handled</span>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <button :if={@has_more?} type="button" class="btn secondary command-history-more" phx-click="load-command-history">
        Load more
      </button>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:result, :any, required: true)

  defp result_chip(assigns) do
    ~H"""
    <span :if={@result} class={["chip", result_tone(@result)]}>{@label}: {humanize(@result)}</span>
    """
  end

  defp result_tone(result) when result in [:ok, :acknowledged, :delivered, "ok", "acknowledged", "delivered"], do: "good"
  defp result_tone(result) when result in [:failed, :delivery_failed, "failed", "delivery_failed"], do: "blocking"
  defp result_tone(result) when result in [:no_longer_applicable, "no_longer_applicable"], do: "blocking"
  defp result_tone(result) when result in [:dispatched, "dispatched"], do: "good"
  defp result_tone(_result), do: "attention"

  defp actor_label(%{label: label}) when is_binary(label), do: label
  defp actor_label(%{type: type}), do: humanize(type)
  defp actor_label(_actor), do: "Unknown source"
  defp actor_code(%{type: :human_operator}), do: "OP"
  defp actor_code(%{type: :supervising_agent}), do: "SA"
  defp actor_code(%{type: :ticket_agent}), do: "TA"
  defp actor_code(_actor), do: "··"
  defp actor_class(%{type: :supervising_agent}), do: "supervising"
  defp actor_class(%{type: :ticket_agent}), do: "ticket"
  defp actor_class(_actor), do: "human"
  defp humanize(nil), do: "System"
  defp humanize(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp format_datetime(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp format_datetime(value) when is_binary(value), do: value
  defp format_datetime(_value), do: "unknown"
end
