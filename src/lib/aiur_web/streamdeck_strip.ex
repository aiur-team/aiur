defmodule AiurWeb.StreamdeckStrip do
  @moduledoc """
  Presentation-only descriptors for the mode-dependent Stream Deck touch strip.

  Keeping these descriptions independent of the LiveView lets the command and
  logs pages share the same bounded-navigation rules while the grid strip
  remains owned by its dedicated renderer.

  The command panel's accent, status wording and progress fill all come from
  `AiurWeb.StreamdeckKeyFaceContract`, so the strip cannot say one thing while
  the key for the same agent says another.
  """

  alias AiurWeb.StreamdeckKeyFaceContract
  alias AiurWeb.StreamdeckLogs

  @type hint :: %{label: String.t(), older?: boolean(), newer?: boolean()}

  @doc "Builds the focused-agent details rendered by the command strip."
  @spec command(map()) :: map()
  def command(agent) when is_map(agent) do
    percent = agent |> Map.get(:progress_percent, 0) |> percent()
    bucket = Map.fetch!(agent, :bucket)
    state = StreamdeckKeyFaceContract.state!(bucket)

    %{
      icon: agent_icon(bucket),
      number: to_string(Map.get(agent, :identifier, "")),
      provider: Map.get(agent, :vendor, "unknown") |> to_string(),
      provider_logo: provider_logo(Map.get(agent, :vendor, "unknown")),
      title: Map.get(agent, :title, "Untitled agent") |> to_string(),
      status: state["label"],
      accent: state["accent"],
      percent: percent,
      progress_colour: StreamdeckKeyFaceContract.progress_color(percent)
    }
  end

  @doc "Describes which fixed-width navigation arrows should be visible."
  @spec hint(integer(), integer(), String.t()) :: hint()
  def hint(index, max_index, label) do
    max_index = max(max_index, 0)
    index = index |> max(0) |> min(max_index)

    %{label: label, older?: index > 0, newer?: index < max_index}
  end

  @doc "Turns flattened transcript entries into their three strip presentation shapes."
  @spec entries([map()]) :: [map()]
  def entries(entries) when is_list(entries), do: Enum.map(entries, &entry/1)

  defp entry(%{kind: :event_header, badge: badge, body: body, timestamp: timestamp}) do
    direction = to_string(badge)

    %{
      shape: :evhdr,
      direction: direction,
      colour: StreamdeckKeyFaceContract.direction_badge!(direction)["color"],
      text: to_string(body),
      time: relative_time(timestamp)
    }
  end

  defp entry(%{kind: :diff, path: path, additions: additions, deletions: deletions, line: line}) do
    additions = additions || 0
    deletions = deletions || 0
    line = diff_line(line, additions, deletions)

    %{
      shape: :diff,
      file: to_string(path || "changed file"),
      additions: additions,
      deletions: deletions,
      line: line,
      line_kind: line_kind(line)
    }
  end

  defp entry(%{kind: :message} = message) do
    role = Map.get(message, :role, "system")
    body = to_string(Map.get(message, :body, ""))

    %{
      shape: :message,
      # `row_kind` and `glyph` come from the StreamdeckLogs projection (so the
      # emulator and the device DTO agree); the fallbacks let a raw transcript
      # entry still render standalone. `tool_display/1` strips the verb prefix
      # and is idempotent, so a projection body already stripped is unchanged.
      kind: Map.get(message, :row_kind, StreamdeckLogs.row_kind(role)),
      glyph: Map.get(message, :glyph, StreamdeckLogs.glyph(role, body)),
      text: Map.get(message, :text, StreamdeckLogs.tool_display(body)) |> to_string()
    }
  end

  defp entry(_entry), do: %{shape: :message, kind: :logs, glyph: nil, text: ""}

  defp percent(value) when is_integer(value), do: clamp(value, 0, 100)
  defp percent(value) when is_float(value), do: value |> round() |> percent()
  defp percent(_value), do: 0

  # Glyphs are the strip's own affordance; the wording beside them is the
  # contract's `label`, so nothing here restates a state name.
  defp agent_icon(:running), do: "▶"
  defp agent_icon(:paused), do: "Ⅱ"
  defp agent_icon(:queued), do: "◌"
  defp agent_icon(:stuck), do: "!"
  defp agent_icon(:alert), do: "!"

  defp provider_logo(provider) do
    case provider |> to_string() |> String.downcase() do
      "claude" -> "/provider-assets/claude-symbol.svg"
      "codex" -> "/provider-assets/codex-color.svg"
      _ -> nil
    end
  end

  defp line_kind("+" <> _line), do: :addition
  defp line_kind("-" <> _line), do: :deletion
  defp line_kind(_line), do: :context

  defp diff_line(line, additions, deletions) do
    line = to_string(line || "")

    cond do
      line == "" or String.starts_with?(line, ["+", "-"]) -> line
      additions > 0 -> "+#{line}"
      deletions > 0 -> "-#{line}"
      true -> line
    end
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

  defp clamp(value, lower, upper), do: value |> max(lower) |> min(upper)
end
