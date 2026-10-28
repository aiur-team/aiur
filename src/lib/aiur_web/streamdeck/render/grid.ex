defmodule AiurWeb.Streamdeck.Render.Grid do
  @moduledoc false

  alias AiurWeb.Streamdeck.Render.{StripBand, StripCounts}

  import AiurWeb.Streamdeck.Render.Svg, only: [field: 2, field: 3]

  @spec compose(map()) :: {[map() | nil], [map()]}
  def compose(model) do
    grid = field(model, :grid) || model
    agents = field(grid, :agents, [])
    max_offset = max(ceil(length(agents) / 2) - 4, 0)
    offset = clamp_offset(field(model, :column_offset, 0), max_offset)
    unavailable = field(grid, :tickets_status) == "unavailable"
    faces = Enum.map(0..7, &Enum.at(agents, (offset + rem(&1, 4)) * 2 + div(&1, 4)))
    faces = if unavailable, do: [%{title: "Tickets unavailable", label: "Unavailable", face: :unknown, bucket: :stuck} | List.duplicate(nil, 7)], else: faces
    chip_offset = field(model, :chip_offset, field(field(model, :nav), :chip_offset, 0))
    counts = StripCounts.model(field(grid, :counts), chip_offset)
    regions = [summary(grid) | StripBand.regions(counts, offset, length(agents))]

    {faces, feedback(regions, field(model, :toast))}
  end

  defp feedback(regions, toast) when is_binary(toast) do
    List.replace_at(regions, 0, region(0, 200, toast, [%{kind: :text_line, text: toast, y: 50, size: 12}]))
  end

  defp feedback(regions, _toast), do: regions

  defp summary(grid) do
    build = field(grid, :build)
    percent = field(build, :percent)

    label =
      case {to_string(field(grid, :build_status)), build, percent} do
        {"unavailable", _, _} -> "Build unavailable"
        {_, nil, _} -> "No build order"
        {_, _, nil} -> "Build unknown"
        _ -> "Build #{percent}%"
      end

    region(0, 200, label, [
      %{kind: :title_bar, title: "AIUR", label: label, percent: percent, freshness: if(is_number(percent), do: :fresh, else: :unknown)}
    ])
  end

  defp region(x, width, label, parts), do: %{x: x, width: width, label: label, parts: parts}
  defp clamp_offset(offset, maximum) when is_integer(offset), do: offset |> max(0) |> min(maximum)
  defp clamp_offset(_offset, _maximum), do: 0
end
