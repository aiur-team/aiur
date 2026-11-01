defmodule AiurWeb.Streamdeck.Render.FleetMeters do
  @moduledoc false
  alias AiurWeb.RemainingMeter
  alias AiurWeb.Streamdeck.Deck.Meters
  import AiurWeb.Streamdeck.Render.Svg, only: [field: 2, field: 3]

  @spec compose([map()], map(), integer()) :: [map()]
  def compose(regions, usage, offset) do
    providers = usage |> Meters.providers() |> Enum.sort_by(&elem(&1, 0))
    offset = offset |> max(0) |> min(max(length(providers) - 3, 0))
    providers = providers |> Enum.drop(offset) |> Enum.take(3)

    providers =
      Enum.with_index(providers, fn {name, meter}, index ->
        part = meter_part(name, meter, field(field(meter, :windows), :session), 34 + index * 26)
        Map.put(part, :compact, part.age_label != "")
      end)

    apis = for row <- field(usage, :apis, []), line <- field(row, :lines, []), do: api_part(row, line)
    apis = Enum.with_index(apis, &Map.put(&1, :y, 34 + &2 * 26))

    regions |> List.update_at(1, &with_meters(&1, providers)) |> List.update_at(2, &with_meters(&1, apis))
  end

  defp meter_part(name, meter, window, y) do
    percent = window |> field(:used_percent) |> RemainingMeter.percent()
    freshness = field(window, :freshness, field(meter, :freshness, :unknown))
    percent = if to_string(field(meter, :state)) == "observed", do: percent
    age = field(window, :age_seconds, field(meter, :age_seconds))
    age_label = if is_number(age), do: "#{age}s old", else: ""
    stale_label = if to_string(freshness) == "stale", do: " stale", else: ""

    %{kind: :meter_row, provider: name, label: name, percent: percent, suffix: " left", freshness: freshness, age_label: age_label <> stale_label, y: y}
  end

  defp with_meters(region, parts) do
    header = Enum.map(region.parts, &Map.put(&1, :y, 14))
    %{region | parts: header ++ parts}
  end

  defp api_part(row, line) do
    hold = field(line, :hold_until)
    held = if is_integer(hold), do: " ⏸ held until #{Calendar.strftime(DateTime.from_unix!(hold, :millisecond), "%H:%M")}", else: " left"
    tag = field(line, :tag)
    label = if field(row, :name) == "GitHub", do: tag, else: "E #{tag}"
    stale = field(row, :stale) == true
    percent = if stale, do: nil, else: field(line, :remaining_percent)
    # A stale or unknown reading shows "—" with its age, never a number.
    age = field(row, :age_seconds)

    age_label =
      cond do
        is_number(percent) -> ""
        is_number(age) -> "#{age}s old"
        true -> "never"
      end

    %{
      kind: :meter_row,
      provider: field(row, :name),
      label: label,
      percent: percent,
      freshness: if(stale, do: :stale, else: :fresh),
      age_label: age_label,
      compact: age_label != "",
      suffix: held,
      unknown_label: "—",
      tip: field(line, :tip)
    }
  end
end
