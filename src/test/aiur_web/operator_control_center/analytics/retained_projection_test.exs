defmodule AiurWeb.OperatorControlCenter.Analytics.RetainedProjectionTest do
  use ExUnit.Case, async: false

  alias Aiur.RunTelemetry.{Dataset, Summaries, SummaryMerge}
  alias AiurWeb.OperatorControlCenter.Analytics.{LatestRun, Presenter}

  @fixture Path.expand("../../../fixtures/analytics/runs/boot-a/run-summary.json", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "retained-projection-#{System.unique_integer([:positive])}")
    old = for key <- [:repo_base_root, :analytics_repo], do: {key, Application.fetch_env(:aiur, key)}
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "projection/test")

    on_exit(fn ->
      Enum.each(old, fn
        {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
        {key, :error} -> Application.delete_env(:aiur, key)
      end)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "latest-run reads real summaries and retains only the newest winner", %{root: root} do
    summary = @fixture |> File.read!() |> Jason.decode!()

    for {boot, finish} <- [{"old", "2026-07-11T00:00:16Z"}, {"new", "2026-07-12T00:00:16Z"}] do
      path = Summaries.run_summary_path(boot)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(put_in(summary, ["provenance", "time_range", "end"], finish)))
    end

    assert {:ok, dataset} = LatestRun.load(Path.join(root, "missing.ndjson"), "live", &analyzable?/1)
    assert dataset.provenance.time_range.end == "2026-07-12T00:00:16Z"
    assert [{_key, {[cached], false}}] = :ets.lookup(LatestRun, {LatestRun.cache_identity("live"), nil})
    assert cached.provenance.time_range.end == dataset.provenance.time_range.end
  end

  test "cache evicts old retained winners after repeated invalidations", %{root: root} do
    {:ok, dataset} = @fixture |> File.read!() |> Summaries.decode_summary()

    for _ <- 1..12 do
      assert {:ok, ^dataset} = LatestRun.load(Path.join(root, "missing.ndjson"), "live", &analyzable?/1, cache_identity: make_ref(), prior_loader: fn -> {[dataset], false} end)
    end

    assert :ets.info(LatestRun, :size) <= 8
  end

  test "future regression guard: full-log fallback keeps both boots of a small raw file", %{root: root} do
    file = Path.join(root, "telemetry.ndjson")
    File.mkdir_p!(root)

    File.write!(
      file,
      Enum.map_join(["older", "current"], "\n", fn boot ->
        Jason.encode!(%{
          schema_version: 2,
          kind: "restart",
          timestamp: "2026-07-11T00:00:00Z",
          recorded_at: "2026-07-11T00:00:00Z",
          boot_id: boot,
          sequence: 1,
          record_id: boot <> ":1",
          attributes: %{event: "restart"}
        })
      end) <> "\n"
    )

    assert {:ok, dataset} = SummaryMerge.load(file, "current")
    assert Dataset.boot_ids(dataset) |> Enum.sort() == ["current", "older"]
  end

  test "full-log refuses an unbounded raw-history fallback", %{root: root} do
    file = Path.join(root, "large.ndjson")
    File.mkdir_p!(root)
    File.write!(file, String.duplicate("{}\n", 400_000))
    assert {:error, :retained_unreadable} = SummaryMerge.load(file, "current")
  end

  test "full log keeps newest complete runs that fit and exposes the included population", %{root: root} do
    summary = @fixture |> File.read!() |> Jason.decode!()
    source = Enum.find(summary["records"], &(&1["kind"] == "lifecycle"))

    for i <- 1..4 do
      boot = "boot-#{i}"

      records =
        for n <- 1..100 do
          source
          |> Map.put("boot_id", boot)
          |> Map.put("record_id", "#{boot}:#{n}")
          |> Map.put("sequence", n)
          |> Map.update!("attributes", &Map.put(&1, "diagnostic", String.duplicate("x", 65_000)))
        end

      body = summary |> Map.put("records", records) |> put_in(["provenance", "time_range", "end"], "2026-07-1#{i}T00:00:16Z")
      path = Summaries.run_summary_path(boot)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(body))
    end

    assert {:ok, dataset} = SummaryMerge.load(Path.join(root, "missing.ndjson"), "live")
    assert dataset.retained_runs.total == 4
    assert dataset.retained_runs.included in 1..3
    assert dataset.provenance.time_range.end == "2026-07-14T00:00:16Z"
    assert :erlang.external_size(dataset) <= 24 * 1024 * 1024
    assert {:ok, model} = Presenter.load(session: :cross, telemetry_file: Path.join(root, "missing.ndjson"))
    assert model.retained_runs == dataset.retained_runs
    assert model.available?
  end

  defp analyzable?(dataset), do: map_size(dataset.tickets) > 0
end
