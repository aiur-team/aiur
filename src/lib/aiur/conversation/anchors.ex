defmodule Aiur.Conversation.Anchors do
  @moduledoc """
  Device-neutral event-to-transcript anchoring at observed timestamp precision.

  Events are oldest-first, with the synthetic origin first. Each transcript
  entry belongs to the last event at or before its timestamp; entries without
  a usable timestamp fall to the origin. These anchors are not stable journal
  positions.

  ## Positions (MP-E4)

  Journal anchors implement conversations-transcripts-anchors contract §10.
  Exact tool provenance beats causal, observed, then unanchored precision.
  `position/3` uses daemon observation times and includes equal-time entries
  (`<=`); the deck membership rule in `at_or_before/2` remains `>=`.
  Inputs are a bounded window from one conversation; resolution is linear.
  """

  @type entry :: Aiur.Conversation.Entry.t() | map()
  @type session :: Aiur.Conversation.Session.t() | map()
  @type event :: %{
          required(:event_id) => pos_integer(),
          required(:kind) => String.t(),
          required(:topic) => String.t(),
          required(:conversation_id) => String.t(),
          optional(atom()) => term()
        }
  @type anchor :: %{String.t() => term()}

  @precision %{"unanchored" => 0, "observed" => 1, "causal" => 2, "exact" => 3}

  @doc "Finds a tool-proven entry, using decision provenance for Command requests."
  @spec exact(event(), [entry()]) :: {:ok, anchor()} | :none
  def exact(%{kind: "command_requested"} = event, entries), do: decision_source(event, entries)
  def exact(event, entries), do: tool_anchor(event, entries, Map.get(event, :source_tool_call_id), "tool_call")

  @doc "Finds the tool entry that requested a Command."
  @spec decision_source(event(), [entry()]) :: {:ok, anchor()} | :none
  def decision_source(event, entries),
    do: tool_anchor(event, entries, Map.get(event, :decision_tool_call_id), "decision_source")

  @doc "Finds the latest successful command with a matching event key in the prior ten minutes."
  @spec causal(event(), [entry()]) :: {:ok, anchor()} | :none
  def causal(event, entries) do
    case Aiur.Conversation.CausalAnchors.command(event, entries) do
      nil -> :none
      entry -> {:ok, anchor(event, entry.pos, "at", "causal", "command_text")}
    end
  end

  @doc "Places an event after the greatest observed position, or leaves it unanchored."
  @spec position(event(), [entry()], [session()]) :: {:ok, anchor()}
  def position(event, entries, sessions) do
    time = instant(Map.get(event, :observed_at))

    entry =
      if time && Enum.any?(sessions, &covers?(&1, time)) && !Enum.any?(entries, &gap?(&1, time)) do
        entries
        |> Enum.filter(&(&1.kind != "gap" && before_or_equal?(instant(&1.observed_at), time)))
        |> Enum.max_by(& &1.pos, fn -> nil end)
      end

    if entry,
      do: {:ok, anchor(event, entry.pos, "after", "observed", "observed_at")},
      else: {:ok, anchor(event, nil, nil, "unanchored", nil)}
  end

  @doc "Keeps the strongest precision per event, kind and conversation, preserving first-seen order."
  @spec strongest([anchor()]) :: [anchor()]
  def strongest(anchors) do
    {order, selected} =
      Enum.reduce(anchors, {[], %{}}, fn anchor, {order, selected} ->
        key = {anchor["event"]["event_id"], anchor["kind"], anchor["conversation_id"]}

        case Map.fetch(selected, key) do
          :error ->
            {[key | order], Map.put(selected, key, anchor)}

          {:ok, prior} ->
            {order, Map.put(selected, key, stronger(anchor, prior))}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(selected, &1))
  end

  defp stronger(anchor, prior) do
    if Map.fetch!(@precision, anchor["precision"]) > Map.fetch!(@precision, prior["precision"]),
      do: anchor,
      else: prior
  end

  @doc "Stable precision-specific identity; upgrading precision appends a new journal line."
  @spec anchor_id(anchor()) :: String.t()
  def anchor_id(anchor) do
    identity = [anchor["event"]["event_id"], anchor["kind"], anchor["conversation_id"], anchor["precision"]]
    digest = :crypto.hash(:sha256, Jason.encode!(identity)) |> Base.encode32(case: :lower, padding: false)
    "anc_" <> binary_part(digest, 0, 26)
  end

  defp tool_anchor(_event, _entries, id, _method) when id in [nil, ""], do: :none

  defp tool_anchor(event, entries, id, method) do
    case Enum.find(entries, &(Map.get(&1.refs, :tool_call_id, Map.get(&1.refs, "tool_call_id")) == id)) do
      nil -> :none
      entry -> {:ok, anchor(event, entry.pos, "at", "exact", method)}
    end
  end

  defp anchor(event, pos, placement, precision, method) do
    record = %{
      "v" => 1,
      "event" => %{
        "event_id" => event.event_id,
        "topic" => event.topic,
        "observed_at" => timestamp(Map.get(event, :observed_at)),
        "occurred_at" => timestamp(Map.get(event, :occurred_at))
      },
      "kind" => event.kind,
      "conversation_id" => event.conversation_id,
      "pos" => pos,
      "placement" => placement,
      "precision" => precision,
      "method" => method,
      "label" => Map.get(event, :label),
      "subject_ref" => Map.get(event, :subject_ref)
    }

    Map.put(record, "anchor_id", anchor_id(record))
  end

  defp covers?(session, time),
    do: before_or_equal?(instant(session.started_at), time) && (is_nil(session.ended_at) || before_or_equal?(time, instant(session.ended_at)))

  defp gap?(%{kind: "gap", meta: meta}, time) do
    from = instant(Map.get(meta, :from, Map.get(meta, "from")))
    to = instant(Map.get(meta, :to, Map.get(meta, "to")))
    (is_nil(from) || before_or_equal?(from, time)) && (is_nil(to) || before_or_equal?(time, to))
  end

  defp gap?(_entry, _time), do: false
  defp before_or_equal?(nil, _time), do: false
  defp before_or_equal?(_time, nil), do: false
  defp before_or_equal?(left, right), do: DateTime.compare(left, right) != :gt
  defp timestamp(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp timestamp(time), do: time

  @origin_id :origin

  # Published and consumed twins share an event ID but remain separate anchors.
  @spec event_identity(term(), term()) :: {:bus, term(), term()}
  def event_identity(kind, id), do: {:bus, kind, id}

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
