defmodule AiurWeb.Streamdeck.Render.Parts do
  @moduledoc false

  alias AiurWeb.Streamdeck.Render.{StripBand, Svg}
  import Svg, only: [element: 2, element: 3, text: 4, text: 5, field: 2, field: 3]

  @spec bar(term(), term(), number(), number(), number()) :: iodata()
  def bar(percent, freshness, x, y, width) do
    known = is_number(percent) and to_string(freshness) != "unknown"
    stale = to_string(freshness) == "stale"

    element(
      "g",
      [opacity: if(stale, do: "0.45", else: "1"), "data-freshness": freshness || "unknown"],
      [
        element("rect",
          "data-part": "progress-track",
          x: x,
          y: y,
          width: width,
          height: 6,
          rx: 3,
          fill: "#555b66"
        ),
        if known do
          percent = min(max(percent, 0), 100)
          color = if percent == 100, do: "#74d47f", else: "#3fb950"

          element("rect",
            "data-part": "progress-fill",
            x: x,
            y: y,
            width: max(width * percent / 100, 6),
            height: 6,
            rx: 3,
            fill: color
          )
        else
          []
        end
      ]
    )
  end

  @spec title_bar(map(), pos_integer()) :: iodata()
  def title_bar(part, width) do
    [
      line(field(part, :title, ""), width, 16, 12),
      line(field(part, :label, ""), width, 34, 11),
      bar(field(part, :percent), field(part, :freshness, "unknown"), 10, 44, width - 20)
    ]
  end

  @spec meter_row(map(), pos_integer()) :: iodata()
  def meter_row(part, width) do
    y = field(part, :y, 24)
    percent = field(part, :percent)
    label = field(part, :label, "")
    freshness = field(part, :freshness, "unknown")

    reading =
      if is_number(percent) and to_string(freshness) != "unknown",
        do: "#{percent}%#{field(part, :suffix, "")}",
        else: "Unknown"

    compact = field(part, :compact, false)
    age = field(part, :age_label, "")

    element("g", ["data-provider": field(part, :provider, "")], [
      line("#{label} #{reading}", if(compact, do: width - 100, else: width), y, 10),
      bar(percent, freshness, 10, y + 5, width - 20),
      if(compact and age != "",
        do: text(age, width - 10, y, 8, "text-anchor": "end"),
        else: line(age, width, y + 22, 8)
      )
    ])
  end

  @spec count_row(map(), pos_integer()) :: iodata()
  def count_row(part, width), do: line(field(part, :label, ""), width, field(part, :y, 75), 11)

  @spec text_line(map(), pos_integer()) :: iodata()
  def text_line(part, width) do
    part
    |> field(:text, "")
    |> to_string()
    |> Svg.wrap(Svg.budget(width, 10, field(part, :size, 10)), 1)
    |> Enum.map(
      &text(&1, 10, field(part, :y, 90), field(part, :size, 10),
        fill: field(part, :colour, "#f1f3f6"),
        "data-log-kind": field(part, :shape, "")
      )
    )
  end

  @spec pager(map(), pos_integer()) :: iodata()
  def pager(part, width) do
    [
      line(field(part, :title, "MORE AGENTS"), width, 24, 12),
      line(field(part, :label, ""), width, 50, 12),
      text(if(field(part, :previous, false), do: "‹", else: "·"), 18, 80, 22),
      text(if(field(part, :next, false), do: "›", else: "·"), width - 18, 80, 22, "text-anchor": "end")
    ]
  end

  @spec draw(map(), pos_integer()) :: iodata()
  def draw(part, width) do
    case to_string(field(part, :kind)) do
      "title_bar" -> title_bar(part, width)
      "meter_row" -> meter_row(part, width)
      "count_row" -> count_row(part, width)
      "text_line" -> text_line(part, width)
      "pager" -> pager(part, width)
      "category_chips" -> StripBand.chips(field(part, :model))
      "backlog" -> StripBand.backlog(part)
    end
  end

  defp line(value, width, y, size) do
    value
    |> to_string()
    |> Svg.wrap(Svg.budget(width, 10, size), 1)
    |> Enum.map(&text(&1, 10, y, size))
  end
end
