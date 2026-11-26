defmodule Aiur.Experiments.OptimisticStartFixtureTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.{Experiments, ExperimentsCLI}
  alias Aiur.Experiments.{Catalog, Spec, Store}

  @repo Path.expand("../../../..", __DIR__)
  @fixtures Path.join(@repo, ".aiur/experiments")
  @research Path.join(@repo, "docs/research/experiments/x7")
  @sha "e88e475b38f1abf9ec2f70016453129904b2357f668290b21fd8991da1cde4cb"
  @gap "optimistic-start/blocker_merge_to_dependent_start"

  setup do
    root = Path.join(System.tmp_dir!(), "optimistic-spec-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    unless Process.whereis(Aiur.PubSub), do: start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    start_supervised!({Store, catalog_context: %{repo_path: @repo}})

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    :ok
  end

  test "reviewed cohort fixture resolves every metric and preserves signed-gap protocol" do
    assert {:ok, spec} = Spec.new(fixture("optimistic-start"))
    assert_schema(spec)
    assert :ok = Catalog.validate_refs(spec.metrics, %{repo_path: @repo})
    assert spec.min_samples == 20
    assert Enum.filter(spec.metrics, & &1["primary"]) |> Enum.map(&{&1["ref"], &1["direction"]}) == [{@gap, "decrease"}, {"optimistic-start/dependent_start_to_merge", "increase"}]
    assert spec.stratify_by == ["complexity", "tags.gate_shape"]
    assert spec.filters == %{"attr" => "tags.late_linked", "op" => "eq", "value" => false}
    assert spec.notes =~ "Holm correction across decision and both primary metrics"
    assert spec.notes =~ "0.265 + 0.20"
    assert spec.notes =~ "0.385 + 0.15 over 24 h"
    assert spec.notes =~ "0.20 after >= 10 optimistic starts"
    assert Enum.all?(spec.design["cohorts"], &(hd(&1["where"]["all"])["value"] == []))
    assert {:error, errors} = Spec.new(Map.put(fixture("optimistic-start"), "min_samples", 0))
    assert Enum.any?(errors, &(&1.path == "min_samples"))
  end

  test "CLI stores the original frozen source and displays its actual sample count and rounded hours" do
    cli(:create, ["--spec-json", Jason.encode!(fixture("optimistic-start")), "--no-freeze"])
    bytes = @research |> Path.join("baseline-2026-10-09/baseline.json.gz") |> File.read!() |> :zlib.gunzip()
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @sha
    output = cli(:import_baseline, ["optimistic-start", "--source-base64", Base.encode64(bytes), "--sha256", @sha, "--metric", @gap])
    assert {:ok, detail} = Experiments.fetch("optimistic-start")
    assert [snapshot] = detail.snapshots
    assert %{"n" => 27, "median_h" => 0.775} = snapshot["baseline_import"]["summary"]
    assert snapshot["baseline_import"]["source_sha256"] == @sha
    assert Base.decode64!(snapshot["baseline_import"]["source_bytes_base64"]) == bytes
    assert snapshot["metrics"][@gap]["coverage"]["state"] == "summary_only"
    assert snapshot["metrics"][@gap]["observations"] == []
    assert output =~ "n=27, median=0.78 h"
    assert cli(:show, ["optimistic-start"]) =~ "n=27, median=0.78 h"
  end

  test "context fixture uses the last sub-issue PR merge rather than the later epic close" do
    assert {:ok, context} = Spec.new(fixture("optimistic-start-default-path"))
    assert_schema(context)
    evidence = @research |> Path.join("feature-line.json") |> File.read!() |> Jason.decode!()
    latest = Enum.max_by(evidence["merges"], & &1["mergedAt"])
    assert length(evidence["subissues"]) == 17
    assert context.design["change"]["time"] == latest["mergedAt"]
    assert context.design["change"]["evidence"]["latest_pr"] == latest["url"]
    assert context.windows["before"]["end"] == "2026-10-09T17:55:20Z"
    assert context.windows["after"]["start"] == latest["mergedAt"]
    assert context.status == "draft"
    assert context.filters == %{"attr" => "tags.late_linked", "op" => "eq", "value" => false}
  end

  defp fixture(id), do: @fixtures |> Path.join(id <> ".json") |> File.read!() |> Jason.decode!()

  defp assert_schema(spec) do
    schema = @repo |> Path.join("src/priv/experiments/spec.v1.schema.json") |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    assert :ok = ExJsonSchema.Validator.validate(schema, Spec.to_map(spec))
  end

  defp cli(verb, argv) do
    capture_io(fn -> assert ExperimentsCLI.run(verb: verb, argv: argv) == 0 end)
  end
end
