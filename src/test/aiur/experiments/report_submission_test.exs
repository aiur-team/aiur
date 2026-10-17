defmodule Aiur.Experiments.ReportSubmissionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.{Experiments, ExperimentsCLI}
  alias Aiur.Experiments.{Evidence, Paths, ReportInput, ReportRecords, ReportSubmission, Snapshot, StatsRunner, Store}
  alias Aiur.TestSupport.RuntimeChildren
  @fixtures Path.expand("../../fixtures/experiments", __DIR__)

  setup do
    root = Aiur.TestSupport.tmp_root!("report-submit")
    previous_base = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :repo_base_root, Path.join(root, "repo"))
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      if previous_base, do: Application.put_env(:aiur, :repo_base_root, previous_base), else: Application.delete_env(:aiur, :repo_base_root)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    :ok = Aiur.TestSupport.ensure_pubsub_running()
    :ok = RuntimeChildren.ensure_aiur_supervisor_running()
    start_supervised!(StatsRunner)
    start_supervised!({Store, catalog_context: %{reduce_dir: Path.expand("../../../../analytics", __DIR__)}})

    attrs = %{
      id: "report-example",
      title: "Report example",
      design: %{kind: "before_after", change: %{type: "manual", ref: "test", time: "2026-10-09T00:00:00Z"}},
      windows: %{before: %{start: "2026-10-08T00:00:00Z", end: "2026-10-09T00:00:00Z"}, after: %{start: "2026-10-09T00:00:00Z", end: "2026-10-10T00:00:00Z"}},
      metrics: [%{ref: "delivery-speed/start_to_merge"}]
    }

    assert {:ok, spec} = Experiments.create(attrs, freeze: false)

    registration =
      read("preregistration.valid.json")
      |> Map.put("primary_metrics", [%{"id" => "delivery-speed/start_to_merge", "expected" => "decrease"}])
      |> put_in(["mde", "metric"], "delivery-speed/start_to_merge")

    assert {:ok, registration} = Experiments.put_preregistration(spec.id, registration)
    ctx = context(5)
    for name <- ["before", "after"], do: assert({:ok, _snapshot} = Snapshot.freeze(spec.id, name, context: ctx))
    assert {:ok, events} = Experiments.events(spec.id, records_fun: fn _ -> {[], []} end, alert_files: [], github_fun: fn _, _, _, _ -> {%{}, []} end)
    %{id: spec.id, registration: registration, events: events}
  end

  defp read(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp context(value) do
    %{
      clock: ~U[2026-10-11 00:00:00Z],
      evaluate: fn refs, window, _ctx ->
        row = %{"unit_id" => window["start"], "at" => window["start"], "value" => value, "started_at" => window["start"], "finished_at" => window["start"], "censored" => false, "attrs" => %{}}
        Map.new(refs, &{&1, %{"coverage" => %{"state" => "captured"}, "observations" => [row]}})
      end
    }
  end

  defp report(stats, registration, events) do
    row = hd(stats["report_results"])

    read("report.valid.json")
    |> Map.put("results", [row])
    |> Map.put("labels", [row["label"]])
    |> Map.put("confounders", [])
    |> put_in(["preregistration", "record"], registration)
    |> put_in(["header", "stats_snapshot_hash"], stats["snapshot_hash"])
    |> put_in(["header", "events_snapshot_hash"], events["snapshot_hash"])
    |> put_in(["header", "preregistration_hash"], Evidence.hash(registration))
  end

  test "CLI submits against recomputed engine output, assigns versions and persists rendered report", ctx do
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :stats, argv: [ctx.id, "--json"]) == 0 end)
    stats = Jason.decode!(output)
    assert {:ok, prepared} = ReportInput.prepare(ctx.id)
    assert prepared.input["taken_at"] == "2026-10-10T00:00:00Z"
    assert stats["body"]["metrics"]["delivery-speed/start_to_merge"]["groups"]["before"]["n"] == 1
    submitted = report(stats, ctx.registration, ctx.events) |> put_in(["header", "report_version"], 999)
    parent = self()

    output =
      capture_io(fn ->
        warning = capture_io(:stderr, fn -> assert ExperimentsCLI.run(verb: :report_submit, argv: [ctx.id, "--contract-json", Jason.encode!(submitted)]) == 0 end)
        send(parent, {:warning, warning})
      end)

    assert output == "report v1 stored\n"
    assert_receive {:warning, warning}, 1_000
    assert warning =~ "confirmatory rewritten to interim"
    assert {:ok, records} = ReportRecords.read(ctx.id)
    assert [first] = records["reports"]
    assert first["header"]["analysis_type"] == "interim"
    assert first["header"]["report_version"] == 1
    assert Experiments.report_markdown(first) =~ "n=after=1 / before=1"
    assert {:ok, %{"report" => second}} = Experiments.put_report(ctx.id, submitted)
    assert second["header"]["report_version"] == 2
    assert {:ok, detail} = Experiments.fetch(ctx.id)
    assert detail.report_records["reports"] == [first, second]
    assert File.exists?(Paths.file(ctx.id, "report/contract.json"))
  end

  test "a spec change during preparation prevents committing a report", ctx do
    assert {:ok, stats} = Experiments.stats(ctx.id)
    submitted = report(stats, ctx.registration, ctx.events)
    assert {:ok, prepared} = ReportSubmission.prepare(ctx.id, submitted, %{reduce_dir: Path.expand("../../../../analytics", __DIR__)})
    assert {:ok, _spec} = Experiments.amend(ctx.id, %{notes: "Changed during analysis"}, "operator")
    assert {:error, :stale_preparation} = ReportSubmission.commit(prepared)
    assert {:ok, records} = ReportRecords.read(ctx.id)
    assert records["reports"] == []
  end

  test "stale stats reject through CLI with exit one and leave report history untouched", ctx do
    assert {:ok, stats} = Experiments.stats(ctx.id)
    submitted = report(stats, ctx.registration, ctx.events)
    assert {:ok, _revision} = Snapshot.freeze(ctx.id, "after", context: context(9), reason: "New outcomes")
    error = capture_io(:stderr, fn -> assert ExperimentsCLI.run(verb: :report_submit, argv: [ctx.id, "--contract-json", Jason.encode!(submitted)]) == 1 end)
    assert error =~ "header.stats_snapshot_hash: stale stats snapshot hash"
    assert {:ok, records} = ReportRecords.read(ctx.id)
    assert records["reports"] == []
  end
end
