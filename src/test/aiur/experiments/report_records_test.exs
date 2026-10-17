defmodule Aiur.Experiments.ReportRecordsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.{Experiments, ExperimentsCLI}
  alias Aiur.Experiments.{Paths, ReportRecords, Snapshot, Store}
  @fixture Path.expand("../../fixtures/experiments/preregistration.valid.json", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "report-records-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :experiments_dir)
    previous_base = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :experiments_dir, root)
    Application.put_env(:aiur, :repo_base_root, Path.join(root, "repo"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      if previous_base, do: Application.put_env(:aiur, :repo_base_root, previous_base), else: Application.delete_env(:aiur, :repo_base_root)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    :ok = Aiur.TestSupport.ensure_pubsub_running()
    start_supervised!(Store)
    attrs = %{title: "Report example", design: %{kind: "before_after", change: %{type: "manual", ref: "test", time: "2026-10-09T00:00:00Z"}}, metrics: [%{ref: "delivery-speed/start_to_merge"}]}
    assert {:ok, spec} = Experiments.create(attrs, freeze: false)
    registration = @fixture |> File.read!() |> Jason.decode!() |> Map.put("experiment_id", spec.id)
    %{id: spec.id, registration: registration}
  end

  test "facade persists server-owned read timestamp and amendments across writer restart", %{id: id, registration: registration} do
    assert :ok = Experiments.record_results_read(id)
    assert {:ok, first} = ReportRecords.read(id)
    assert {:ok, _, _} = DateTime.from_iso8601(first["first_results_read_at"])
    assert :ok = Experiments.record_results_read(id)
    assert {:ok, ^first} = ReportRecords.read(id)
    assert {:ok, stored} = Experiments.put_preregistration(id, registration)
    assert stored["post_hoc"] == true
    assert {:error, [%{path: "reason"}]} = Experiments.put_preregistration(id, registration)
    assert {:ok, amended} = Experiments.put_preregistration(id, Map.put(registration, "reason", "Fix typo"))
    assert length(amended["amendments"]) == 1
    stop_supervised!(Store)
    start_supervised!(Store)
    assert {:ok, records} = ReportRecords.read(id)
    assert records["preregistration"] == amended
    assert records["first_results_read_at"] == first["first_results_read_at"]
    assert File.exists?(Paths.file(id, "report/contract.json"))
  end

  for surface <- [:arms, :fetch, :export_analysis_input, :freeze] do
    @surface surface
    test "#{surface} records the first post-period read while baseline access stays blind", %{id: id, registration: registration} do
      windows = %{before: %{start: "2026-10-08T00:00:00Z", end: "2026-10-09T00:00:00Z"}, after: %{start: "2026-10-09T00:00:00Z", end: "2026-10-10T00:00:00Z"}}
      assert {:ok, _spec} = Experiments.amend(id, %{windows: windows}, "test")

      ctx = %{
        clock: ~U[2026-10-11 00:00:00Z],
        evaluate: fn refs, window, _ctx ->
          row = %{"unit_id" => window["start"], "at" => window["start"], "value" => 5, "started_at" => window["start"], "finished_at" => window["start"], "censored" => false, "attrs" => %{}}
          Map.new(refs, &{&1, %{"coverage" => %{"state" => "captured"}, "observations" => [row]}})
        end
      }

      assert {:ok, baseline} = Experiments.freeze(id, "before", context: ctx)
      assert baseline["observation_count"] == 1
      assert {:ok, detail} = Experiments.fetch(id)
      assert detail.report_records["first_results_read_at"] == nil
      # Prepare server-owned evidence without exposing post-period values to a consumer.
      assert {:ok, _snapshot} = Snapshot.freeze(id, "after", context: ctx)

      response =
        case @surface do
          :arms -> Experiments.arms(id, context: ctx)
          :freeze -> Experiments.freeze(id, "after", context: ctx, reason: "Read complete window")
          surface -> apply(Experiments, surface, [id])
        end

      assert {:ok, _data} = response
      assert {:ok, records} = ReportRecords.read(id)
      assert {:ok, _, _} = DateTime.from_iso8601(records["first_results_read_at"])
      assert {:ok, registration} = Experiments.put_preregistration(id, registration)
      assert registration["post_hoc"] == true
    end
  end

  test "future spec versions refuse report mutations with typed errors", %{id: id, registration: registration} do
    path = Paths.file(id, "spec.json")
    bytes = path |> File.read!() |> Jason.decode!() |> Map.put("schema_version", 2) |> Jason.encode!()
    File.write!(path, bytes)
    assert {:error, :store_read_only} = Experiments.put_preregistration(id, registration)
    assert {:error, :store_read_only} = Experiments.stats(id)
    assert File.read!(path) == bytes
  end

  test "CLI validates imported registrations and prints actionable errors", %{id: id, registration: registration} do
    assert capture_io(fn -> assert ExperimentsCLI.run(verb: :preregister, argv: [id, "--contract-json", Jason.encode!(registration)]) == 0 end) == "pre-registration stored\n"
    error = capture_io(:stderr, fn -> assert ExperimentsCLI.run(verb: :preregister, argv: [id, "--contract-json", Jason.encode!(registration)]) == 1 end)
    assert error =~ "reason: an amendment requires a reason"
    assert capture_io(:stderr, fn -> assert ExperimentsCLI.run(verb: :preregister, argv: [id, "--contract-json", "{"]) == 1 end) =~ "expected a JSON object"
  end
end
