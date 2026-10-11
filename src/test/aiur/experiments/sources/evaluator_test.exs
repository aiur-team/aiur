defmodule Aiur.Experiments.Sources.EvaluatorTest do
  use ExUnit.Case, async: true
  alias Aiur.Events.Exchange
  alias Aiur.Experiments.{Capture, Catalog, Evaluator, Metric, Observation}

  defmodule FixturePack do
    @behaviour Aiur.Experiments.MetricPack
    @impl true
    def id, do: "fixture"
    @impl true
    def version, do: "1"
    @impl true
    def metrics, do: [%Metric{id: "sample", pack: id()}, %Metric{id: "broken", pack: id()}]
    @impl true
    def observations(ids, window, _ctx) do
      if "broken" in ids, do: exit(:source_gone)
      Map.new(ids, &{&1, {%{state: :captured}, [%Observation{unit_id: "unit-1", value: 17, at: window.start}]}})
    end
  end

  @fixture Path.expand("../../../fixtures/experiments/consumer_repo", __DIR__)
  @window %{start: ~U[2026-01-01 10:00:00Z], end: ~U[2026-01-01 13:00:00Z]}

  setup do
    capture = Path.join(System.tmp_dir!(), "metric-evaluator-#{System.unique_integer([:positive])}")
    File.mkdir_p!(capture)
    on_exit(fn -> File.rm_rf!(capture) end)
    %{capture: capture}
  end

  test "consumer repository pack produces interval and script samples without built-in changes", %{capture: capture} do
    ref = "app/deploy_latency"
    ctx = %{repo_path: @fixture, capture_root: capture, builtin_packs: []}
    exchange = start_supervised!({Exchange, []})
    subscriber = start_supervised!({Capture, name: nil, context: ctx, root: capture, exchange: exchange, clock: fn -> @window.start end})

    assert Exchange.publish(
             "executor.app.deploy.started",
             %{id: 1, topic: "executor.app.deploy.started", deployment_id: "deployment-1", branch: "main", at: "2026-01-01T10:00:00Z", body: "private"},
             exchange
           ) == 1

    assert Exchange.publish("executor.app.deploy.finished", %{id: 2, topic: "executor.app.deploy.finished", deployment_id: "deployment-1", branch: "main", at: "2026-01-01T10:05:00Z"}, exchange) == 1
    assert Capture.status(subscriber).dropped == 0
    refute File.read!(Path.join(capture, "events-2026-01.ndjson")) =~ "private"
    catalog = Catalog.load(ctx)
    assert catalog.problems == []
    assert Map.keys(catalog.metrics) |> Enum.sort() == ["app/deploy_latency", "app/request_latency"]
    results = Evaluator.observations(Map.keys(catalog.metrics), @window, ctx)
    assert %{coverage: %{state: :captured}, observations: [%{value: 300_000, unit_id: "deployment-1", attrs: %{"branch" => "main"}}]} = results[ref]
    assert %{coverage: %{state: :captured}, observations: [%{value: 42}, %{value: 57}]} = results["app/request_latency"]
  end

  test "missing packs are unavailable, and capture corruption never becomes an empty success", %{capture: capture} do
    ctx = %{repo_path: @fixture, capture_root: capture, builtin_packs: []}
    assert %{"gone/value" => %{coverage: %{state: :unavailable, reason: :metric_missing}, observations: []}} = Evaluator.observations(["gone/value"], @window, ctx)
    File.write!(Path.join(capture, "coverage.json"), Jason.encode!(%{"app/deploy_latency" => "invalid-date"}))
    assert %{coverage: %{state: :not_captured}} = Evaluator.observations(["app/deploy_latency"], @window, ctx)["app/deploy_latency"]
    File.write!(Path.join(capture, "coverage.json"), Jason.encode!(%{"app/deploy_latency" => DateTime.to_iso8601(@window.start)}))

    for body <- ["broken-json\n", Jason.encode!(%{metric_ref: "app/deploy_latency", topic: "executor.app.deploy.started", at: "2026-01-01T10:00:00Z", unit: 42, attrs: %{}})] do
      File.write!(Path.join(capture, "events-2026-01.ndjson"), body)
      assert %{coverage: %{state: :unavailable, reason: :capture_corrupt}, observations: []} = Evaluator.observations(["app/deploy_latency"], @window, ctx)["app/deploy_latency"]
    end
  end

  test "spec ISO windows and open windows normalize, invalid windows are unavailable", %{capture: capture} do
    ctx = %{repo_path: @fixture, capture_root: capture, builtin_packs: [], clock: fn -> @window.end end}
    results = Evaluator.observations(["app/request_latency"], %{"start" => "2026-01-01T10:00:00Z", "end" => nil}, ctx)
    assert %{coverage: %{state: :captured}, observations: [%{value: 42}, %{value: 57}]} = results["app/request_latency"]

    for window <- [%{start: @window.end, end: @window.start}, %{"start" => "invalid", "end" => nil}] do
      assert %{coverage: %{state: :unavailable, reason: :invalid_window}} = Evaluator.observations(["app/request_latency"], window, ctx)["app/request_latency"]
    end
  end

  test "default daemon context cannot infer capture continues when the subscriber is absent" do
    catalog = Catalog.load(%{repo_path: @fixture, builtin_packs: []})
    ctx = %{catalog: catalog, capture_server: nil}
    assert %{coverage: %{state: :unavailable, reason: :capture_inactive}, observations: []} = Evaluator.observations(["app/deploy_latency"], @window, ctx)["app/deploy_latency"]
  end

  test "built-in packs delegate ids and qualify returned results; failed sources are unavailable" do
    ctx = %{repo_path: @fixture, builtin_packs: [FixturePack]}
    results = Evaluator.observations(["fixture/sample", "fixture/missing"], @window, ctx)
    assert %{coverage: %{state: :captured}, observations: [%{unit_id: "unit-1", value: 17}]} = results["fixture/sample"]
    assert %{coverage: %{state: :unavailable, reason: :metric_missing}} = results["fixture/missing"]
    assert %{coverage: %{state: :unavailable, reason: {:pack_failed, :source_gone}}, observations: []} = Evaluator.observations(["fixture/broken"], @window, ctx)["fixture/broken"]
  end

  test "capture append failure persists unavailable coverage", %{capture: capture} do
    File.write!(Path.join(capture, "errors.json"), Jason.encode!(%{"app/deploy_latency" => "enospc"}))
    ctx = %{repo_path: @fixture, capture_root: capture, builtin_packs: []}
    assert %{coverage: %{state: :unavailable, reason: "enospc"}, observations: []} = Evaluator.observations(["app/deploy_latency"], @window, ctx)["app/deploy_latency"]
  end
end
