defmodule AiurWeb.OperatorControlCenter.DecisionTimeline do
  @moduledoc false
  use Phoenix.Component

  @labels %{
    requested: "Requested",
    request_attributed: "Request recorded",
    enriched: "Context updated",
    routed: "Routed",
    escalated: "Escalated",
    executor_acknowledged: "Executor acknowledged",
    human_needed: "Human needed",
    answer_recorded: "Answer recorded",
    revision_recorded: "Revision recorded",
    delivered: "Delivered",
    native_released: "Native request released",
    requester_notified: "Requester notified"
  }
  @causes %{
    executor_originated: "Requested by the Executor",
    executor_offline: "Executor offline",
    executor_stalled: "Executor stalled",
    authority_human_required: "Human authority required",
    executor_not_answerable: "Executor cannot answer",
    executor_ack_timeout: "Executor acknowledgement timed out",
    executor_answer_timeout: "Executor answer timed out",
    executor_escalated: "Escalated by the Executor"
  }

  attr(:audit_history, :any, default: :unavailable)
  attr(:now, :any, default: nil)

  @spec decision_timeline(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_timeline(assigns) do
    assigns = assign(assigns, :now, assigns.now || DateTime.utc_now())

    ~H"""
    <section class="detail-block" aria-label="Escalation timeline">
      <h4>Escalation timeline</h4>
      <ol :if={is_list(@audit_history)} class="decision-timeline">
        <li :for={entry <- @audit_history}>
          <strong>{Map.get(labels(), entry.type, "Updated")}</strong>
          <span :if={entry.cause}>{cause_label(entry.cause)}</span>
          <time class="timeline-time mono" datetime={iso(entry.at)}>{iso(entry.at)}</time>
          <span>{age(entry.at, @now)}</span>
        </li>
      </ol>
      <p :if={@audit_history == []} class="empty-state compact">No durable Command events were recorded.</p>
      <p :if={not is_list(@audit_history)} role="status">Timeline unavailable. Recorded events could not be loaded.</p>
    </section>
    """
  end

  defp labels, do: @labels
  defp cause_label(cause), do: Map.get(@causes, cause, "Unknown cause")
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp age(%DateTime{} = at, now) do
    seconds = max(DateTime.diff(now, at), 0)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
