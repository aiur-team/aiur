defmodule AiurWeb.StreamdeckLogs do
  @moduledoc false

  @events_window_size 8
  @transcript_window_size 2

  @spec project([map()]) :: map()
  def project(entries) when is_list(entries) do
    events = entries |> grouped_events() |> Enum.map(&event/1)
    flat = events |> Enum.reverse() |> Enum.flat_map(&flatten_event/1)

    %{
      events: events,
      transcript: flat,
      events_offset: 0,
      events_max_offset: max(length(events) - @events_window_size, 0),
      transcript_offset: 0,
      transcript_max_offset: max(length(flat) - @transcript_window_size, 0)
    }
    |> visible()
  end

  @spec visible(map()) :: map()
  def visible(logs) do
    logs
    |> Map.put(:events_visible, Enum.slice(logs.events, logs.events_offset, @events_window_size))
    |> Map.put(:transcript_visible, Enum.slice(logs.transcript, logs.transcript_offset, @transcript_window_size))
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
      body: body(latest),
      timestamp: value(latest, :timestamp),
      entries: entries |> Enum.reverse() |> Enum.map(&entry/1)
    }
  end

  defp flatten_event(event) do
    [%{kind: :event_header, badge: event.badge, body: event.body, timestamp: event.timestamp} | event.entries]
  end

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
end
