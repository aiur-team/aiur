defmodule AiurWeb.Streamdeck.Render.Chat do
  @moduledoc "Full-width frame strip from the already masked conversation projection."
  alias AiurWeb.Streamdeck.Render.Svg
  import Svg, only: [field: 2, field: 3]

  @spec strip(map(), integer()) :: [map()]
  def strip(chat, now) do
    latest = field(chat, :latest)
    status = status(chat, now)
    text = if latest, do: entry(latest), else: ""
    lines = Svg.wrap(text, Svg.budget(800, 6, 14), if(status == "", do: 5, else: 4))
    rows = if status == "", do: lines, else: [status | lines]
    content = [Svg.element("rect", width: 800, height: 100, fill: "#101318"), Enum.with_index(rows, fn row, i -> Svg.text(row, 6, 16 + i * 17, 14) end)]
    [content |> Svg.image(800, 100, Enum.join(rows, " ")) |> Map.merge(%{x: 0, width: 800})]
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
