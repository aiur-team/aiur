defmodule Aiur.Experiments.ChartCacheTest do
  use ExUnit.Case, async: false
  alias Aiur.Experiments
  alias Aiur.Experiments.{Catalog, Evidence, Paths, ReportEngine, ReportInput, Snapshot, Store, WindowEvents}

  setup do
    root = Path.join(System.tmp_dir!(), "chart-cache-#{System.unique_integer([:positive])}")
    keys = [:experiments_dir, :repo_base_root, :experiment_metric_packs]
    previous = Map.new(keys, &{&1, Application.get_env(:aiur, &1)})
    Application.put_env(:aiur, :experiments_dir, root)
    Application.put_env(:aiur, :repo_base_root, Path.join(root, "repo-state"))
    Application.put_env(:aiur, :experiment_metric_packs, [Aiur.Experiments.Packs.DeliverySpeed])

    on_exit(fn ->
      for {key, value} <- previous, do: if(is_nil(value), do: Application.delete_env(:aiur, key), else: Application.put_env(:aiur, key, value))
      Aiur.TestCleanup.rm_rf!(root)
    end)

    :ok = Aiur.TestSupport.ensure_pubsub_running()
    start_supervised!(Store)
    raw = File.read!(Path.expand("fixtures/chart_detail.json", __DIR__)) |> Jason.decode!()
    spec = raw["spec"]
    id = spec["id"]
    File.mkdir_p!(Paths.file(id, "snapshots"))
    File.mkdir_p!(Paths.file(id, "report"))
    File.write!(Paths.file(id, "spec.json"), Jason.encode!(spec))
    File.write!(Paths.file(id, "annotations.ndjson"), "")
    entries = for snapshot <- raw["snapshots"], do: write_snapshot(id, snapshot)
    File.write!(Paths.file(id, "journal.ndjson"), Enum.join(entries, "\n") <> "\n")

    registration = %{
      "primary_metrics" => [%{"id" => hd(spec["metrics"])["ref"], "expected" => "decrease"}],
      "secondary_metrics" => [],
      "guardrail_metrics" => [],
      "mde" => %{"metric" => hd(spec["metrics"])["ref"], "relative" => -0.15},
      "alpha" => 0.05,
      "fdr_q" => 0.05,
      "power_target" => 0.8
    }

    File.write!(Paths.file(id, "report/contract.json"), Jason.encode!(%{"preregistration" => registration}))
    {:ok, input} = ReportInput.prepare(id)
    engine_spec = ReportEngine.spec(input.input, registration, Catalog.load())
    directory = Paths.file(id, "report/stats/" <> Evidence.hash(%{input: input.input, spec: engine_spec}))
    File.mkdir_p!(directory)
    body = Map.put(raw["analysis"], "experiment_id", id)
    File.write!(Path.join(directory, "result.json"), Jason.encode!(%{"body" => body}))
    %{id: id, body: body, directory: directory, raw: raw}
  end

  test "real facade reads the report engine cache without a legacy root result or rerunning stats", %{id: id, body: body} do
    refute File.exists?(Paths.file(id, "result.json"))
    {:ok, legacy} = Experiments.fetch(id)
    assert legacy.analysis == nil
    {:ok, detail} = Experiments.chart_detail(id)
    assert detail.analysis == body
    assert Enum.map(hd(detail.chart_metrics).groups, & &1.n) == [12, 4]
    assert Enum.map(hd(detail.chart_metrics).groups, &length(&1.points)) == [12, 4]
  end

  test "new baseline revision cannot reuse the old report result", %{id: id, raw: raw, body: body} do
    assert {:ok, %{analysis: ^body}} = Experiments.chart_detail(id)
    snapshot = hd(raw["snapshots"]) |> Map.put("revision", 2)
    entry = write_snapshot(id, snapshot)
    File.write!(Paths.file(id, "journal.ndjson"), entry <> "\n", [:append])
    {:ok, detail} = Experiments.chart_detail(id)
    assert detail.analysis == nil
    assert hd(detail.chart_metrics).effect == %{estimate: nil, lo: nil, hi: nil}
  end

  test "cached confounder snapshots supply ticks through the real facade", %{id: id, raw: raw} do
    {:ok, now, _} = DateTime.from_iso8601(hd(raw["snapshots"])["computed_at"])
    at = raw["spec"]["windows"]["after"]["start"]
    pulls = [%{"number" => 123, "mergedAt" => at, "title" => "Overlapping release"}]
    events = WindowEvents.collect(raw["spec"], now: now, alert_files: [], records_fun: fn _ -> {[], []} end, github_fun: fn _, _, _, _ -> {%{"pulls" => pulls}, []} end)
    events = Map.put(events, "snapshot", "events-1.ndjson")
    bytes = Enum.map_join([Map.delete(events, "events") | events["events"]], &(Evidence.encode(&1) <> "\n"))
    File.write!(Paths.file(id, "events-1.ndjson"), bytes)
    {:ok, detail} = Experiments.chart_detail(id)
    assert Enum.any?(detail.annotations, &(&1["at"] == at))
  end

  defp write_snapshot(id, snapshot) do
    metrics = Map.new(snapshot["metrics"], fn {ref, evidence} -> {ref, Map.put(evidence, "summary", Snapshot.summary(evidence["observations"]))} end)
    snapshot = Map.put(snapshot, "metrics", metrics)
    snapshot = Map.put(snapshot, "sha256", Evidence.hash(snapshot))
    File.write!(Paths.file(id, "snapshots/#{snapshot["window_name"]}.r#{snapshot["revision"]}.json"), Jason.encode!(snapshot))
    Jason.encode!(%{"schema_version" => 1, "kind" => "frozen", "window" => snapshot["window_name"], "revision" => snapshot["revision"], "sha256" => snapshot["sha256"]})
  end
end
