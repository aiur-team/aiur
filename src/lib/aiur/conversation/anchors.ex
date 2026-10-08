defmodule Aiur.Conversation.Anchors do
  @moduledoc """
  Device-neutral event-to-transcript anchoring at observed timestamp precision.

  Events are oldest-first, with the synthetic origin first. Each transcript
  entry belongs to the last event at or before its timestamp; entries without
  a usable timestamp fall to the origin. These anchors are not stable journal
  positions.
  """

  @origin_id :origin

  # Published and consumed twins share an event ID but remain separate anchors.
  @spec event_identity(String.t() | nil, term()) :: {:bus, String.t(), term()}
  def event_identity(kind, id), do: {:bus, kind || "emit", id}

  @spec origin_id() :: :origin
  def origin_id, do: @origin_id

  @doc "Prepends a neutral origin using the earliest non-nil timestamp of both feeds."
  @spec with_origin([map()], [map()]) :: [map()]
  def with_origin(events, transcript_entries) do
    [%{id: @origin_id, timestamp: earliest(events, transcript_entries)} | events]
  end

  defp earliest(events, transcript_entries) do
    (Enum.map(events, & &1.timestamp) ++ Enum.map(transcript_entries, & &1.timestamp))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.min(fn -> nil end)
  end

  # Every transcript entry belongs to the last event at or before it. Entries
  # with no usable timestamp fall to the origin rather than being dropped: an
  # unattributable row is still something the agent said.
  @spec at_or_before([map()], [map()]) :: [map()]
  def at_or_before(events, transcript_entries) do
    events
    |> Enum.reverse()
    |> Enum.map_reduce(transcript_entries, fn event, remaining ->
      {mine, earlier} = Enum.split_with(remaining, &at_or_after?(&1, event.timestamp))
      {Map.put(event, :entries, mine), earlier}
    end)
    |> then(fn {assigned, leftover} -> attach_leftover(Enum.reverse(assigned), leftover) end)
  end

  defp attach_leftover([origin | rest], leftover), do: [Map.update!(origin, :entries, &(leftover ++ &1)) | rest]
  defp attach_leftover([], _leftover), do: []

  # An event with no usable timestamp claims nothing rather than everything.
  # The walk runs newest-first and uses `split_with`, so a boundary that matched
  # every entry would hand one malformed event the whole transcript and leave
  # every older key — including the origin — empty. Unmatched entries still
  # reach the origin through `attach_leftover/2`, which is where they belong.
  defp at_or_after?(_entry, nil), do: false
  defp at_or_after?(%{timestamp: nil}, _boundary), do: false

  defp at_or_after?(%{timestamp: timestamp}, boundary) do
    case {instant(timestamp), instant(boundary)} do
      {%DateTime{} = at, %DateTime{} = edge} -> DateTime.compare(at, edge) != :lt
      # Neither side parses as an instant: a lexical comparison is the only
      # ordering left, and it is right for the same-shape UTC strings both
      # producers actually emit.
      _ -> to_string(timestamp) >= to_string(boundary)
    end
  end

  # Parsed rather than compared as strings: ISO 8601 is only lexically ordered
  # when both sides share a precision and an offset. "10:00:00Z" against
  # "10:00:00.5Z" compares "Z" to ".", which sorts the later instant first.
  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp instant(%DateTime{} = value), do: value
  defp instant(_value), do: nil
end
