defmodule AiurWeb.StreamdeckStrip do
  @moduledoc """
  Presentation-only descriptors for the mode-dependent Stream Deck touch strip.

  Keeping these descriptions independent of the LiveView lets the command and
  logs pages share the same bounded-navigation rules while the grid strip
  remains owned by its dedicated renderer.
  """

  @type hint :: %{label: String.t(), older?: boolean(), newer?: boolean()}

  @doc "Builds the focused-agent details rendered by the command strip."
  @spec command(map()) :: map()
  def command(agent) when is_map(agent) do
    percent = agent |> Map.get(:progress_percent, 0) |> percent()

    %{
      number: to_string(Map.get(agent, :identifier, "")),
      provider: Map.get(agent, :vendor, "unknown") |> to_string(),
      provider_logo: provider_logo(Map.get(agent, :vendor, "unknown")),
      title: Map.get(agent, :title, "Untitled agent") |> to_string(),
      status: status(Map.get(agent, :bucket)),
      percent: percent,
      progress_colour: "hsl(#{percent / 100 * 125}, 72%, 50%)"
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
    %{shape: :evhdr, direction: to_string(badge), text: to_string(body), time: relative_time(timestamp)}
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

  defp entry(%{kind: :message, role: role, body: body}) do
    %{shape: :message, speaker: speaker(role), text: to_string(body)}
  end

  defp entry(_entry), do: %{shape: :message, speaker: :ci, text: ""}

  defp percent(value) when is_integer(value), do: clamp(value, 0, 100)
  defp percent(value) when is_float(value), do: value |> round() |> percent()
  defp percent(_value), do: 0

  defp status(:running), do: "RUNNING"
  defp status(:paused), do: "PAUSED"
  defp status(:queued), do: "QUEUED"
  defp status(:stuck), do: "STUCK"
  defp status(:alert), do: "ATTENTION"
  defp status(_bucket), do: "IDLE"

  defp provider_logo(provider) do
    case provider |> to_string() |> String.downcase() do
      "claude" -> "/claude-symbol.svg"
      "codex" -> "/codex-color.svg"
      _ -> nil
    end
  end

  defp speaker(role) when role in ["assistant", :assistant], do: :agent
  defp speaker(role) when role in ["tool", :tool], do: :tool
  defp speaker(role) when role in ["user", :user], do: :you
  defp speaker(_role), do: :ci

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
