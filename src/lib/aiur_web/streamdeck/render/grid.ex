defmodule AiurWeb.Streamdeck.Render.Grid do
  @moduledoc false

  alias AiurWeb.RemainingMeter

  import AiurWeb.Streamdeck.Render.Svg, only: [field: 2, field: 3]

  @spec compose(map()) :: {[map() | nil], [map()]}
  def compose(%{grid: grid, nav: %{view: :epic} = nav}), do: AiurWeb.Streamdeck.Deck.EpicFrame.compose(grid, nav)

  def compose(model) do
    grid = field(model, :grid) || model
    agents = field(grid, :agents, [])
    max_offset = max(ceil(length(agents) / 2) - 4, 0)
    offset = clamp_offset(field(model, :column_offset, 0), max_offset)
    unavailable = field(grid, :tickets_status) == "unavailable"
    faces = Enum.map(0..7, &Enum.at(agents, (offset + rem(&1, 4)) * 2 + div(&1, 4)))
    faces = if unavailable, do: [%{title: "Tickets unavailable", label: "Unavailable", face: :unknown, bucket: :stuck} | List.duplicate(nil, 7)], else: faces
    providers = model |> field(:usage, %{}) |> Enum.sort_by(fn {name, _meter} -> to_string(name) end)

    regions =
      [summary(grid, agents)] ++
        provider_regions(providers, field(model, :provider_offset, 0)) ++
        [if(unavailable, do: region(600, 200, "Tickets unavailable", [%{kind: :text_line, text: "Tickets unavailable", y: 50, size: 12}]), else: pager(offset, max_offset, length(agents)))]

    {faces, feedback(regions, field(model, :toast))}
  end

  defp feedback(regions, toast) when is_binary(toast) do
    List.replace_at(regions, 0, region(0, 200, toast, [%{kind: :text_line, text: toast, y: 50, size: 12}]))
  end

  defp feedback(regions, _toast), do: regions

  defp summary(grid, agents) do
    live = Enum.count(agents, &(to_string(field(&1, :bucket)) != "queued"))
    remaining = length(agents) - live
    count = if field(grid, :tickets_status) == "unavailable", do: "Tickets unavailable", else: "#{live} live / #{remaining} left"
    build = field(grid, :build)
    percent = field(build, :percent)

    label =
      case {to_string(field(grid, :build_status)), build, percent} do
        {"unavailable", _, _} -> "Build unavailable"
        {_, nil, _} -> "No build order"
        {_, _, nil} -> "Build unknown"
        _ -> "Build #{percent}%"
      end

    region(0, 200, "#{count}; #{label}", [
      %{kind: :title_bar, title: "AIUR", label: label, percent: percent, freshness: if(is_number(percent), do: :fresh, else: :unknown)},
      %{kind: :count_row, label: count}
    ])
  end

  defp provider_regions(providers, offset) when length(providers) >= 3 do
    offset = clamp_offset(offset, length(providers) - 3)
    visible = Enum.slice(providers, offset, 3)

    parts =
      visible
      |> Enum.with_index()
      |> Enum.map(fn {{name, meter}, index} ->
        window = field(field(meter, :windows, %{}), :session)
        meter_part(name, meter, window, 16 + index * 26) |> Map.put(:compact, true)
      end)

    label = "Providers #{offset + 1}–#{offset + length(visible)} / #{length(providers)}"
    [region(200, 400, label, parts ++ [%{kind: :text_line, text: label, y: 96, size: 8}])]
  end

  defp provider_regions(providers, _offset) do
    Enum.map(0..1, fn slot ->
      case Enum.at(providers, slot) do
        nil -> region(200 + slot * 200, 200, "", [])
        {name, meter} -> provider_region(name, meter, 200 + slot * 200)
      end
    end)
  end

  defp provider_region(name, meter, x) do
    windows = field(meter, :windows, %{})

    parts = [
      %{kind: :text_line, text: name, y: 20, size: 13},
      %{kind: :text_line, text: field(meter, :summary_label) || "", y: 37, size: 9},
      meter_part("Session", meter, field(windows, :session), 60)
    ]

    region(x, 200, to_string(name), parts)
  end

  defp meter_part(name, meter, window, y) do
    percent = window |> field(:used_percent) |> RemainingMeter.percent()
    freshness = field(window, :freshness, field(meter, :freshness, :unknown))
    percent = if to_string(field(meter, :state)) == "observed", do: percent
    age = field(window, :age_seconds, field(meter, :age_seconds))
    age_label = if is_number(age), do: "#{age}s old", else: ""
    stale_label = if to_string(freshness) == "stale", do: " stale", else: ""
    %{kind: :meter_row, label: name, percent: percent, suffix: " left", freshness: freshness, age_label: age_label <> stale_label, y: y}
  end

  defp pager(offset, max_offset, total) do
    label = if total == 0, do: "0 agents", else: "#{offset * 2 + 1}–#{min(offset * 2 + 8, total)} / #{total}"
    region(600, 200, label, [%{kind: :pager, label: label, previous: offset > 0, next: offset < max_offset}])
  end

  defp region(x, width, label, parts), do: %{x: x, width: width, label: label, parts: parts}
  defp clamp_offset(offset, maximum) when is_integer(offset), do: offset |> max(0) |> min(maximum)
  defp clamp_offset(_offset, _maximum), do: 0
end
