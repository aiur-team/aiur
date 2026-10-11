defmodule Aiur.Experiments.CatalogTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{Catalog, Metric, MetricPack}

  defmodule FixturePack do
    @behaviour MetricPack
    def id, do: "fixture"
    def version, do: "1"
    def metrics, do: [%Metric{id: "latency", pack: id(), label: "Latency", unit: "ms", unit_of_analysis: "deploy", kind: "duration", better: "lower", default_direction: "decrease"}]
    def observations(_ids, _window, _ctx), do: %{}
  end

  test "consumer definitions are loaded from the supplied base checkout" do
    root = Path.expand("../../fixtures/experiments/consumer_repo", __DIR__)
    catalog = Catalog.load(%{repo_path: root, builtin_packs: []})
    assert catalog.problems == []
    assert catalog.metrics["app/deploy_latency"].source["kind"] == "event_interval"
    assert catalog.metrics["app/request_latency"].source["kind"] == "script"
  end

  test "built-ins have qualified refs, unknown refs suggest nearby ids, and disabled packs disappear" do
    ctx = %{repo_path: System.tmp_dir!(), pack_dirs: [], builtin_packs: [FixturePack]}
    assert Catalog.load(ctx).metrics["fixture/latency"].label == "Latency"
    assert :ok = Catalog.validate_refs([%{"ref" => "fixture/latency"}], ctx)
    assert {:error, [error]} = Catalog.validate_refs([%{"ref" => "fixture/latenc"}], ctx)
    assert error.path == "metrics.0.ref"
    assert error.message =~ "fixture/latency"
    assert Catalog.load(Map.put(ctx, :disabled_packs, ["fixture"])).metrics == %{}
  end
end
