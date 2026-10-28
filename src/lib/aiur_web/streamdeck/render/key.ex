defmodule AiurWeb.Streamdeck.Render.Key do
  @moduledoc false

  alias AiurWeb.Streamdeck.Render.{Marks, Parts, Style, Svg}
  import Svg, only: [element: 2, element: 3, field: 2, field: 3, text: 5]

  @spec render(map()) :: map()
  def render(face) do
    style = Style.state(field(face, :face, field(face, :bucket, "queued")))
    style = Map.put(style, :label, field(face, :label, style.label))
    state_label = state_label(face, style)
    title = field(face, :title) || ""
    identifier = field(face, :identifier) || ""
    percent = field(face, :progress_percent)

    freshness =
      field(face, :progress_freshness, if(is_number(percent), do: "fresh", else: "unknown"))

    content = [
      element("defs", [], [gradient("glow", style.glow), gradient("face", style.face)]),
      element("rect", width: 120, height: 120, rx: 15, fill: "url(#glow)"),
      element("rect", x: 3, y: 3, width: 114, height: 114, rx: 12, fill: "url(#face)"),
      element("rect",
        x: 9,
        y: 10,
        width: 26,
        height: 26,
        rx: 8,
        fill: "#ffffff",
        "fill-opacity": "0.08"
      ),
      Marks.epic(field(face, :icon), style.accent),
      Marks.provider(field(face, :vendor), 41, 14, 18, field(face, :vendor_logo)),
      text(ticket_number(identifier), 111, 29, 14, "text-anchor": "end"),
      if(field(face, :priority, false), do: text("★", 66, 14, 9, fill: "#ffcf87"), else: []),
      title_lines(title),
      text(state_label, 9, 99, min(10, div(170, max(String.length(state_label), 1))), fill: style.accent, "data-part": "status-label"),
      footer(face, percent, freshness)
    ]

    Svg.image(content, 120, 120, label(face, style, percent, freshness))
  end

  defp label(face, style, percent, freshness) do
    reading =
      if is_number(percent) and to_string(freshness) != "unknown",
        do: " #{percent}%",
        else: " progress unknown"

    stale = if to_string(freshness) == "stale", do: " stale", else: ""

    "#{field(face, :identifier)} #{state_label(face, style)}#{reading}#{stale} — #{field(face, :title)}"
  end

  defp state_label(face, style) do
    case {field(face, :queue_position), field(face, :state), field(face, :face)} do
      {position, state, palette} when is_integer(position) and position >= 0 and (state in [:queued, "queued"] or is_nil(palette)) -> "Queued ##{position + 1}"
      _ -> style.label
    end
  end

  defp title_lines(title) do
    title
    |> Svg.wrap(Svg.budget(120, 9, 14), 3)
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      text(line, 9, 51 + index * 16, 14, "data-part": "title-line")
    end)
  end

  defp footer(face, percent, freshness) do
    if to_string(field(face, :bucket, "queued")) == "queued" do
      label = if field(face, :dependency_ready) == true, do: "Unblocked", else: "Blocked"
      text(label, 9, 112, 9, fill: if(label == "Unblocked", do: "#88e0a6", else: "#ff9a90"))
    else
      if is_number(percent) or is_nil(field(face, :face)), do: Parts.bar(percent, freshness, 9, 106, 102), else: []
    end
  end

  defp gradient(id, [first, last]) do
    element("linearGradient", [id: id, x1: 0, y1: 0, x2: 0, y2: 1], [
      element("stop", offset: "0%", "stop-color": first),
      element("stop", offset: "100%", "stop-color": last)
    ])
  end

  defp ticket_number(identifier),
    do: identifier |> to_string() |> String.split(~r/[-#]/) |> List.last() |> String.slice(0, 5)
end
