defmodule Aiur.Experiments.ChartDataTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.ChartData

  defp fixture do
    raw = File.read!(Path.expand("fixtures/chart_detail.json", __DIR__)) |> Jason.decode!()
    %{spec: raw["spec"], analysis: raw["analysis"], snapshots: raw["snapshots"], annotations: raw["annotations"], phase: :collecting}
  end

  test "projection selects the latest frozen arms and preserves stored descriptive values" do
    detail = fixture()
    older = hd(detail.snapshots) |> Map.put("revision", 0) |> put_in(["metrics", "delivery-speed/start_to_merge", "observations"], [])
    {:ok, result} = ChartData.attach({:ok, %{detail | snapshots: [older | detail.snapshots]}}, [])
    [metric | _] = result.chart_metrics
    assert Enum.map(metric.groups, & &1.n) == [12, 4]
    assert Enum.map(metric.groups, &length(&1.points)) == [12, 4]
    assert hd(metric.groups).median == 100.055
    assert hd(metric.groups).whiskers == {100.0, 100.11}
    assert metric.guarded?
  end

  test "stratum requests select stored inference and matching observations, unknown falls back" do
    {:ok, result} = ChartData.attach({:ok, fixture()}, stratum: "complexity:2")
    assert result.strata == ["complexity:2"]
    assert result.stratum == "complexity:2"
    assert Enum.map(hd(result.chart_metrics).groups, & &1.n) == [6, 2]
    assert Enum.map(hd(result.chart_metrics).groups, &length(&1.points)) == [6, 2]
    {:ok, fallback} = ChartData.attach({:ok, fixture()}, stratum: "missing")
    assert fallback.stratum == nil
    assert Enum.map(hd(fallback.chart_metrics).groups, &length(&1.points)) == [12, 4]
  end

  test "relative intervals are projected consistently and absence stays unknown" do
    detail = fixture() |> put_in([:analysis, "metrics", "delivery-speed/start_to_merge", "effects"], %{"median_ratio" => %{"estimate" => 0.8, "lo" => 0.6, "hi" => 1.1}})
    {:ok, result} = ChartData.attach({:ok, detail}, [])
    assert_in_delta hd(result.chart_metrics).effect.estimate, -20, 0.00001
    assert_in_delta hd(result.chart_metrics).effect.lo, -40, 0.00001
    assert_in_delta hd(result.chart_metrics).effect.hi, 10, 0.00001
    assert Enum.at(result.chart_metrics, 1).effect == %{estimate: nil, lo: nil, hi: nil}
    assert ChartData.attach({:error, :not_found}, []) == {:error, :not_found}
  end

  test "cohort projection retains labels, arm order and attribute assignments" do
    detail = fixture()

    design = %{
      "kind" => "ab",
      "control" => "a",
      "cohorts" => [
        %{"id" => "a", "label" => "Cohort Alpha", "where" => %{"attr" => "complexity", "op" => "eq", "value" => 2}},
        %{"id" => "b", "label" => "Cohort Beta", "where" => %{"attr" => "complexity", "op" => "eq", "value" => 3}}
      ]
    }

    detail = %{detail | spec: Map.put(detail.spec, "design", design), analysis: nil}
    {:ok, result} = ChartData.attach({:ok, detail}, [])
    metric = hd(result.chart_metrics)
    assert metric.cohorts?
    assert Enum.map(metric.groups, & &1.label) == ["Cohort Alpha", "Cohort Beta"]
    assert Enum.map(metric.groups, &length(&1.points)) == [8, 8]
  end

  test "power allocation and long-tail log scale are decided by the facade" do
    detail = fixture()
    detail = put_in(detail, [:analysis, "metrics", "delivery-speed/start_to_merge", "power"], %{"samples_needed_per_group" => 60, "allocation_ratio" => 0.5, "baseline_group" => "before"})
    detail = put_in(detail, [:analysis, "metrics", "delivery-speed/start_to_merge", "scale"], "log")
    {:ok, projected} = ChartData.attach({:ok, detail}, [])
    metric = hd(projected.chart_metrics)
    assert Enum.map(metric.groups, & &1.needed) == [60, 30]
    assert metric.scale == "log"
  end

  test "tag-list strata match values across JSON Unicode escaping" do
    detail = fixture()
    [metric | _] = detail.spec["metrics"]
    ref = metric["ref"]
    key = ~S(["\u00e9","a"])
    spec = Map.merge(detail.spec, %{"metrics" => [metric], "stratify_by" => ["tags.team"]})

    snapshots =
      for snapshot <- detail.snapshots do
        evidence = snapshot["metrics"][ref]
        points = Enum.map(evidence["observations"], &put_in(&1, ["attrs", "tags"], %{"team" => ["é", "a"]}))
        Map.put(snapshot, "metrics", %{ref => Map.put(evidence, "observations", points)})
      end

    result = detail.analysis["metrics"][ref] |> Map.delete("strata")
    analysis = Map.put(detail.analysis, "metrics", %{ref => Map.put(result, "strata", %{key => result})})
    {:ok, projected} = ChartData.attach({:ok, %{detail | spec: spec, snapshots: snapshots, analysis: analysis}}, stratum: "tags.team:" <> key)
    assert projected.stratum == "tags.team:" <> key
    assert Enum.map(hd(projected.chart_metrics).groups, &length(&1.points)) == [12, 4]
  end

  test "a zero whisker outside the point cap keeps the scale linear" do
    detail = fixture()
    [metric | _] = detail.spec["metrics"]
    ref = metric["ref"]
    template = hd(get_in(hd(detail.snapshots), ["metrics", ref, "observations"]))
    points = for index <- 1..500, do: %{template | "unit_id" => String.pad_leading(to_string(index), 3, "0"), "value" => index}
    points = points ++ [%{template | "unit_id" => "zzz", "value" => 0}]

    snapshots =
      for snapshot <- detail.snapshots do
        evidence = snapshot["metrics"][ref]
        evidence = if snapshot["window_name"] == "before", do: Map.put(evidence, "observations", points), else: evidence
        Map.put(snapshot, "metrics", %{ref => evidence})
      end

    result = detail.analysis["metrics"][ref] |> Map.delete("strata")
    result = put_in(result, ["groups", "before"], %{"n" => 501, "median" => 250, "q1" => 125, "q3" => 375, "min" => 0, "max" => 500, "iqr" => 250, "p90" => 450, "n_censored" => 0})
    analysis = Map.put(detail.analysis, "metrics", %{ref => result})
    spec = Map.merge(detail.spec, %{"metrics" => [metric], "stratify_by" => []})
    {:ok, projected} = ChartData.attach({:ok, %{detail | spec: spec, snapshots: snapshots, analysis: analysis}}, [])
    metric = hd(projected.chart_metrics)
    assert length(hd(metric.groups).points) == 500
    assert Enum.min(Enum.map(hd(metric.groups).points, & &1["value"])) == 1
    assert hd(metric.groups).whiskers == {0, 500}
    assert metric.scale == "linear"
  end
end
