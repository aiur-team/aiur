defmodule AiurWeb.Experiments.UnknownEvidenceTest do
  use ExUnit.Case, async: true

  alias Aiur.Experiments.ChartData
  alias AiurWeb.Experiments.{Charts, ViewModel}

  defp fixture do
    raw = File.read!(Path.expand("../../aiur/experiments/fixtures/chart_detail.json", __DIR__)) |> Jason.decode!()
    spec = Map.put(raw["spec"], "metrics", Enum.take(raw["spec"]["metrics"], 1))
    refs = Enum.map(spec["metrics"], & &1["ref"])
    snapshots = Enum.map(raw["snapshots"], &Map.update!(&1, "metrics", fn metrics -> Map.take(metrics, refs) end))
    %{spec: spec, analysis: raw["analysis"], snapshots: snapshots, annotations: raw["annotations"], phase: :collecting}
  end

  defp project(detail) do
    {:ok, detail} = ChartData.attach({:ok, detail}, [])
    model = ViewModel.detail(detail)
    {model, hd(model.chart_metrics)}
  end

  defp html(chart), do: chart |> Phoenix.HTML.safe_to_string() |> Floki.parse_fragment!()
  defp cells(row), do: Floki.find(row, "td") |> Enum.map(&Floki.text/1)

  defp captured(detail, state, empty? \\ false) do
    snapshots =
      for snapshot <- detail.snapshots do
        metrics =
          Map.new(snapshot["metrics"], fn {ref, evidence} ->
            evidence = Map.put(evidence, "coverage", %{"state" => state})
            {ref, if(empty?, do: Map.put(evidence, "observations", []), else: evidence)}
          end)

        Map.put(snapshot, "metrics", metrics)
      end

    %{detail | snapshots: snapshots}
  end

  test "absent frozen evidence keeps counts unknown in the facade, SVG and both tables" do
    raw = fixture()
    {detail, metric} = project(%{raw | snapshots: [], analysis: nil})
    assert Enum.map(metric.groups, & &1.n) == [nil, nil]
    assert metric.guarded?
    power = html(Charts.power([metric], detail))
    labels = Floki.attribute(Floki.find(power, "svg"), "aria-label")
    assert length(labels) == 2
    assert Enum.all?(labels, &String.contains?(&1, "sample count unavailable"))
    assert Floki.find(power, ".exp-meter-fill") == []
    assert Enum.map(Floki.find(power, "tbody tr"), &Enum.at(cells(&1), 2)) == ["Unavailable", "Unavailable"]
    assert Enum.all?(Floki.find(power, "tbody tr"), &(List.last(cells(&1)) == "sample count unavailable"))
    refute Floki.text(power) =~ "needs 10 more"
    distribution = html(Charts.distribution(metric))
    assert Floki.text(Floki.find(distribution, "svg")) =~ "sample count unavailable"
    [summary, _samples] = Floki.find(distribution, "table")
    assert Enum.map(Floki.find(summary, "tbody tr"), &Enum.at(cells(&1), 1)) == ["Unavailable", "Unavailable"]

    {_detail, stored} = project(%{raw | snapshots: []})
    assert Enum.map(stored.groups, & &1.n) == [12, 4]
  end

  test "uncaptured or missing metric coverage cannot become a known empty sample" do
    raw = fixture()
    unavailable = captured(%{raw | analysis: nil}, "unavailable", true)
    missing = %{raw | analysis: nil, snapshots: Enum.map(raw.snapshots, &Map.put(&1, "metrics", %{}))}

    for evidence <- [unavailable, missing] do
      {_detail, metric} = project(evidence)
      assert Enum.map(metric.groups, & &1.n) == [nil, nil]
      assert metric.guarded?
    end
  end

  test "future guard: captured empty evidence remains a known zero" do
    raw = fixture()

    for state <- ["captured", "partial"] do
      {detail, metric} = project(captured(%{raw | analysis: nil}, state, true))
      assert Enum.map(metric.groups, & &1.n) == [0, 0]
      power = html(Charts.power([metric], detail))
      assert Enum.map(Floki.find(power, "tbody tr"), &Enum.at(cells(&1), 2)) == ["0", "0"]
      assert Floki.text(power) =~ "needs 10 more before the line"
      assert Floki.text(power) =~ "needs 10 more after the line"
      refute Floki.text(power) =~ "in cohort Before"
    end
  end

  test "metric minimum applies without stored inference when the global guard is already met" do
    raw = fixture()
    [spec] = raw.spec["metrics"]
    raw = %{raw | analysis: nil, spec: raw.spec |> Map.put("min_samples", 2) |> Map.put("metrics", [Map.put(spec, "min_samples", 20)])}
    {detail, metric} = project(captured(raw, "captured"))
    assert Enum.map(metric.groups, & &1.n) == [12, 4]
    assert metric.minimum == 20
    assert metric.guarded?
    power = html(Charts.power([metric], detail))
    assert Enum.map(Floki.find(power, "tbody tr"), &Enum.at(cells(&1), 3)) == ["20", "20"]
    assert Floki.text(power) =~ "needs 8 more before the line"
    assert Floki.text(power) =~ "needs 16 more after the line"
    refute Floki.text(power) =~ "Sample minimum reached"
  end

  test "stored insufficient status hides an available interval even when all counts meet the minimum" do
    raw = fixture()
    raw = put_in(raw, [:spec, "min_samples"], 2)
    raw = put_in(raw, [:analysis, "defaults", "min_samples"], 2)
    ref = hd(raw.spec["metrics"])["ref"]
    raw = put_in(raw, [:analysis, "metrics", ref, "status"], "insufficient_data")
    raw = put_in(raw, [:analysis, "metrics", ref, "effects"], %{"median_ratio" => %{"estimate" => 0.7, "lo" => 0.5, "hi" => 0.9}})
    {_detail, metric} = project(raw)
    assert Enum.all?(metric.groups, &(&1.n >= metric.minimum))
    assert_in_delta metric.effect.estimate, -30, 0.00001
    assert metric.guarded?
    forest = html(Charts.forest([metric]))
    assert length(Floki.find(forest, ".exp-hollow")) == 1
    assert Floki.find(forest, ".exp-ci") == []
  end
end
