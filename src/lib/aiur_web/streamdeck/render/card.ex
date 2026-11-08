defmodule AiurWeb.Streamdeck.Render.Card do
  @moduledoc false
  alias AiurWeb.Streamdeck.Render.{Style, Svg}
  import Svg, only: [field: 2, field: 3]

  @spec render(map()) :: map()
  def render(face) do
    label = field(face, :label, "Key")
    title = field(face, :title) || label
    accent = accent(face)

    content = [
      Svg.element("rect",
        width: 120,
        height: 120,
        rx: 15,
        fill: if(field(face, :live, false), do: "#14291f", else: "#171b24"),
        stroke: accent,
        "stroke-width": 2
      ),
      Svg.text(field(face, :glyph, ""), 60, 35, 26,
        fill: accent,
        "text-anchor": "middle",
        "data-part": "icon",
        "data-dir": field(face, :badge, "")
      ),
      lines(title),
      Svg.text(field(face, :sub, ""), 10, 108, 9, fill: accent, "data-part": "caption")
    ]

    Svg.image(content, 120, 120, label)
  end

  defp lines(title) do
    title
    |> Svg.wrap(12, 3)
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      Svg.text(line, 10, 57 + index * 16, 13, "data-part": "title-line")
    end)
  end

  defp accent(face) do
    cond do
      field(face, :disabled, false) -> "#9096a4"
      field(face, :state) == "live" -> "#ff9a90"
      field(face, :badge) -> Style.direction_badge!(field(face, :badge))["color"]
      field(face, :live, false) -> "#88e0a6"
      field(face, :selected, false) -> "#88e0a6"
      true -> "#9fd0ff"
    end
  end
end
