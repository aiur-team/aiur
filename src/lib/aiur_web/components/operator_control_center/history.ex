defmodule AiurWeb.OperatorControlCenter.History do
  @moduledoc false

  use Phoenix.Component

  attr(:entries, :list, required: true)
  attr(:provider_health, :any, default: :ok)

  @spec history(map()) :: Phoenix.LiveView.Rendered.t()
  def history(assigns) do
    ~H"""
    <section class="recent-section" aria-labelledby="decision-history-title">
      <p class="recent-subtitle" id="decision-history-title">Decision history</p>
      <div :if={@provider_health == :unavailable} class="empty-state compact">History provider is currently unavailable.</div>
      <div :if={@provider_health == :degraded} class="empty-state compact">
        Decision history is degraded; showing the last validated prefix.
      </div>
      <div :if={@provider_health == :ok and @entries == []} class="empty-state compact">No decision actions have been recorded.</div>
      <div class="history-list">
        <article :for={entry <- @entries} class="history-item">
          <span class="severity-rail"></span>
          <header>
            <span class="ticket-id">{ticket_identifier(entry.ticket) || entry.decision_id}</span>
            <strong>{entry.question || humanize(entry.change)}</strong>
          </header>
          <p :if={entry.choice} class="history-choice">Choice: <b>{entry.choice}</b></p>
          <p :if={entry.rationale} class="history-rationale">{entry.rationale}</p>
          <footer>
            <span class="actor-tag"><span class={["actor-glyph", actor_class(entry.actor)]}>{actor_code(entry.actor)}</span>{actor_label(entry.actor)}</span>
            <span class="timeline-time mono">{format_datetime(entry.changed_at)}</span>
            <.result_chip label="dispatch" result={entry.dispatch_result} />
            <.result_chip label="ack" result={entry.acknowledgement_result} />
            <.result_chip label="revision" result={Map.get(entry, :revision_result)} />
            <span :if={entry.revised?} class="chip super">Revised</span>
            <span :if={entry.follow_up_required and not entry.follow_up_handled} class="chip blocking">Follow-up required</span>
            <span :if={entry.follow_up_handled} class="chip good">Follow-up handled</span>
          </footer>
        </article>
      </div>
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

  defp ticket_identifier(%{identifier: identifier}), do: identifier
  defp ticket_identifier(identifier) when is_binary(identifier), do: identifier
  defp ticket_identifier(_ticket), do: nil
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
