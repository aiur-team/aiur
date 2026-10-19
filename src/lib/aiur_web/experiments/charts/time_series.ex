defmodule AiurWeb.Experiments.Charts.TimeSeries do
  @moduledoc false
  alias AiurWeb.Experiments.Charts.Svg

  @spec render(map(), map()) :: String.t()
  def render(metric, detail) do
    points = for {group, index} <- Enum.with_index(metric.groups), point <- group.points, is_number(time(point["at"])), do: {group, index, point}
    dates = Enum.map(points, fn {_, _, point} -> time(point["at"]) end) ++ window_dates(detail)
    times = Svg.domain(dates)
    values = Svg.domain(Enum.map(points, fn {_, _, point} -> point["value"] end), metric.scale)
    dots = Enum.map(points, &dot(&1, times, values, metric, detail))
    body = [windows(detail, times), value_grid(values, metric), line_rule(detail, times), annotations(detail, times), rolling(metric, times, values), dots, axis(times)]
    rows = Enum.map(points, fn {group, _, point} -> [group.label, point["unit_id"], point["at"], Svg.number(point["value"]), if(outside?(point, detail), do: "Outside window", else: "In window")] end)
    svg = Svg.wrap("#{metric.label} over time in #{metric.unit}; #{length(points)} samples. Group marker shapes match the distribution.", 280, body)

    ~s(<div class="exp-series-scroll" role="region" aria-label="#{Svg.escape(metric.label)} over time" tabindex="0"><div class="exp-series-canvas">#{svg}</div></div>) <>
      Svg.table("Time series samples", ~w(Group Sample Time Value Window), rows)
  end

  defp value_grid(values, metric) do
    for value <- Svg.ticks(values, metric.scale) do
      y = Svg.position(value, values, {235, 35}, metric.scale)
      [Svg.line(55, y, 615, y, "exp-grid"), Svg.text(0, y, Svg.number(value))]
    end
  end

  defp dot({group, index, point}, times, values, metric, detail) do
    scale = metric.scale

    if scale != "log" or point["value"] > 0 do
      class = if outside?(point, detail), do: "exp-point exp-outside", else: "exp-point"
      class = if metric.cohorts?, do: class, else: class <> " exp-#{group.name}"
      Svg.marker(x(time(point["at"]), times), Svg.position(point["value"], values, {235, 35}, scale), index, class)
    else
      ""
    end
  end

  defp windows(detail, times) do
    for {name, window} <- Enum.sort(detail.windows), start = time(window["start"]), is_number(start) do
      stop = time(window["end"]) || elem(times, 1)
      frozen = if name == "before" and is_map(detail.frozen_baseline), do: " exp-frozen", else: ""
      Svg.rect(x(start, times), 30, max(x(stop, times) - x(start, times), 0), 210, "exp-window-shade exp-window-#{name}" <> frozen)
    end
  end

  defp line_rule(%{design: %{"kind" => "before_after", "change" => change}}, times) do
    case time(change["time"]) do
      nil -> ""
      at -> [Svg.line(x(at, times), 20, x(at, times), 240, "exp-line-rule"), Svg.text(x(at, times) + 4, 18, change["ref"])]
    end
  end

  defp line_rule(_, _), do: ""

  defp annotations(detail, times) do
    for annotation <- detail.annotations, at = time(annotation["at"] || annotation["time"]), is_number(at) do
      label = annotation["label"] || annotation["reason"] || "Confounder"
      [~s(<g class="exp-confounder"><title>#{Svg.escape(label)}</title>), Svg.line(x(at, times), 25, x(at, times), 40), Svg.text(x(at, times) + 3, 28, label), "</g>"]
    end
  end

  defp rolling(metric, times, values) do
    for series <- metric.rolling do
      points =
        for point <- series["points"] || [],
            at = time(point["at"]),
            is_number(at) and is_number(point["value"]) and (metric.scale != "log" or point["value"] > 0),
            do: "#{x(at, times)},#{Svg.position(point["value"], values, {235, 35}, metric.scale)}"

      ~s(<polyline class="exp-rolling" points="#{Enum.join(points, " ")}" fill="none" stroke="currentColor" />)
    end
  end

  defp axis({lo, hi}) do
    [Svg.line(55, 245, 615, 245), Svg.text(55, 267, stamp(lo)), Svg.text(470, 267, stamp(hi))]
  end

  defp stamp(value), do: value |> round() |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_iso8601()
  defp x(at, domain), do: Svg.position(at, domain, {55, 615})
  defp window_dates(detail), do: detail.windows |> Map.values() |> Enum.flat_map(&[time(&1["start"]), time(&1["end"])]) |> Enum.filter(&is_number/1)

  defp outside?(point, detail) do
    at = time(point["at"])

    not Enum.any?(detail.windows, fn {_name, window} ->
      start = time(window["start"])
      stop = time(window["end"])
      is_number(start) and at >= start and (is_nil(stop) or at < stop)
    end)
  end

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _} -> DateTime.to_unix(parsed)
      _ -> nil
    end
  end

  defp time(_), do: nil
end
