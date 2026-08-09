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

  @direction_colours %{
    "EMIT" => "#9fd0ff",
    "CONSUME" => "#88e0a6",
    "INFO" => "#c2c6cf",
    "AGENT" => "#9fd0ff",
    "SYSTEM" => "#ffcf87"
  }

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

  @doc "Refreshes entries while retaining the selected event when it is still present."
  @spec refresh(map(), [map()]) :: map()
  def refresh(logs, entries) do
    refreshed = project(entries)

    case Map.get(logs, :selected_event_id) do
      id when not is_nil(id) and id != :live ->
        case Enum.find(refreshed.event_keys, &(&1.id == id)) do
          nil -> refreshed
          key -> select_event(refreshed, key.index)
        end

      _ ->
        refreshed
    end
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
    badge = direction(event.badge)

    %{
      kind: :event,
      id: event.id,
      index: event.index,
      badge: badge,
      color: Map.fetch!(@direction_colours, badge),
      text: event.body,
      time: relative_time(event.timestamp)
    }
  end

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
    if Map.has_key?(@direction_colours, badge), do: badge, else: "INFO"
  end

  defp relative_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, event_at, _offset} ->
        seconds = max(DateTime.diff(DateTime.utc_now(), event_at), 0)

        cond do
          seconds < 60 -> "now"
          seconds < 3600 -> "#{div(seconds, 60)}m"
          seconds < 86_400 -> "#{div(seconds, 3600)}h"
          true -> "#{div(seconds, 86_400)}d"
        end

      _ ->
        timestamp
    end
  end

  defp relative_time(_timestamp), do: ""

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
        %{kind: :message, role: value(entry, :role, "system"), body: body(entry)}
    end
  end

  defp body(entry), do: value(entry, :body, "") |> to_string() |> String.replace(~r/\R/u, " ") |> String.trim()

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp clamp(value, lower, upper), do: value |> max(lower) |> min(max(upper, lower))
end
