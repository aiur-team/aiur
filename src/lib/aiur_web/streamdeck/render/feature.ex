defmodule AiurWeb.Streamdeck.Render.Feature do
  @moduledoc false
  alias AiurWeb.Streamdeck.Render.{Parts, Svg}
  import Svg, only: [field: 2, text: 5, element: 2]

  @spec render(map()) :: map()
  def render(face) do
    pct = field(face, :pct)
    reading = if is_integer(pct), do: "#{pct}%", else: "—"
    label = "#{field(face, :label)} #{reading} #{field(face, :reason)}"
    unknown = !is_integer(pct)

    title =
      face
      |> field(:label)
      |> Svg.wrap(15, if(unknown, do: 2, else: 3))
      |> Enum.with_index()
      |> Enum.map(fn {line, index} -> text(line, 9, 22 + index * 16, 12, []) end)

    badge = if field(face, :ci_wait), do: text("CI #{field(face, :ci_wait)}", 111, if(unknown, do: 75, else: 96), 10, "text-anchor": "end"), else: []
    reason = if unknown, do: reason_lines(field(face, :reason)), else: []
    content = [element("rect", width: 120, height: 120, rx: 12, fill: "#101318"), title, text(reading, 9, if(unknown, do: 75, else: 87), 24, []), badge, bar(field(face, :bar)), reason]
    Svg.image(content, 120, 120, label)
  end

  defp reason_lines(reason) do
    reason
    |> to_string()
    |> Svg.wrap(Svg.budget(120, 9, 7), 3)
    |> Enum.with_index()
    |> Enum.map(fn {line, index} -> text(line, 9, 89 + index * 10, 7, []) end)
  end

  defp bar(bar) when is_map(bar) do
    total = field(bar, :total)

    if total > 0 do
      [{:closed, "#88e0a6"}, {:open, "#86bfff"}, {:unpublished, "#737983"}]
      |> Enum.map_reduce(9, fn {kind, color}, x ->
        count = layer_count(bar, kind)
        width = 102 * count / total
        {element("rect", x: x, y: 100, width: width, height: 4, fill: color, "data-layer": kind), x + width}
      end)
      |> elem(0)
    else
      Parts.bar(nil, :unknown, 9, 114, 102)
    end
  end

  defp bar(_unknown), do: Parts.bar(nil, :unknown, 9, 114, 102)
  defp layer_count(bar, :open), do: field(bar, :open) + field(bar, :ci_wait)
  defp layer_count(bar, kind), do: field(bar, kind)
end
