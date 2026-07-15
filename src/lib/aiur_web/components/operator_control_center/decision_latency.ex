defmodule AiurWeb.OperatorControlCenter.DecisionLatency do
  @moduledoc false

  use Phoenix.Component

  @intervals [
    {:request_to_decision_ms, "Request to Command"},
    {:decision_to_dispatch_ms, "Command to dispatch"},
    {:dispatch_to_delivery_ms, "Dispatch to delivery"},
    {:delivery_to_ack_ms, "Delivery to acknowledgement"},
    {:blocked_time_ms, "Blocked time"}
  ]

  attr(:latency, :map, default: %{status: :missing, snapshot: nil})

  @spec decision_latency(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_latency(assigns) do
    status = Map.get(assigns.latency, :status, :missing)
    snapshot = Map.get(assigns.latency, :snapshot)

    assigns =
      assign(assigns,
        status: status,
        snapshot: snapshot,
        intervals: intervals(snapshot),
        actor: snapshot_value(snapshot, :actor),
        revised?: snapshot_value(snapshot, :revised) == true,
        reminder_count: count(snapshot, :reminder_count),
        attention_count: count(snapshot, :attention_count)
      )

    ~H"""
    <section class="detail-block decision-latency" aria-labelledby="decision-latency-title">
      <h4 id="decision-latency-title">Command latency</h4>

      <p :if={@status == :missing} class="empty-state compact">
        No latency sample has been retained for this Command yet.
      </p>
      <p :if={@status not in [:available, :missing]} class="empty-state compact" role="status">
        Command latency provider is unavailable.
      </p>

      <div :if={@status == :available and is_map(@snapshot)}>
        <dl class="metadata-list decision-latency-list">
          <div :for={{label, value} <- @intervals}>
            <dt>{label}</dt>
            <dd class="mono num">{value}</dd>
          </div>
        </dl>
        <div class="decision-latency-facts" aria-label="Command latency facts">
          <span class="chip">{actor_label(@actor)}</span>
          <span class="chip">{count_label(@reminder_count, "reminder")}</span>
          <span class="chip">{count_label(@attention_count, "attention")}</span>
          <span :if={@revised?} class="chip super">Revised</span>
        </div>
      </div>
    </section>
    """
  end

  defp intervals(snapshot) do
    Enum.map(@intervals, fn {key, label} -> {label, snapshot |> snapshot_value(key) |> format_duration()} end)
  end

  defp snapshot_value(snapshot, key) when is_map(snapshot) do
    Map.get(snapshot, key, Map.get(snapshot, Atom.to_string(key)))
  end

  defp snapshot_value(_snapshot, _key), do: nil

  defp count(snapshot, key) do
    case snapshot_value(snapshot, key) do
      value when is_integer(value) and value >= 0 -> value
      _value -> 0
    end
  end

  defp format_duration(nil), do: "Pending"
  defp format_duration(milliseconds) when is_integer(milliseconds) and milliseconds < 1_000, do: "#{milliseconds} ms"

  defp format_duration(milliseconds) when is_integer(milliseconds) and milliseconds < 60_000 do
    seconds = Float.round(milliseconds / 1_000, 1)
    "#{seconds} s"
  end

  defp format_duration(milliseconds) when is_integer(milliseconds) do
    seconds = div(milliseconds, 1_000)
    minutes = div(seconds, 60)
    remainder = rem(seconds, 60)
    "#{minutes}m #{remainder}s"
  end

  defp format_duration(_value), do: "Pending"

  defp actor_label("human"), do: "Human"
  defp actor_label("supervisor"), do: "Supervisor"
  defp actor_label(_actor), do: "Actor pending"

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(count, noun), do: "#{count} #{noun}s"
end
