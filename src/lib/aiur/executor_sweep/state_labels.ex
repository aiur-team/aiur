defmodule Aiur.ExecutorSweep.StateLabels do
  @moduledoc """
  One summary finding for open tickets without exactly one agent state label
  (#5119). Parked, triage, human-owned and epic tickets are skipped: nothing
  dispatches them, so their missing state label is expected.
  """

  # Mirrors `Aiur.GitHub.Labels` state suffixes: a state missing here is
  # miscounted as an absent label (#5796).
  @state_labels ~w(todo in-progress ci-wait human-review rework merging error done cancelled canceled)

  @spec raw_labels(map()) :: [String.t()]
  def raw_labels(ticket) do
    ticket
    |> Map.get(:labels, Map.get(ticket, "labels", []))
    |> Enum.map(fn label ->
      if is_map(label), do: Map.get(label, :name, Map.get(label, "name", "")), else: label
    end)
    |> Enum.map(&to_string/1)
  end

  @doc "Takes tickets with raw labels; returns zero or one finding for this instance's prefix."
  @spec findings([map()]) :: [map()]
  @spec findings([map()], String.t()) :: [map()]
  def findings(tickets, prefix \\ "agent") do
    prefix = prefix |> String.trim() |> String.downcase()

    case for(
           ticket <- tickets,
           not excluded?(ticket.labels, prefix),
           states = current_states(ticket.labels, prefix),
           length(states) != 1,
           not foreign_only?(ticket.labels, states, prefix),
           do: {ticket, states}
         ) do
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

  defp excluded?(labels, prefix) do
    Enum.any?(labels, fn label ->
      normalized = label |> String.trim() |> String.downcase()
      suffix = prefixed_suffix(normalized, prefix)

      normalized in ["parked", "needs-triage", "human:todo"] or suffix == "parked" or
        normalized == "epic" or String.starts_with?(normalized, "epic:")
    end)
  end

  defp current_states(labels, prefix) do
    Enum.flat_map(labels, fn label ->
      normalized = label |> String.trim() |> String.downcase()

      state =
        case String.split(normalized, ":", parts: 2) do
          [^prefix, state] -> state
          [other_prefix, _state] when other_prefix != "" -> nil
          [_other_prefix, _state] -> nil
          [state] -> state
        end

      if state in @state_labels, do: [state], else: []
    end)
  end

  defp foreign_only?(labels, [], prefix) do
    Enum.any?(labels, fn label ->
      case String.split(label |> String.trim() |> String.downcase(), ":", parts: 2) do
        [other_prefix, state] when other_prefix != prefix -> state in @state_labels
        _other -> false
      end
    end)
  end

  defp foreign_only?(_labels, _states, _prefix), do: false

  defp prefixed_suffix(label, prefix) do
    case String.split(label, ":", parts: 2) do
      [^prefix, suffix] -> suffix
      _other -> nil
    end
  end

  # Oldest by creation time; tickets without one sort after, by number.
  defp age_key({ticket, _states}) do
    case ticket.created_at && DateTime.from_iso8601(to_string(ticket.created_at)) do
      {:ok, created_at, _offset} -> {0, DateTime.to_unix(created_at, :millisecond), ticket.number || 0}
      _ -> {1, 0, ticket.number || 0}
    end
  end
end
