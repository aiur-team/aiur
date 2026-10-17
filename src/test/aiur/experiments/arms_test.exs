defmodule Aiur.Experiments.ArmsTest do
  use ExUnit.Case, async: false
  alias Aiur.Experiments.{AnalysisInput, Arms, Paths, Persistence, Snapshot}

  @ref "delivery-speed/start_to_merge"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    :ok = Aiur.TestSupport.ensure_pubsub_running()
    root = Path.join(System.tmp_dir!(), "experiment-arms-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  defp spec do
    Path.join(__DIR__, "fixtures/valid_line.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("spec")
  end

  defp row(id, start, finish, attrs \\ %{}) do
    %{"unit_id" => id, "value" => 17, "at" => start, "started_at" => start, "finished_at" => finish, "censored" => false, "attrs" => attrs}
  end

  defp window(rows, source \\ :live), do: %{source: source, metrics: %{@ref => %{"coverage" => %{"state" => "captured"}, "observations" => rows}}}

  defp change_spec do
    spec()
    |> put_in(["design", "change", "time"], "2026-10-09T12:00:00Z")
    |> put_in(["windows", "after", "start"], "2026-10-09T12:00:00Z")
  end

  test "start assignment excludes straddlers and retains small arms with evidence sources" do
    before = row("before", "2026-10-09T10:00:00Z", "2026-10-09T11:00:00Z")
    straddle = row("straddle", "2026-10-09T11:30:00Z", "2026-10-09T12:30:00Z")
    after_row = row("after", "2026-10-09T12:10:00Z", "2026-10-09T13:00:00Z")
    result = Arms.assign(change_spec(), [{"before", window([straddle, before], :frozen)}, {"after", window([after_row])}])
    assert result["excluded"] == %{"straddle" => 1, "ambiguous" => 0, "filtered" => 0}
    assert result["arms"]["before"]["source"] == "frozen"
    assert result["arms"]["after"]["source"] == "live"
    assert result["arms"]["before"]["metrics"][@ref]["observations"] == [before]
    assert result["arms"]["after"]["metrics"][@ref]["observations"] == [after_row]
    assert result["arms"]["before"]["metrics"][@ref]["n"] == 1
    assert change_spec()["min_samples"] == 15
  end

  test "finish assignment moves a straddling unit after the change" do
    straddle = row("straddle", "2026-10-09T11:30:00Z", "2026-10-09T12:30:00Z")
    result = Arms.assign(put_in(change_spec(), ["design", "assign_by"], "finish"), [{"before", window([straddle], :frozen)}, {"after", window([])}])
    assert result["arms"]["before"]["metrics"][@ref]["n"] == 0
    assert result["arms"]["after"]["metrics"][@ref]["observations"] == [straddle]
    assert result["excluded"]["straddle"] == 0
  end

  test "cohort predicates count ambiguous and filtered units, applying filters first" do
    ab = Path.join(__DIR__, "fixtures/valid_ab.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("spec")
    ab = put_in(ab, ["filters"], %{"attr" => "complexity", "op" => "eq", "value" => 3})
    codex = row("codex", "2026-10-09T13:00:00Z", nil, %{"backend" => "codex", "tags" => %{"team" => "one"}, "complexity" => 3})
    unknown = row("unknown", "2026-10-09T13:00:00Z", nil, %{"backend" => "muse", "complexity" => 3})
    ambiguous = row("ambiguous", "2026-10-09T13:00:00Z", nil, %{"backend" => "claude", "tags" => %{"team" => "one"}, "complexity" => 3})
    excluded_first = put_in(ambiguous, ["attrs", "complexity"], 1) |> Map.put("unit_id", "filtered-first")
    result = Arms.assign(ab, [{"observation", window([codex, unknown, ambiguous, excluded_first])}])
    assert result["arms"]["test"]["metrics"][@ref]["observations"] == [codex]
    assert result["arms"]["control"]["metrics"][@ref]["n"] == 0
    assert result["excluded"] == %{"straddle" => 0, "ambiguous" => 1, "filtered" => 2}
  end

  test "after window start excludes washout observations and boundary finish belongs before" do
    before = row("boundary", "2026-10-09T10:00:00Z", "2026-10-09T12:00:00Z")
    washout = row("washout", "2026-10-09T12:10:00Z", nil)
    after_row = row("after", "2026-10-09T13:00:00Z", nil)
    spec = put_in(change_spec(), ["windows", "after", "start"], "2026-10-09T13:00:00Z")
    result = Arms.assign(spec, [{"before", window([before])}, {"after", window([washout, after_row])}])
    assert result["arms"]["before"]["metrics"][@ref]["observations"] == [before]
    assert result["arms"]["after"]["metrics"][@ref]["observations"] == [after_row]
    assert result["excluded"]["straddle"] == 1
  end

  test "unfinished prechange duration retains its censored value" do
    censored = row("open", "2026-10-09T10:00:00Z", nil) |> Map.put("censored", true)
    result = Arms.assign(change_spec(), [{"before", window([censored], :frozen)}, {"after", window([])}])
    assert result["arms"]["before"]["metrics"][@ref]["observations"] == [censored]
    assert result["excluded"]["straddle"] == 0
  end

  test "frozen arms and export survive telemetry deletion and refuse tampering", %{root: root} do
    spec = change_spec()
    id = spec["id"]
    File.mkdir_p!(Paths.file(id, "report"))
    :ok = Persistence.write_json(Paths.file(id, "spec.json"), spec)
    telemetry = Path.join(root, "telemetry.json")
    before = row("before", "2026-10-09T10:00:00Z", "2026-10-09T11:00:00Z", %{"complexity" => 3})
    after_row = row("after", "2026-10-09T12:10:00Z", "2026-10-09T13:00:00Z", %{"complexity" => 1})
    File.write!(telemetry, Jason.encode!([before, after_row]))

    ctx = %{
      clock: ~U[2026-10-09 14:00:00Z],
      catalog: %{packs: %{}},
      evaluate: fn refs, window, _ctx ->
        rows = File.read!(telemetry) |> Jason.decode!() |> Enum.filter(fn row -> row["at"] >= window["start"] and row["at"] < window["end"] end)
        Map.new(refs, &{&1, %{"coverage" => %{"state" => "captured"}, "observations" => rows}})
      end
    }

    assert {:ok, _snapshot} = Snapshot.freeze(id, "before", context: ctx)
    assert {:ok, _snapshot} = Snapshot.freeze(id, "after", context: ctx)
    assert {:ok, before_delete} = Arms.read(id, context: ctx)
    assert {:ok, exported} = AnalysisInput.export(id, context: ctx)
    assert Jason.decode!(File.read!(Paths.file(id, "report/analysis-input.json"))) == exported
    File.rm!(telemetry)
    assert Arms.read(id, context: ctx) == {:ok, before_delete}
    assert AnalysisInput.export(id, context: ctx) == {:ok, exported}
    path = Paths.file(id, "snapshots/before.r1.json")
    File.chmod!(path, 0o600)
    File.write!(path, String.replace(File.read!(path), "before", "beforz", global: false))
    assert Arms.read(id, context: ctx) == {:error, :tampered}
    assert AnalysisInput.export(id, context: ctx) == {:error, :tampered}
    assert Jason.decode!(File.read!(Paths.file(id, "report/analysis-input.json"))) == exported
  end

  test "excluded units are counted once across metric observations" do
    straddle = row("straddle", "2026-10-09T11:30:00Z", "2026-10-09T12:30:00Z")
    spec = Map.update!(change_spec(), "metrics", &(&1 ++ [%{"ref" => "fixture/other"}]))
    data = window([straddle])
    data = put_in(data, [:metrics, "fixture/other"], data.metrics[@ref])
    result = Arms.assign(spec, [{"before", data}, {"after", window([])}])
    assert result["excluded"]["straddle"] == 1
    assert result["arms"]["before"]["metrics"]["fixture/other"]["n"] == 0
  end

  test "finish assignment deduplicates units across windows, preserving frozen evidence" do
    frozen = row("same", "2026-10-09T11:30:00Z", "2026-10-09T12:30:00Z")
    live = Map.put(frozen, "value", 99)
    spec = put_in(change_spec(), ["design", "assign_by"], "finish")
    result = Arms.assign(spec, [{"after", window([live])}, {"before", window([frozen], :frozen)}])
    assert result["arms"]["after"]["metrics"][@ref]["n"] == 1
    assert result["arms"]["after"]["metrics"][@ref]["observations"] == [frozen]
  end
end
