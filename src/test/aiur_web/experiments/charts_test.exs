defmodule AiurWeb.Experiments.ChartsTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.ChartData
  alias AiurWeb.Experiments.{Charts, Styles, ViewModel}
  alias AiurWeb.Experiments.Charts.Svg

  defp fixture do
    raw = File.read!(Path.expand("../../aiur/experiments/fixtures/chart_detail.json", __DIR__)) |> Jason.decode!()
    detail = %{spec: raw["spec"], analysis: raw["analysis"], snapshots: raw["snapshots"], annotations: raw["annotations"], phase: :collecting}
    {:ok, detail} = ChartData.attach({:ok, detail}, [])
    ViewModel.detail(detail)
  end

  defp html(safe), do: Phoenix.HTML.safe_to_string(safe)

  test "AE1 draws sixteen samples, a hollow guard without CI and six remaining after the line" do
    detail = fixture()
    metric = hd(detail.chart_metrics) |> Map.put(:effect, %{estimate: -30, lo: -45, hi: -10})
    forest = html(Charts.forest([metric]))
    assert forest =~ "exp-hollow"
    assert forest =~ "not enough data"
    refute forest =~ "exp-ci"
    [forest_row] = Floki.find(Floki.parse_fragment!(forest), "tbody tr")
    assert Enum.map(Floki.find(forest_row, "td"), &Floki.text/1) == [metric.label, "not enough data", "not enough data", "not enough data", "not enough data"]
    assert html(Charts.power([metric], detail)) =~ "needs 6 more after the line"
    distribution = html(Charts.distribution(metric)) |> Floki.parse_fragment!()
    assert length(Floki.find(distribution, "svg .exp-point")) == 16
    assert Floki.text(distribution) =~ "100 to 100.11"
    assert length(Floki.find(distribution, "table caption") |> Enum.filter(&(Floki.text(&1) == "Distribution samples"))) == 1
    assert length(Floki.find(distribution, "details:last-child tbody tr")) == 16
  end

  test "an unguarded missing effect stays unavailable in the forest and every estimate cell" do
    metric = hd(fixture().chart_metrics) |> Map.merge(%{guarded?: false, effect: %{estimate: nil, lo: nil, hi: nil}})
    chart = html(Charts.forest([metric])) |> Floki.parse_fragment!()
    assert Floki.text(Floki.find(chart, "svg")) =~ "Percent change unavailable"
    assert length(Floki.find(chart, "svg .exp-hollow")) == 1
    assert Floki.find(chart, "svg .exp-ci") == []
    [row] = Floki.find(chart, "tbody tr")
    assert Enum.map(Floki.find(row, "td"), &Floki.text/1) == [metric.label, "Unavailable", "Unavailable", "Unavailable", "Stored evidence"]
  end

  test "AE3 expected direction occupies the negative side and crossing CI stays neutral" do
    metric = hd(fixture().chart_metrics) |> Map.merge(%{guarded?: false, effect: %{estimate: -20, lo: -40, hi: 10}})
    chart = html(Charts.forest([metric])) |> Floki.parse_fragment!()
    assert ["100"] == Floki.attribute(Floki.find(chart, ".exp-expected"), "x")
    assert chart |> Floki.text() =~ "expected"
    assert [bar] = Floki.find(chart, ".exp-ci")
    assert Floki.attribute(bar, "x1") |> hd() |> String.to_float() < 340
    assert Floki.attribute(bar, "x2") |> hd() |> String.to_float() > 340
    refute Floki.find(chart, ".exp-estimate") == []
  end

  test "AE2 cohorts use a labelled palette and distinct shapes, with no change rule" do
    detail = fixture() |> Map.put(:design, %{"kind" => "ab"})
    metric = hd(detail.chart_metrics)
    chart = html(Charts.distribution(Map.put(metric, :cohorts?, true))) |> Floki.parse_fragment!()
    assert length(Floki.find(chart, ".exp-series-0 circle")) == 12
    assert length(Floki.find(chart, ".exp-series-1 rect")) == 4
    assert Floki.text(chart) =~ "Before"
    assert Floki.text(chart) =~ "After"
    refute html(Charts.time_series(metric, detail)) =~ "exp-line-rule"
    css = Styles.css()
    assert css =~ ".exp-series-0{fill:var(--an-s1)}"
    assert css =~ ".exp-series-1{fill:var(--an-s2)}"
  end

  test "jitter is byte stable, labels are escaped and log powers are equally spaced" do
    metric = hd(fixture().chart_metrics) |> Map.merge(%{label: "<script>latency</script>", scale: "log"})
    metric = %{metric | groups: Enum.map(metric.groups, &%{&1 | name: "\" onload=\"evil", label: "<b>Group</b>"})}
    first = html(Charts.distribution(metric))
    assert first == html(Charts.distribution(metric))
    assert first =~ "&lt;script&gt;latency&lt;/script&gt;"
    refute first =~ "<script>"
    assert Floki.find(Floki.parse_fragment!(first), "[onload]") == []
    assert first =~ "&lt;b&gt;Group&lt;/b&gt;"
    assert Svg.ticks({0, 1}, "linear") == [0.0, 0.25, 0.5, 0.75, 1.0]
    assert Svg.ticks({0, 37}, "linear") == [0.0, 10.0, 20.0, 30.0]
    assert Svg.ticks({0.5, 9000}, "log") == [1.0, 10.0, 100.0, 1000.0]
    assert Svg.position(10, {1, 100}, {0, 100}, "log") == 50.0
    assert Svg.position(100, {1, 100}, {0, 100}, "log") == 100.0
    parsed = Floki.parse_fragment!(first)
    assert Floki.attribute(Floki.find(parsed, ".exp-point circle"), "cx") |> Enum.uniq() |> length() > 1
  end

  test "time series renders frozen windows, change and confounder labels, and supplied rolling line only" do
    detail = fixture()
    metric = hd(detail.chart_metrics)
    chart = html(Charts.time_series(metric, detail))
    assert length(Floki.find(Floki.parse_fragment!(chart), "svg .exp-grid")) == 4
    assert chart =~ "exp-frozen"
    assert chart =~ "exp-line-rule"
    assert chart =~ "v0.0.9"
    assert chart =~ "Release &lt;overlap&gt;"
    assert chart =~ "exp-confounder"
    refute chart =~ "exp-rolling"
    assert length(Floki.find(Floki.parse_fragment!(chart), "tbody tr")) == 16
    rolling = [%{"points" => [%{"at" => "2026-10-08T00:00:00Z", "value" => 100}, %{"at" => "2026-10-10T00:00:00Z", "value" => 70}]}]
    assert html(Charts.time_series(%{metric | rolling: rolling}, detail)) =~ "exp-rolling"
  end

  test "missing power estimates remain unavailable rather than showing zero percent" do
    detail = fixture()
    metric = hd(detail.chart_metrics)
    chart = html(Charts.power([metric], detail))
    assert metric.power["power_at_current_n"] == nil
    assert chart =~ "power requirement unavailable"
    [row | _] = Floki.find(Floki.parse_fragment!(chart), "tbody tr")
    cells = Enum.map(Floki.find(row, "td"), &Floki.text/1)
    assert Enum.at(cells, 4) == "Unavailable"
    assert Enum.at(cells, 5) == "Unavailable"
    refute chart =~ "0% power"
    group = hd(metric.groups)
    empty = %{group | n: 0, median: nil, q1: nil, q3: nil, whiskers: nil, points: []}
    assert empty.whiskers == nil
    distribution = html(Charts.distribution(%{metric | groups: [empty]})) |> Floki.parse_fragment!()
    [summary_table, _samples_table] = Floki.find(distribution, "table")
    summary_cells = Floki.find(summary_table, "tbody td") |> Enum.map(&Floki.text/1)
    assert List.last(summary_cells) == "Unavailable"
  end

  test "power targets render the supplied effect and power, never invented defaults" do
    detail = fixture()
    metric = hd(detail.chart_metrics) |> Map.merge(%{mde: 0.15, power_target: 0.8, power: %{"samples_needed_per_group" => 10}})
    metric = %{metric | groups: Enum.map(metric.groups, &Map.put(&1, :needed, 10))}
    chart = html(Charts.power([metric], detail))
    assert chart =~ "enough samples for a 15% effect at 80% power"
    assert chart =~ "needs 6 more after the line"
    assert html(Charts.power([%{metric | mde: nil}], detail)) =~ "target effect size or power unavailable"
  end

  test "single sample keeps its median and outside-window points remain visible and tabulated" do
    detail = fixture()
    metric = hd(detail.chart_metrics)
    group = hd(metric.groups)
    point = hd(group.points) |> Map.put("at", "2026-09-20T00:00:00Z")
    metric = %{metric | groups: [%{group | n: 1, q1: 100, q3: 100, median: 100, points: [point]}]}
    chart = html(Charts.distribution(metric)) |> Floki.parse_fragment!()
    assert length(Floki.find(chart, ".exp-median")) == 1
    assert length(Floki.find(chart, ".exp-point")) == 1
    assert Floki.find(chart, ".exp-box") == []
    times = html(Charts.time_series(metric, detail)) |> Floki.parse_fragment!()
    assert length(Floki.find(times, ".exp-outside")) == 1
    assert Floki.text(Floki.find(times, "tbody")) =~ "Outside window"
  end

  test "capped point sets keep full distribution whiskers inside the plot" do
    metric = hd(fixture().chart_metrics)
    group = hd(metric.groups)
    group = %{group | points: [hd(group.points)], n: 600, median: 100, q1: 99, q3: 101, whiskers: {98, 103}}
    chart = html(Charts.distribution(%{metric | groups: [group]})) |> Floki.parse_fragment!()
    [line] = Floki.find(chart, ".exp-whisker")
    assert Floki.attribute(line, "y1") == ["240.0"]
    assert Floki.attribute(line, "y2") == ["20.0"]
    assert Floki.text(chart) =~ "n 600, showing 1"
  end

  test "a fifth cohort keeps a distinct marker when the palette repeats" do
    metric = hd(fixture().chart_metrics)
    group = hd(metric.groups)
    point = hd(group.points)
    value = point["value"]

    groups =
      for index <- 0..4,
          do: %{
            group
            | name: "cohort-#{index}",
              label: "Cohort #{index + 1}",
              n: 1,
              median: value,
              q1: value,
              q3: value,
              whiskers: {value, value},
              points: [Map.put(point, "unit_id", "sample-#{index}")]
          }

    chart = html(Charts.distribution(%{metric | groups: groups, cohorts?: true})) |> Floki.parse_fragment!()
    assert length(Floki.find(chart, "svg .exp-point")) == 5
    assert length(Floki.find(chart, "svg .exp-series-0 circle")) == 1
    assert Floki.text(Floki.find(chart, "svg .exp-series-0 text")) == "5"
  end
end
