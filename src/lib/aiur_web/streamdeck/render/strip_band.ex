defmodule AiurWeb.Streamdeck.Render.StripBand do
  @moduledoc false
  import AiurWeb.Streamdeck.Render.Svg, only: [element: 2, element: 3, text: 4]

  @spec regions(map(), non_neg_integer(), non_neg_integer()) :: [map()]
  def regions(model, offset, total) do
    label =
      if model.status == "unavailable" do
        "Counts unavailable"
      else
        Enum.map_join(model.visible, "; ", &"#{&1.label} #{&1.count}") <>
          if(model.more > 0, do: "; +#{model.more} more", else: "") <> if(model.status == "stale", do: "; stale", else: "")
      end

    backlog = "Queued #{reading(model.backlog.queued)}; Not queued #{reading(model.backlog.not_queued)}"

    [
      %{x: 200, width: 400, label: label, parts: [%{kind: :category_chips, model: model}]},
      %{x: 600, width: 200, label: backlog, parts: [%{kind: :backlog, model: model, offset: offset, total: total}]}
    ]
  end

  @spec chips(map()) :: iodata()
  def chips(%{status: "unavailable"}), do: text("Counts unavailable", 15, 52, 18)

  def chips(model) do
    chips = model.visible
    chips = if model.more > 0, do: chips ++ [%{count: "+#{model.more} more", color: "#c2c6cf", state: "more", glyph: nil}], else: chips

    element("g", [opacity: if(model.status == "stale", do: "0.45", else: "1"), "data-status": model.status], [
      text(if(model.status == "stale", do: "Agents · stale", else: "Agents"), 10, 16, 11),
      chips
      |> Enum.with_index()
      |> Enum.map(fn {chip, index} ->
        x = 10 + rem(index, 4) * 98
        y = 44 + div(index, 4) * 36

        element("g", [fill: chip.color, color: chip.color, "data-state": chip.state, "aria-label": "#{chip.glyph} #{chip.count}"], [
          glyph(chip.glyph, x, y),
          text(chip.count, x + if(chip.glyph, do: 20, else: 0), y, 15)
        ])
      end)
    ])
  end

  @spec backlog(map()) :: iodata()
  def backlog(%{model: model, offset: offset, total: total}) do
    pages = max(ceil(total / 8), 1)
    max_offset = max(ceil(total / 2) - 4, 0)
    page = if offset >= max_offset, do: pages - 1, else: min(div(offset, 4), pages - 1)
    first = max(min(page - 4, pages - 9), 0)
    last = min(first + 8, pages - 1)

    [
      text("Queued #{reading(model.backlog.queued)}", 10, 24, 15),
      text("Not queued #{reading(model.backlog.not_queued)}", 10, 47, 13),
      Enum.map(first..last, fn index ->
        element("circle", cx: 12 + (index - first) * 19, cy: 73, r: 4, fill: if(index == page, do: "#9fd0ff", else: "#555b66"), "data-page": index)
      end),
      text("#{page + 1} / #{pages}", 10, 95, 10)
    ]
  end

  defp reading(count) when is_integer(count) and count >= 0, do: to_string(count)
  defp reading(_count), do: "unknown"

  # These glyphs are absent from the shipped mono font; draw their shapes.
  defp glyph("◷", x, y) do
    element("g", [transform: "translate(#{x},#{y - 11})", fill: "none", stroke: "currentColor"], [
      element("circle", cx: 6, cy: 6, r: 5),
      element("path", d: "M6 1 V6 H11")
    ])
  end

  defp glyph("↻", x, y) do
    element("g", [transform: "translate(#{x},#{y - 11})"], [
      element("path", d: "M10 4 A5 5 0 1 0 11 8", fill: "none", stroke: "currentColor"),
      element("path", d: "M7 4 H12 V0 Z")
    ])
  end

  defp glyph("Ⅱ", x, y), do: element("path", d: "M#{x + 2} #{y - 11} v11 m5 -11 v11", stroke: "currentColor", "stroke-width": 2)
  defp glyph(nil, _x, _y), do: []
  defp glyph(value, x, y), do: text(value, x, y, 15)
end
