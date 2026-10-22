defmodule Aiur.ExecutorSweep.StateLabels do
  @moduledoc """
  One summary finding for open tickets without exactly one agent state label
  (#5119). Parked, triage, human-owned and epic tickets are skipped: nothing
  dispatches them, so their missing state label is expected.
  """

  @state_labels ~w(todo in-progress ci-wait human-review rework error done)

  @doc "Takes tickets with agent-prefix-stripped `labels`; returns zero or one finding."
  @spec findings([map()]) :: [map()]
  def findings(tickets) do
    case for(ticket <- tickets, not excluded?(ticket.labels), states = Enum.filter(ticket.labels, &(&1 in @state_labels)), length(states) != 1, do: {ticket, states}) do
      [] ->
        []

      invalid ->
        {oldest, states} = Enum.min_by(invalid, &age_key/1)
        count = length(invalid)

        [
          %{
            kind: "invalid_state_labels",
            priority: 9,
            age_ms: 0,
            action: "Review the open tickets and leave exactly one agent state label on each.",
            message: "#{count} open ticket(s) have an invalid count of agent state labels (oldest ticket ##{oldest.number || "?"}, #{length(states)} labels).",
            ticket: oldest.number,
            ticket_count: count,
            state_labels: states
          }
        ]
    end
  end

  defp excluded?(labels) do
    Enum.any?(labels, fn label ->
      label in ["parked", "needs-triage", "human:todo"] or String.downcase(label) == "epic" or String.starts_with?(String.downcase(label), "epic:")
    end)
  end

  # Oldest by creation time; tickets without one sort after, by number.
  defp age_key({ticket, _states}) do
    case ticket.created_at && DateTime.from_iso8601(to_string(ticket.created_at)) do
      {:ok, created_at, _offset} -> {0, DateTime.to_unix(created_at, :millisecond), ticket.number || 0}
      _ -> {1, 0, ticket.number || 0}
    end
  end
end
