defmodule AiurWeb.Streamdeck.Render.Chat do
  @moduledoc "Full-width frame strip from the already masked conversation projection."
  alias AiurWeb.Streamdeck.Render.Svg
  import Svg, only: [field: 2, field: 3]

  @spec strip(map(), integer()) :: [map()]
  def strip(chat, now), do: strip(chat, now, nil)

  @spec strip(map(), integer(), map() | nil) :: [map()]
  def strip(chat, now, nav) do
    status = status(chat, now)
    lines = lines(chat, nav)
    count = if status == "", do: 5, else: 4
    offset = if nav, do: min(nav.scroll, max(length(lines) - count, 0)), else: 0
    lines = lines |> Enum.drop(offset) |> Enum.take(count)
    rows = if status == "", do: lines, else: [status | lines]
    content = [Svg.element("rect", width: 800, height: 100, fill: "#101318"), Enum.with_index(rows, fn row, i -> Svg.text(row, 6, 16 + i * 17, 14) end)]
    [content |> Svg.image(800, 100, Enum.join(rows, " ")) |> Map.merge(%{x: 0, width: 800})]
  end

  @spec clamp_scroll(map()) :: map()
  def clamp_scroll(nav) do
    chat = nav.chat
    count = if to_string(chat[:state]) == "live", do: 5, else: 4
    %{nav | scroll: min(nav.scroll, max(length(lines(chat, nav)) - count, 0))}
  end

  defp lines(chat, nav) do
    latest = field(chat, :latest)
    selected = nav && nav.chat && Enum.find(nav.chat.turns, &(&1.id == nav.chat.selected))
    text = if selected, do: Enum.map_join(selected.entries, " ", &entry/1), else: if(latest, do: entry(latest), else: "")
    Svg.wrap(text, Svg.budget(800, 6, 14), 500)
  end

  defp status(chat, now) do
    case to_string(field(chat, :state)) do
      "live" -> if field(chat, :latest), do: "", else: "No chat yet."
      "not_retained" -> "Conversation not retained"
      "ended" -> "Conversation ended"
      "known_empty" -> "No chat yet."
      "restart_unknown" -> "Conversation state unknown after restart"
      "stale" -> "Conversation stale · #{age(field(chat, :observed_at), now)}"
      _ -> "Conversation unavailable"
    end
  end

  defp age(at, now) when is_integer(at), do: "#{div(max(now - at, 0), 1_000)}s old"
  defp age(_, _), do: "age unknown"

  defp entry(entry) do
    case to_string(field(entry, :k)) do
      "tool" -> "$ #{field(entry, :name, "tool")} #{field(entry, :arg, "")} #{field(entry, :res, "")}"
      "op" -> "› #{field(entry, :text, "")}"
      "say" -> "● #{field(entry, :text, "")}"
      _ -> "· #{field(entry, :text, "")}"
    end
  end
end
