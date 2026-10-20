defmodule Aiur.Experiments.StrataMetadataTest do
  use ExUnit.Case, async: false

  alias Aiur.Experiments.{AnalysisInput, Catalog, Evidence, Paths, Persistence, Reader}
  alias Aiur.Experiments.Packs.Loader

  @ref "app/latency"
  @metadata %{"backend" => %{"post_treatment" => true}, "complexity" => %{"post_treatment" => false}}

  setup do
    root = Path.join(System.tmp_dir!(), "strata-metadata-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "packs"))
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, Path.join(root, "state"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  defp pack do
    %{
      "schema_version" => 1,
      "id" => "app",
      "version" => "1",
      "metrics" => [
        %{
          "id" => "latency",
          "label" => "Latency",
          "unit" => "ms",
          "unit_of_analysis" => "deploy",
          "kind" => "duration",
          "better" => "lower",
          "default_direction" => "decrease",
          "group" => "app",
          "requires" => [],
          "source" => %{"kind" => "event_interval", "start" => "app.start", "end" => "app.end", "unit_key" => "/id"},
          "strata_metadata" => @metadata
        }
      ]
    }
  end

  # The full pack schema contains a pre-existing path regex unsupported by ExJsonSchema.
  # Resolve the published metadata subschema directly; exported input uses its full schema.
  defp schema("pack") do
    Path.expand("../../../priv/experiments/pack.v1.schema.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["properties", "metrics", "items", "properties", "strata_metadata"])
    |> ExJsonSchema.Schema.resolve()
  end

  defp schema(name) do
    Path.expand("../../../priv/experiments/#{name}.v1.schema.json", __DIR__) |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
  end

  test "consumer pack metadata reaches exported analysis input without modifying spec", %{root: root} do
    File.write!(Path.join(root, "packs/app.json"), Jason.encode!(pack()))
    ctx = %{repo_path: root, pack_dirs: ["packs"], builtin_packs: [], disabled_packs: [], clock: ~U[2026-10-09 14:00:00Z]}
    catalog = Catalog.load(ctx)
    assert catalog.problems == []
    assert catalog.metrics[@ref].strata_metadata == @metadata
    assert ExJsonSchema.Validator.validate(schema("pack"), @metadata) == :ok

    original = Path.join(__DIR__, "fixtures/valid_ab.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("spec")
    spec = put_in(original, ["metrics", Access.at(0), "ref"], @ref)
    File.mkdir_p!(Paths.file(spec["id"], "report"))
    :ok = Persistence.write_json(Paths.file(spec["id"], "spec.json"), spec)
    assert {:ok, expected_spec, false} = Reader.spec(spec["id"])

    ctx =
      Map.put(ctx, :evaluate, fn refs, _window, _ctx ->
        rows = [%{"unit_id" => "one", "value" => 3, "at" => "2026-10-09T01:00:00Z", "attrs" => %{"backend" => "claude", "complexity" => 2}}]
        Map.new(refs, &{&1, %{"coverage" => %{"state" => "captured"}, "observations" => rows}})
      end)

    assert {:ok, input} = AnalysisInput.export(spec["id"], context: ctx)
    assert input["metric_metadata"] == %{@ref => %{"strata_metadata" => @metadata}}
    assert input["taken_at"] == "2026-10-09T14:00:00Z"
    assert input["spec"] == expected_spec
    refute Map.has_key?(hd(input["spec"]["metrics"]), "strata_metadata")
    assert input["input_sha256"] == Evidence.hash(Map.delete(input, "input_sha256"))
    assert ExJsonSchema.Validator.validate(schema("analysis-input"), input) == :ok
    assert Jason.decode!(File.read!(Paths.file(spec["id"], "report/analysis-input.json"))) == input
  end

  test "absent metadata keeps the legacy export and changing metadata changes its hash" do
    spec = %{"metrics" => [%{"ref" => @ref}], "stratify_by" => [], "registered_at" => nil}
    arms = %{"arms" => %{}}
    legacy = AnalysisInput.build(spec, [], arms)
    refute Map.has_key?(legacy, "metric_metadata")
    assert AnalysisInput.build(spec, [], arms, %{@ref => %{strata_metadata: %{}}}) == legacy
    annotated = AnalysisInput.build(spec, [], arms, %{@ref => %{strata_metadata: @metadata}})
    assert annotated["metric_metadata"] == %{@ref => %{"strata_metadata" => @metadata}}
    refute annotated["input_sha256"] == legacy["input_sha256"]
  end

  test "runtime loader and published schema reject malformed post-treatment declarations" do
    for metadata <- [nil, [], %{"" => %{"post_treatment" => true}}, %{"model" => %{}}, %{"model" => %{"post_treatment" => "true"}}, %{"model" => %{"post_treatment" => true, "extra" => false}}] do
      malformed = put_in(pack(), ["metrics", Access.at(0), "strata_metadata"], metadata)
      assert {:error, errors} = Loader.validate(malformed)
      assert Enum.any?(errors, &String.ends_with?(&1.path, "strata_metadata"))
      refute ExJsonSchema.Validator.validate(schema("pack"), metadata) == :ok
    end
  end
end
