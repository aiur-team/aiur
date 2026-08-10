defmodule Aiur.SweepWatermarkStoreTest do
  use Aiur.TestSupport

  alias Aiur.SweepWatermarkStore

  setup do
    path = Path.join(System.tmp_dir!(), "aiur-sweep-watermark-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    {:ok, path: path}
  end

  describe "load/1 and save/2" do
    test "round-trips every cursor family the sweep depends on", %{path: path} do
      observed_at = ~U[2026-07-12 18:00:00Z]

      :ok =
        SweepWatermarkStore.save(
          %{
            events_last_id: "event-9",
            comment_cursors: %{"41" => "2026-07-12T17:00:00Z", "42" => "2026-07-12T17:30:00Z"},
            pr_review_seen_at: %{"41" => "2026-07-12T17:05:00Z"},
            observed_at: observed_at
          },
          sweep_watermark_path: path
        )

      assert %{
               events_last_id: "event-9",
               comment_cursors: %{"41" => "2026-07-12T17:00:00Z", "42" => "2026-07-12T17:30:00Z"},
               pr_review_seen_at: %{"41" => "2026-07-12T17:05:00Z"},
               observed_at: ^observed_at
             } = SweepWatermarkStore.load(sweep_watermark_path: path)
    end

    test "a missing file yields an empty watermark rather than a crash", %{path: path} do
      assert SweepWatermarkStore.load(sweep_watermark_path: path) == SweepWatermarkStore.empty()
    end

    test "a corrupt file fails safe to an empty watermark", %{path: path} do
      File.write!(path, "{not json")

      assert SweepWatermarkStore.load(sweep_watermark_path: path) == SweepWatermarkStore.empty()
    end

    test "malformed cursor entries are dropped without discarding the good ones", %{path: path} do
      File.write!(
        path,
        Jason.encode!(%{
          "events_last_id" => "",
          "comment_cursors" => %{"41" => "2026-07-12T17:00:00Z", "42" => 17, "" => "2026-07-12T17:00:00Z"},
          "pr_review_seen_at" => "not-a-map",
          "observed_at" => "not-a-timestamp"
        })
      )

      assert %{
               events_last_id: nil,
               comment_cursors: %{"41" => "2026-07-12T17:00:00Z"},
               pr_review_seen_at: %{},
               observed_at: nil
             } = SweepWatermarkStore.load(sweep_watermark_path: path)
    end
  end

  describe "restored_cutoff/2" do
    test "resumes from the recorded sweep when it is inside the lookback bound" do
      observed_at = ~U[2026-07-12 18:00:00Z]
      watermark = %{SweepWatermarkStore.empty() | observed_at: observed_at}

      assert SweepWatermarkStore.restored_cutoff(watermark, now: ~U[2026-07-12 20:00:00Z]) == observed_at
      refute SweepWatermarkStore.lookback_truncated?(watermark, now: ~U[2026-07-12 20:00:00Z])
    end

    test "clamps to the lookback floor when the recorded sweep is older than the bound" do
      watermark = %{SweepWatermarkStore.empty() | observed_at: ~U[2026-07-01 00:00:00Z]}
      now = ~U[2026-07-12 20:00:00Z]

      assert SweepWatermarkStore.restored_cutoff(watermark, now: now) == ~U[2026-07-11 20:00:00Z]
      assert SweepWatermarkStore.lookback_truncated?(watermark, now: now)
    end

    test "honors an explicit lookback bound" do
      watermark = %{SweepWatermarkStore.empty() | observed_at: ~U[2026-07-12 18:00:00Z]}
      now = ~U[2026-07-12 20:00:00Z]

      assert SweepWatermarkStore.restored_cutoff(watermark, now: now, max_lookback_seconds: 3_600) ==
               ~U[2026-07-12 19:00:00Z]

      assert SweepWatermarkStore.lookback_truncated?(watermark, now: now, max_lookback_seconds: 3_600)
    end

    test "returns nil with no sweep on record so callers keep the boot cutoff" do
      assert SweepWatermarkStore.restored_cutoff(SweepWatermarkStore.empty()) == nil
      refute SweepWatermarkStore.lookback_truncated?(SweepWatermarkStore.empty())
    end
  end
end
