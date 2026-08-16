defmodule AiurWeb.StreamdeckLogs do
  @moduledoc """
  Server-side projection of a ticket's activity onto the Stream Deck logs
  surface.

  ## Two inputs, and why they are not one

  `project/1` takes a map with two keys:

    * `:events` — the ticket's **shared event bus** history, oldest first, from
      `Aiur.AgentEventFeed.bus_events/2`. These are the things that *happened to
      the ticket*: progress and phase changes, inbound comments, CI and PR
      transitions, decisions and attentions. One key on the deck per entry.
    * `:transcript` — the agent's **provider transcript**, from
      `Aiur.AgentEventFeed.list/2`. These are the things the agent *said*:
      messages, tool calls, commands, diffs. They are the detail underneath an
      event, never a key of their own.

  The surface previously fed both roles from the transcript alone and grouped it
  by `turn_id`. That is what produced a single, endlessly-rewritten event key: a
  turn is one grouping of dozens of messages, so the whole page collapsed into
  one "event" whose label was simply the newest thing the agent had typed.

  ## Ordering

  Everything here is **oldest first**, in both axes, because the surface is read
  as a chat window: scroll fully left for the beginning, fully right for now.
  The previous projection flattened newest-first, which put the agent's most
  recent word at the far left and the ticket's origin at the far right.

  ## The two anchors

  Index `0` is always an **origin** event, synthesised even when the bus is
  empty, so the transcript always has a defined left edge and no entry that
  predates the first published event is orphaned. The **last** key is always
  LIVE, and LIVE is **pinned**: it occupies the bottom-right key at every scroll
  position and never participates in the event window's paging, so "return to
  now" is a single press from anywhere. The event window therefore shows
  `@events_per_page` events (seven) plus the pinned LIVE key — one fewer event
  per page than the physical key count — and the paging arithmetic derives the
  max offset from those seven slots rather than slicing eight and silently
  overwriting the slot LIVE occupies.

  Each key carries its own `start` — the offset of its header in the flattened
  transcript. The client jumps by reading that field rather than by indexing a
  parallel array, so there is no off-by-one to get wrong when the anchors move.
  """

  alias Aiur.AgentEventFeed

  # LIVE is pinned to the rightmost key, so each page of events shows one fewer
  # event than the physical key count (seven, against eight keys). All paging
  # arithmetic (max offset, the visible window, selection chasing) is derived
  # from this event count per page rather than from the total window size.
  @events_per_page 7
  # The emulator's own readout height. The packaged deck renders five rows and
  # computes its own bounds from the transcript it receives, because how many
  # rows fit is a render decision the server cannot make for it.
  @transcript_window_size 2

  # The badge is the only thing the projection emits; the shared key-face
  # contract owns both the set of directions and the colour each one paints
  # with, so the emulator and the packaged deck cannot drift apart.
  @directions Map.keys(AiurWeb.StreamdeckKeyFaceContract.direction_badges())

  @origin_id :origin
  @live_id :live

  @type source :: %{optional(:events) => [map()], optional(:transcript) => [map()]}

  @spec project(source() | [map()]) :: map()
  def project(source)

  # A bare list is the transcript alone — the shape every caller used before the
  # bus became a separate input. Kept so a caller with no bus access still
  # projects, rather than raising.
  def project(entries) when is_list(entries), do: project(%{events: [], transcript: entries})

  def project(%{} = source) do
    transcript_entries = source |> Map.get(:transcript, []) |> oldest_first() |> Enum.map(&entry/1)
    bus = source |> Map.get(:events, []) |> Enum.map(&bus_event/1)

    events = bus |> with_origin(transcript_entries) |> assign_entries(transcript_entries) |> Enum.with_index() |> Enum.map(&indexed/1)
    {flat, starts} = flatten(events)
    # Every row is addressable as a reading position — an event header in the
    # last rows still has to be somewhere a key can jump to. The *window* is
    # clamped separately in `visible/1`, so scrolling to the end paints a full
    # readout rather than one line above blank ones.
    transcript_max_offset = max(length(flat) - 1, 0)
    event_keys = Enum.map(events, &event_key(&1, starts)) ++ [live_key(events, transcript_max_offset)]
    # The scroll range covers the events only: LIVE is pinned and is not a list
    # member the window pages over. `- 1` drops LIVE, and `@events_per_page`
    # says how many events one page holds — the paging arithmetic is explicit
    # that pinning removes one key from every page.
    events_max_offset = max(length(event_keys) - 1 - @events_per_page, 0)

    %{
      events: events,
      event_keys: event_keys,
      event_starts: starts,
      transcript: flat,
      events_offset: events_max_offset,
      events_max_offset: events_max_offset,
      # Logs opens on the newest entry — where the agent is working — not on the
      # ticket's first line. This is the whole point of the LIVE anchor being on
      # the right.
      transcript_offset: transcript_max_offset,
      transcript_max_offset: transcript_max_offset,
      selected_event_id: @live_id,
      selected_event_index: length(event_keys) - 1
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
  # `nil`, `true` and `false` are atoms, and the generic clause below would send
  # them as the strings "nil"/"true"/"false". The client reads an absent tool
  # name, timestamp or diff line as absent, so a stringified `nil` arrives as a
  # present value: every tool row would have rendered as the tool named "Nil".
  # This is the same defect as the persisted `"nil"` turn id, one layer out.
  defp wire_value(nil), do: nil
  defp wire_value(value) when is_boolean(value), do: value
  defp wire_value(value) when is_atom(value), do: Atom.to_string(value)
  defp wire_value(value), do: value

  @spec visible(map()) :: map()
  def visible(logs) do
    logs
    |> Map.put(:event_keys_visible, event_window(logs))
    |> Map.put(:transcript_visible, transcript_window(logs))
  end

  @doc """
  Selects an event key and positions the transcript at that event's header.

  Selecting LIVE is not a jump to a header — LIVE has none. It is a jump to the
  newest entry, which is what "live" means on a surface read left-to-right.
  """
  @spec select_event(map(), integer()) :: map()
  def select_event(logs, index) when is_integer(index) do
    index = clamp(index, 0, length(logs.event_keys) - 1)
    key = Enum.at(logs.event_keys, index)

    logs
    |> Map.put(:selected_event_id, key.id)
    |> Map.put(:selected_event_index, index)
    |> Map.put(:transcript_offset, clamp(key.start, 0, logs.transcript_max_offset))
    |> ensure_visible()
    |> visible()
  end

  @doc """
  Refreshes the projection while retaining the operator's reading position.

  Following LIVE is the default and the common case: while LIVE is selected the
  refresh re-pins to the new newest entry, which is what makes the surface show
  the agent working. A selected *event* keeps its identity across the refresh —
  bus event ids are stable — and the transcript position is carried as a delta
  from that event's header, because the absolute offset moves as newer entries
  are appended.
  """
  @spec refresh(map(), source() | [map()]) :: map()
  def refresh(logs, source) do
    refreshed = project(source)
    selected_id = Map.get(logs, :selected_event_id)

    with id when not is_nil(id) and id != @live_id <- selected_id,
         key when not is_nil(key) <- Enum.find(refreshed.event_keys, &(&1.id == id)) do
      refreshed
      |> select_event(key.index)
      |> shift_transcript(transcript_delta(logs))
      |> restore_events_offset(logs)
    else
      _ -> restore_events_offset(refreshed, logs)
    end
  end

  @doc """
  Re-derives the age shown on each event key against `now`.

  `refresh/2` only runs when the feed changes, so on an idle agent a key face
  would otherwise read "now" indefinitely.
  """
  @spec refresh_relative_times(map(), DateTime.t()) :: map()
  def refresh_relative_times(logs, now \\ DateTime.utc_now()) do
    logs
    |> Map.update!(:event_keys, fn keys ->
      Enum.map(keys, fn
        %{kind: :event, timestamp: timestamp} = key -> Map.put(key, :time, relative_time(timestamp, now))
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
    selected = selected_at(logs, transcript_offset)

    logs
    |> Map.put(:transcript_offset, transcript_offset)
    |> Map.put(:selected_event_id, Enum.at(logs.event_keys, selected).id)
    |> Map.put(:selected_event_index, selected)
    |> ensure_visible()
    |> visible()
  end

  @doc "Keeps the selected event inside the event window; LIVE chases to the newest page."
  @spec ensure_visible(map()) :: map()
  def ensure_visible(logs) do
    offset = logs.events_offset
    selected = logs.selected_event_index

    offset =
      cond do
        # LIVE is pinned to the rightmost key, so it never needs the window to
        # chase it for visibility — but selection semantics are unchanged from
        # #1934, and the client chases a selected LIVE to the newest page, so
        # the server does too: selecting LIVE lands the window on the newest
        # events beside it. The general branch below yields max_offset for LIVE
        # after clamping.
        selected < offset -> selected
        selected >= offset + @events_per_page -> selected - @events_per_page + 1
        true -> offset
      end

    Map.put(logs, :events_offset, clamp(offset, 0, logs.events_max_offset))
  end

  @spec line(map()) :: String.t()
  def line(%{kind: :event_header, badge: badge, body: body}), do: "[#{badge}] #{body}"
  def line(%{kind: :message, role: role, body: body}), do: "[#{role}] #{body}"
  # An unrolled hunk line keeps its own sign, which is the only thing that says
  # whether it was added or removed. Without this clause it fell to the
  # catch-all and every line of every diff read "[INFO]".
  def line(%{kind: :diff_line, sign: sign, text: text}), do: "#{sign}#{text}"

  def line(%{kind: :diff, path: path, additions: additions, deletions: deletions, line: line}) do
    "[diff] #{path || "changed file"} +#{additions} -#{deletions}" <> if(is_binary(line) and line != "", do: " #{line}", else: "")
  end

  def line(_entry), do: "[INFO]"

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  defp bus_event(row) do
    %{
      # The kind is part of the identity, not decoration. A ticket subscribes to
      # some of its own topics, so the same event id can be written twice — once
      # as `[event:emit]` when published and once as `[event:consumed]` when
      # delivered back. Keying on the id alone made those two rows one identity,
      # and a refresh silently moved the selection from the row the operator
      # picked to its twin, dragging the transcript with it.
      id: {:bus, value(row, :kind, "emit"), value(row, :id)},
      badge: direction(value(row, :badge, "EMIT")),
      label: value(row, :label, "Event"),
      body: summary(value(row, :label, "Event"), value(row, :body, "")),
      timestamp: value(row, :timestamp)
    }
  end

  # The origin exists so the surface always has a beginning. A ticket that has
  # published nothing still has a transcript, and every entry of it belongs
  # somewhere; without an anchor those rows would sit above the first header
  # with no key able to reach them.
  defp with_origin(events, transcript_entries) do
    origin = %{
      id: @origin_id,
      badge: "INFO",
      label: "Ticket opened",
      body: "Ticket opened",
      timestamp: earliest(events, transcript_entries)
    }

    [origin | events]
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
  defp assign_entries(events, transcript_entries) do
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

  defp indexed({event, index}), do: Map.put(event, :index, index)

  defp flatten(events) do
    {chunks, starts, _offset} =
      Enum.reduce(events, {[], %{}, 0}, fn event, {chunks, starts, offset} ->
        entries = [header(event) | Enum.flat_map(event.entries, &flat_rows/1)]
        {[entries | chunks], Map.put(starts, event.index, offset), offset + length(entries)}
      end)

    {chunks |> Enum.reverse() |> List.flatten(), starts}
  end

  # A diff becomes a header row plus one row per hunk line, because the client
  # addresses transcript rows by index to scroll and to jump. Summarising a
  # multi-line hunk into a single row would have shown the operator a diff's
  # *existence* where he asked to read the diff; unrolling it here — rather than
  # at the renderer — keeps "one row is one line" true for the scroll maths.
  defp flat_rows(%{kind: :diff, lines: lines} = entry) when is_list(lines) and lines != [] do
    [Map.delete(entry, :lines) | Enum.map(lines, &Map.put(&1, :kind, :diff_line))]
  end

  defp flat_rows(%{kind: :diff} = entry), do: [Map.delete(entry, :lines)]
  defp flat_rows(entry), do: [entry]

  defp header(event) do
    %{kind: :event_header, badge: event.badge, body: event.body, label: event.label, timestamp: event.timestamp}
  end

  defp event_key(event, starts) do
    %{
      kind: :event,
      id: event.id,
      index: event.index,
      badge: event.badge,
      text: event.label,
      body: event.body,
      time: relative_time(event.timestamp),
      timestamp: event.timestamp,
      start: Map.get(starts, event.index, 0)
    }
  end

  # LIVE is a key like any other so that selection is a single index rather than
  # a special case the client has to remember to exclude. Its `start` is the
  # newest row, which is exactly what pressing it should show.
  defp live_key(events, transcript_max_offset) do
    %{
      kind: :live,
      id: @live_id,
      index: length(events),
      badge: "AGENT",
      text: "LIVE",
      body: "LIVE",
      time: "",
      timestamp: nil,
      start: transcript_max_offset
    }
  end

  # A bus event's label is the human topic; its summary is whatever the
  # publisher wrote. Both are worth showing when they differ, and repeating the
  # label is worth showing never.
  defp summary(label, ""), do: label
  defp summary(label, body) when is_binary(body), do: if(String.downcase(body) == String.downcase(label), do: label, else: body)
  defp summary(label, _body), do: label

  # ---------------------------------------------------------------------------
  # Selection and scrolling
  # ---------------------------------------------------------------------------

  # Sitting on the newest row *is* being live; anything else is reading a
  # specific event. Deriving it this way is what makes the selection
  # bidirectional — a press moves the offset and the highlight follows, and so
  # does a scroll — without LIVE needing a rule of its own.
  defp selected_at(logs, transcript_offset) do
    if transcript_offset >= logs.transcript_max_offset,
      do: length(logs.event_keys) - 1,
      else: event_at(logs.event_starts, transcript_offset)
  end

  defp event_at(event_starts, transcript_offset) do
    event_starts
    |> Enum.sort_by(fn {index, _offset} -> index end)
    |> Enum.reduce(0, fn {index, offset}, selected -> if offset <= transcript_offset, do: index, else: selected end)
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
    |> Map.put(:events_offset, clamp(Map.get(previous, :events_offset, logs.events_offset), 0, logs.events_max_offset))
    |> visible()
  end

  # The painted window stops at the end of the transcript even though the
  # reading position does not, so the last position still shows a full readout.
  defp transcript_window(logs) do
    start = min(logs.transcript_offset, max(length(logs.transcript) - @transcript_window_size, 0))
    Enum.slice(logs.transcript, max(start, 0), @transcript_window_size)
  end

  # The visible window is exactly eight keys: @events_per_page event slots from
  # the scroll window plus the LIVE key pinned to the rightmost (bottom-right)
  # slot. LIVE is excluded from the slice (`Enum.drop(-1)`) and appended, so no
  # scroll position — and no short event list — can put it anywhere but the last
  # slot, and the event slice is clamped to @events_per_page so the slot LIVE
  # owns is never silently overwritten by a page's last event.
  defp event_window(logs) do
    live = List.last(logs.event_keys)

    events =
      logs.event_keys
      |> Enum.drop(-1)
      |> Enum.slice(logs.events_offset, @events_per_page)
      |> Kernel.++(List.duplicate(%{kind: :empty, id: nil, index: nil}, @events_per_page))
      |> Enum.take(@events_per_page)

    events ++ [live]
  end

  # ---------------------------------------------------------------------------
  # Transcript entries
  # ---------------------------------------------------------------------------

  defp oldest_first(entries) when is_list(entries), do: Enum.reverse(entries)
  defp oldest_first(_entries), do: []

  defp entry(entry) do
    case value(entry, :type) do
      "diff" ->
        %{
          kind: :diff,
          path: value(entry, :path),
          additions: value(entry, :additions, 0),
          deletions: value(entry, :deletions, 0),
          line: value(entry, :line),
          lines: diff_lines(value(entry, :lines, [])),
          timestamp: value(entry, :timestamp)
        }

      _ ->
        %{
          kind: :message,
          role: value(entry, :role, "system"),
          body: body(entry),
          tool: value(entry, :tool),
          timestamp: value(entry, :timestamp)
        }
    end
  end

  defp diff_lines(lines) when is_list(lines) do
    Enum.map(lines, fn line -> %{sign: value(line, :sign, " "), text: value(line, :text, "")} end)
  end

  defp diff_lines(_lines), do: []

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

  defp body(entry), do: value(entry, :body, "") |> to_string() |> String.replace(~r/\R/u, " ") |> String.trim()

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp clamp(value, lower, upper), do: value |> max(lower) |> min(max(upper, lower))

  @doc "Reads both feeds for `identifier` and projects them together."
  @spec load(String.t()) :: map()
  def load(identifier) when is_binary(identifier) do
    transcript =
      case AgentEventFeed.list(identifier, %{"limit" => 50}) do
        {:ok, %{events: events}} -> events
        _ -> []
      end

    project(%{events: AgentEventFeed.bus_events(identifier), transcript: transcript})
  end
end
