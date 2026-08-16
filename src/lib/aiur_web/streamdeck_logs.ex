defmodule AiurWeb.StreamdeckLogs do
  @moduledoc """
  Server-side projection of the classified agent event feed onto the Stream
  Deck logs mode window model from #1351.

  `AgentEventFeed.list/2` returns a flat, newest-first list of classified
  transcript entries. `project/1` groups them by `turn_id` into events, derives
  a badge/body header per event, and flattens them once into the transcript
  while recording the start offset for each event. The eight-key event window
  reserves index zero for the LIVE key; selecting another key positions the
  transcript at that event's recorded start offset.
  """

  @events_window_size 8
  @transcript_window_size 2

  # The badge is the only thing the projection emits; the shared key-face
  # contract owns both the set of directions and the colour each one paints
  # with, so the emulator and the packaged deck cannot drift apart.
  @directions Map.keys(AiurWeb.StreamdeckKeyFaceContract.direction_badges())

  @spec project([map()]) :: map()
  def project(entries) when is_list(entries) do
    events =
      entries
      |> grouped_events()
      |> Enum.map(&event/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    {flat, event_starts} = flatten(events)
    event_keys = [%{kind: :live, id: :live, index: 0, label: "LIVE"} | Enum.map(events, &event_key/1)]

    %{
      # Retained so `refresh_relative_times/2` can re-derive each key's age from
      # the real timestamp without rebuilding the feed.
      events: events,
      event_keys: event_keys,
      event_starts: event_starts,
      transcript: flat,
      events_offset: 0,
      events_max_offset: max(length(event_keys) - @events_window_size, 0),
      transcript_offset: 0,
      transcript_max_offset: max(length(flat) - @transcript_window_size, 0),
      selected_event_id: :live,
      selected_event_index: 0
    }
    |> visible()
  end

  @doc "Converts the internal projection into the JSON-safe channel DTO."
  @spec wire(map()) :: map()
  def wire(logs) when is_map(logs), do: wire_value(logs)

  defp wire_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp wire_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), wire_value(item)} end)
  end

  defp wire_value(value) when is_list(value), do: Enum.map(value, &wire_value/1)
  defp wire_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map_join(":", &wire_value/1)
  defp wire_value(value) when is_atom(value), do: Atom.to_string(value)
  defp wire_value(value), do: value

  @spec visible(map()) :: map()
  def visible(logs) do
    logs
    |> Map.put(:event_keys_visible, event_window(logs))
    |> Map.put(:transcript_visible, Enum.slice(logs.transcript, logs.transcript_offset, @transcript_window_size))
  end

  @doc "Selects an event key and positions the transcript at that event header."
  @spec select_event(map(), integer()) :: map()
  def select_event(logs, index) when is_integer(index) do
    index = clamp(index, 0, length(logs.event_keys) - 1)
    transcript_offset = Map.get(logs.event_starts, index, 0)

    logs
    |> Map.put(:selected_event_id, Enum.at(logs.event_keys, index).id)
    |> Map.put(:selected_event_index, index)
    |> Map.put(:transcript_offset, transcript_offset)
    |> ensure_visible()
    |> visible()
  end

  @doc """
  Refreshes entries while retaining the operator's reading position.

  The relay flushes several times a second, so re-projecting alone is not
  enough: the selected event, how far into that event the transcript is
  scrolled, and where the eight-key window sits all have to survive the flush.
  The transcript position is carried as a delta from the selected event's start
  offset, because the absolute offset moves whenever a newer event is prepended.
  """
  @spec refresh(map(), [map()]) :: map()
  def refresh(logs, entries) do
    refreshed = project(entries)
    selected_id = Map.get(logs, :selected_event_id)

    with id when not is_nil(id) and id != :live <- selected_id,
         key when not is_nil(key) <- Enum.find(refreshed.event_keys, &(&1.id == id)) do
      refreshed
      |> select_event(key.index)
      |> shift_transcript(transcript_delta(logs))
      |> restore_events_offset(logs)
    else
      # LIVE follows the head of the feed, so the transcript position is not
      # carried; only the key window the operator scrolled with dial D is.
      :live -> restore_events_offset(refreshed, logs)
      _ -> refreshed
    end
  end

  @doc """
  Re-derives the age shown on each event key against `now`.

  `refresh/2` only runs when the feed changes, so on an idle agent a key face
  would otherwise read "now" indefinitely. This recomputes the relative times
  from the events' real timestamps without rebuilding the feed, leaving the
  selection, both offsets and the flattened transcript untouched.
  """
  @spec refresh_relative_times(map(), DateTime.t()) :: map()
  def refresh_relative_times(logs, now \\ DateTime.utc_now()) do
    times = Map.new(logs.events, fn event -> {event.index, relative_time(event.timestamp, now)} end)

    logs
    |> Map.update!(:event_keys, fn keys ->
      Enum.map(keys, fn
        %{kind: :event, index: index} = key -> Map.put(key, :time, Map.fetch!(times, index))
        key -> key
      end)
    end)
    |> visible()
  end

  @doc "Scrolls one logs surface while keeping the selected event coherent."
  @spec scroll(map(), :events | :transcript, integer()) :: map()
  def scroll(logs, :events, delta) when is_integer(delta) do
    logs
    |> Map.put(:events_offset, clamp(logs.events_offset + delta, 0, logs.events_max_offset))
    |> visible()
  end

  def scroll(logs, :transcript, delta) when is_integer(delta) do
    transcript_offset = clamp(logs.transcript_offset + delta, 0, logs.transcript_max_offset)
    selected_event_index = event_at(logs.event_starts, transcript_offset)

    logs
    |> Map.put(:transcript_offset, transcript_offset)
    |> Map.put(:selected_event_id, Enum.at(logs.event_keys, selected_event_index).id)
    |> Map.put(:selected_event_index, selected_event_index)
    |> ensure_visible()
    |> visible()
  end

  @doc "Keeps the selected event inside the eight-key event window."
  @spec ensure_visible(map()) :: map()
  def ensure_visible(logs) do
    offset = logs.events_offset
    selected = logs.selected_event_index

    offset =
      cond do
        selected < offset -> selected
        selected >= offset + @events_window_size -> selected - @events_window_size + 1
        true -> offset
      end

    Map.put(logs, :events_offset, clamp(offset, 0, logs.events_max_offset))
  end

  @spec line(map()) :: String.t()
  def line(%{kind: :event_header, badge: badge, body: body}), do: "[#{badge}] #{body}"
  def line(%{kind: :message, role: role, body: body}), do: "[#{role}] #{body}"

  def line(%{kind: :diff, path: path, additions: additions, deletions: deletions, line: line}) do
    "[diff] #{path || "changed file"} +#{additions} -#{deletions}" <> if(is_binary(line) and line != "", do: " #{line}", else: "")
  end

  def line(_entry), do: "[INFO]"

  defp grouped_events(entries) do
    entries
    |> Enum.with_index()
    |> Enum.chunk_by(fn {entry, index} -> value(entry, :turn_id) || {:entry, index} end)
    |> Enum.map(fn group -> Enum.map(group, &elem(&1, 0)) end)
  end

  defp event([latest | _] = entries) do
    %{
      badge: value(latest, :badge, "INFO"),
      body: summary_body(entries),
      id: event_id(latest),
      timestamp: value(latest, :timestamp),
      entries: entries |> Enum.reverse() |> Enum.map(&entry/1)
    }
  end

  defp event_key(event) do
    %{
      kind: :event,
      id: event.id,
      index: event.index,
      badge: direction(event.badge),
      text: event.body,
      time: relative_time(event.timestamp)
    }
  end

  # `turn_id` is what the classified feed always sets, and it is what makes an
  # event stable across refreshes. The remaining clauses only matter for
  # synthetic or partial entries, where two byte-identical entries collide and
  # `refresh/2` may reselect the sibling.
  defp event_id(entry) do
    cond do
      turn_id = value(entry, :turn_id) -> {:turn, turn_id}
      msg_id = value(entry, :msg_id) -> {:message, msg_id}
      true -> {:entry, value(entry, :timestamp), value(entry, :type), value(entry, :role), body(entry), value(entry, :path)}
    end
  end

  # The classified feed omits `body` for diff entries, so a turn whose newest
  # entry is a provider diff derives its header summary from the diff path.
  defp summary_body(entries) do
    entries
    |> Enum.map(fn entry ->
      case body(entry) do
        "" -> value(entry, :path) || ""
        text -> text
      end
    end)
    |> Enum.find(&(&1 != ""))
    |> Kernel.||("")
  end

  defp flatten(events) do
    {chunks, event_starts, _offset} =
      Enum.reduce(events, {[], %{}, 0}, fn event, {chunks, starts, offset} ->
        entries = flatten_event(event)
        {[entries | chunks], Map.put(starts, event.index, offset), offset + length(entries)}
      end)

    {chunks |> Enum.reverse() |> List.flatten(), event_starts}
  end

  defp flatten_event(event) do
    [%{kind: :event_header, badge: event.badge, body: event.body, timestamp: event.timestamp} | event.entries]
  end

  defp transcript_delta(logs) do
    starts = Map.get(logs, :event_starts) || %{}
    selected_start = Map.get(starts, Map.get(logs, :selected_event_index, 0), 0)
    Map.get(logs, :transcript_offset, 0) - selected_start
  end

  defp shift_transcript(logs, 0), do: logs

  defp shift_transcript(logs, delta) do
    logs
    |> Map.put(:transcript_offset, clamp(logs.transcript_offset + delta, 0, logs.transcript_max_offset))
    |> visible()
  end

  # Deliberately not `ensure_visible/1`: dial D may legitimately have scrolled
  # the key window away from the selection, and a flush must not drag it back.
  defp restore_events_offset(logs, previous) do
    logs
    |> Map.put(:events_offset, clamp(Map.get(previous, :events_offset, 0), 0, logs.events_max_offset))
    |> visible()
  end

  defp event_window(logs) do
    logs.event_keys
    |> Enum.slice(logs.events_offset, @events_window_size)
    |> Kernel.++(List.duplicate(%{kind: :empty, id: nil, index: nil}, @events_window_size))
    |> Enum.take(@events_window_size)
  end

  defp event_at(event_starts, transcript_offset) do
    event_starts
    |> Enum.sort_by(fn {index, _offset} -> index end)
    |> Enum.reduce(0, fn {index, offset}, selected -> if offset <= transcript_offset, do: index, else: selected end)
  end

  defp direction(badge) do
    if badge in @directions, do: badge, else: "INFO"
  end

  # `now` is injected rather than read inline so `refresh_relative_times/2` can
  # re-age every key against a single instant, and so a test can assert that the
  # faces advance without sleeping.
  defp relative_time(timestamp), do: relative_time(timestamp, DateTime.utc_now())

  defp relative_time(timestamp, now) when is_binary(timestamp) and is_struct(now, DateTime) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, event_at, _offset} ->
        seconds = max(DateTime.diff(now, event_at), 0)

        cond do
          seconds < 60 -> "now"
          seconds < 3600 -> "#{div(seconds, 60)}m"
          seconds < 86_400 -> "#{div(seconds, 3600)}h"
          true -> "#{div(seconds, 86_400)}d"
        end

      # A non-ISO8601 stamp is not a duration, and a key face is six characters
      # wide, so show a truncated literal rather than overflowing the face.
      _ ->
        String.slice(timestamp, 0, 6)
    end
  end

  defp relative_time(_timestamp, _now), do: ""

  defp entry(entry) do
    case value(entry, :type) do
      "diff" ->
        %{
          kind: :diff,
          path: value(entry, :path),
          additions: value(entry, :additions, 0),
          deletions: value(entry, :deletions, 0),
          line: value(entry, :line)
        }

      _ ->
        role = value(entry, :role, "system")
        raw_body = body(entry)

        %{
          kind: :message,
          role: role,
          # The verb prefix (`read `/`edit `/`write `) is stripped from tool
          # bodies because the glyph gutter carries the verb; a tool row reads
          # `→ lib/aiur.ex` rather than `→ read lib/aiur.ex`. Both the emulator
          # strip and the device DTO consume this body, so the physical deck
          # shows the same path the emulator shows. Non-tool prose is untouched.
          body: if(role in ["tool", :tool], do: tool_display(raw_body), else: raw_body),
          row_kind: row_kind(role),
          glyph: glyph(role, raw_body)
        }
    end
  end

  defp body(entry), do: value(entry, :body, "") |> to_string() |> String.replace(~r/\R/u, " ") |> String.trim()

  # Row kind drives the per-kind colour on both the emulator and the device.
  # Commands and tool rows are one class (the agent acting on an external
  # surface); agent prose is another; system/reasoning/alert are the "logs"
  # class. The third distinct colour (tan) belongs to logs.
  @doc false
  def row_kind(role) when role in ["assistant", :assistant], do: :agent
  def row_kind(role) when role in ["command", :command, "tool", :tool], do: :command
  def row_kind(role) when role in ["user", :user], do: :user
  def row_kind(_role), do: :logs

  # The opencode-style glyph gutter (#1934): `$` commands, `→` read, `←`
  # edit/write, `⚙` generic tools. The verb is detected from the RAW body
  # (before the prefix is stripped).
  @doc false
  def glyph(role, body) when role in ["tool", :tool] and is_binary(body) do
    case tool_verb(body) do
      :read -> "→"
      :write -> "←"
      :edit -> "←"
      nil -> "⚙"
    end
  end

  def glyph(role, _body) when role in ["command", :command], do: "$"
  def glyph(_role, _body), do: nil

  @doc false
  def tool_display(body) when is_binary(body) do
    case tool_verb(body) do
      verb when verb in [:read, :write, :edit] ->
        case String.split(body, " ", parts: 2) do
          [_verb, rest] -> rest
          _ -> body
        end

      nil ->
        body
    end
  end

  def tool_display(body), do: body

  defp tool_verb(body) when is_binary(body) do
    cond do
      String.starts_with?(body, "read ") -> :read
      String.starts_with?(body, "write ") -> :write
      String.starts_with?(body, "edit ") -> :edit
      true -> nil
    end
  end

  defp tool_verb(_body), do: nil

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp clamp(value, lower, upper), do: value |> max(lower) |> min(max(upper, lower))
end
