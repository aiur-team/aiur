defmodule AiurWeb.OperatorControlCenter.Analytics.RetainedProjectionTest do
  use ExUnit.Case, async: false

  alias Aiur.RunTelemetry.{Dataset, RetainedCache, Summaries, SummaryMerge}
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

      Aiur.TestCleanup.rm_rf!(root)
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
    assert [{_key, {[cached], false}}] = :ets.lookup(LatestRun, {RetainedCache.identity("live"), nil})
    assert cached.provenance.time_range.end == dataset.provenance.time_range.end
  end

  test "cache evicts old retained winners after repeated invalidations", %{root: root} do
    {:ok, dataset} = @fixture |> File.read!() |> Summaries.decode_summary()

    for _ <- 1..12 do
      assert {:ok, ^dataset} = LatestRun.load(Path.join(root, "missing.ndjson"), "live", &analyzable?/1, cache_identity: make_ref(), prior_loader: fn -> {[dataset], false} end)
    end

    assert :ets.info(LatestRun, :size) <= 8
  end

  test "latest-run skips an oversized newest summary and discloses it", %{root: root} do
    for boot <- ["older", "newer"] do
      path = Summaries.run_summary_path(boot)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{}")
    end

    {:ok, template} = @fixture |> File.read!() |> Summaries.decode_summary()
    newer_at = DateTime.utc_now() |> DateTime.truncate(:second)
    older_at = DateTime.add(newer_at, -1, :second)
    older = put_in(template, [:provenance, :time_range, :end], DateTime.to_iso8601(older_at))
    newer = put_in(template, [:provenance, :time_range, :end], DateTime.to_iso8601(newer_at))
    parent = self()

    opts = [
      cache_identity: make_ref(),
      summary_index_loader: fn
        "newer" -> {:ok, newer.provenance.time_range.end, 10, 45 * 1024 * 1024 + 1}
        "older" -> {:ok, older.provenance.time_range.end, 10, 100}
      end,
      summary_dataset_loader: fn boot ->
        send(parent, {:decoded_latest, boot})
        {:ok, if(boot == "newer", do: newer, else: older)}
      end
    ]

    assert {:ok, dataset} = LatestRun.load(Path.join(root, "missing.ndjson"), "live", &analyzable?/1, opts)
    assert dataset.provenance.time_range.end == older.provenance.time_range.end
    assert dataset.retained_runs == %{included: 1, total: 2, skipped_large: 1, skipped_newer: 1}
    assert_receive {:decoded_latest, "older"}, 100
    refute_receive {:decoded_latest, "newer"}, 100
  end

  test "latest-run reports unavailable when no retained summary fits the scan budget", %{root: root} do
    path = Summaries.run_summary_path("oversized")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}")

    assert {:error, :retained_scan_limited} =
             LatestRun.load(Path.join(root, "missing.ndjson"), "live", &analyzable?/1,
               cache_identity: make_ref(),
               summary_index_loader: fn _boot -> {:ok, DateTime.utc_now() |> DateTime.to_iso8601(), 10, 45 * 1024 * 1024 + 1} end,
               summary_dataset_loader: fn _boot -> flunk("oversized summary must be rejected before decoding") end
             )
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

  test "full log stops decoding when the cumulative summary byte budget fills", %{root: root} do
    for boot <- ["old", "new"] do
      File.mkdir_p!(Path.dirname(Summaries.run_summary_path(boot)))
    end

    parent = self()
    timestamps = %{"old" => "2026-07-11T00:00:16Z", "new" => "2026-07-12T00:00:16Z"}
    {:ok, template} = @fixture |> File.read!() |> Summaries.decode_summary()
    newest = put_in(template, [:provenance, :time_range, :end], timestamps["new"])
    older = put_in(template, [:provenance, :time_range, :end], timestamps["old"])

    index_loader = fn boot -> {:ok, timestamps[boot], 100, 30 * 1024 * 1024} end

    dataset_loader = fn boot ->
      send(parent, {:decoded_summary, boot})
      {:ok, if(boot == "new", do: newest, else: older)}
    end

    assert {:ok, merged} =
             SummaryMerge.load(
               Path.join(root, "missing.ndjson"),
               "live",
               summary_index_loader: index_loader,
               summary_dataset_loader: dataset_loader
             )

    assert merged.retained_runs.included == 1
    assert_receive {:decoded_summary, "new"}, 100
    refute_receive {:decoded_summary, "old"}, 100
  end

  test "full log does not decode a summary beyond the retained byte cap", %{root: root} do
    File.mkdir_p!(Path.dirname(Summaries.run_summary_path("oversized")))
    parent = self()
    {:ok, dataset} = @fixture |> File.read!() |> Summaries.decode_summary()

    index_loader = fn boot ->
      send(parent, {:indexed_oversized, boot})
      {:ok, "2026-07-12T00:00:16Z", 100, 128 * 1024 * 1024 + 1}
    end

    dataset_loader = fn _boot ->
      send(parent, :decoded_oversized)
      {:ok, dataset}
    end

    assert {:error, :retained_scan_limited} =
             SummaryMerge.load(
               Path.join(root, "missing.ndjson"),
               "live",
               summary_index_loader: index_loader,
               summary_dataset_loader: dataset_loader,
               max_scan_bytes: 1
             )

    assert_receive {:indexed_oversized, "oversized"}, 100
    refute_receive :decoded_oversized, 100
  end

  test "full log rejects a sole summary over the retained byte cap", %{root: root} do
    path = Summaries.run_summary_path("oversized_solo")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}")
    observed_at = DateTime.utc_now() |> DateTime.to_iso8601()

    assert {:error, :retained_scan_limited} =
             SummaryMerge.load(Path.join(root, "missing.ndjson"), "live", summary_index_loader: fn _boot -> {:ok, observed_at, 10, 210 * 1024 * 1024} end)
  end

  test "the full-log presenter reports scan limits without claiming summaries are corrupt", %{root: root} do
    path = Summaries.run_summary_path("limited")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}")

    opts = [
      max_scan_bytes: 1,
      summary_index_loader: fn _boot -> {:ok, "2026-07-12T00:00:16Z", 100, 2} end,
      summary_dataset_loader: fn _boot -> flunk("scan budget must reject this summary before decoding") end
    ]

    assert {:unavailable, :retained_scan_limited} =
             Presenter.load(Keyword.merge(opts, session: :cross, telemetry_file: Path.join(root, "missing.ndjson")))
  end

  defp analyzable?(dataset), do: map_size(dataset.tickets) > 0
end
