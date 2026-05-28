defmodule Aiur.ProgressTrackerTest do
  use ExUnit.Case, async: true

  alias Aiur.ProgressTracker

  describe "record/3" do
    test "appends to the front, newest first" do
      samples =
        []
        |> ProgressTracker.record(10, 1000)
        |> ProgressTracker.record(25, 2000)
        |> ProgressTracker.record(40, 3000)

      assert samples == [{40, 3000}, {25, 2000}, {10, 1000}]
    end

    test "clamps percent to 0..100" do
      assert [{100, _} | _] = ProgressTracker.record([], 150, 1000)
      assert [{0, _} | _] = ProgressTracker.record([], -25, 1000)
    end

    test "drops oldest beyond the cap so memory stays bounded" do
      samples =
        Enum.reduce(1..20, [], fn i, acc ->
          ProgressTracker.record(acc, i * 5, i * 1000)
        end)

      assert length(samples) == 8
      # Newest entry still on the head, regardless of cap.
      {latest_pct, _} = hd(samples)
      assert latest_pct == 100
    end
  end

  describe "estimate/2" do
    test "no samples → :unknown" do
      assert ProgressTracker.estimate([], 0) == :unknown
    end

    test "single sample → returns the percent but ETA is unknown" do
      samples = ProgressTracker.record([], 25, 1000)

      assert %{percent: 25, eta_seconds: :unknown} = ProgressTracker.estimate(samples, 2000)
    end

    test "two samples → linear extrapolation gives a finite ETA" do
      samples =
        []
        |> ProgressTracker.record(25, 0)
        |> ProgressTracker.record(50, 30_000)

      # 25 percentage points gained in 30s → 1.2s per percent.
      # Remaining 50 pct → 60s.
      result = ProgressTracker.estimate(samples, 30_000)
      assert result.percent == 50
      assert_in_delta result.eta_seconds, 60, 1
    end

    test "ETA decrements as wall time advances between samples" do
      samples =
        []
        |> ProgressTracker.record(25, 0)
        |> ProgressTracker.record(50, 30_000)

      a = ProgressTracker.estimate(samples, 35_000)
      b = ProgressTracker.estimate(samples, 45_000)

      # Both have an ETA derived from the same pair; b is 10s later
      # so its remaining ETA should be ~10s smaller.
      assert (a.eta_seconds - b.eta_seconds) in 9..11
    end

    test "stale samples freeze ETA at :unknown" do
      samples =
        []
        |> ProgressTracker.record(25, 0)
        |> ProgressTracker.record(50, 30_000)

      # Six minutes later → past the 5-minute stale window.
      assert %{eta_seconds: :unknown} = ProgressTracker.estimate(samples, 30_000 + 6 * 60_000)
    end

    test "non-monotonic samples (agent revised down) recompute from new pair" do
      samples =
        []
        |> ProgressTracker.record(60, 0)
        |> ProgressTracker.record(30, 10_000)

      # Rate went negative → no finite ETA.
      assert %{percent: 30, eta_seconds: :unknown} =
               ProgressTracker.estimate(samples, 10_000)
    end

    test "projected percent never crosses 99 between samples" do
      # Aggressive rate that would shoot past 100 if not capped.
      samples =
        []
        |> ProgressTracker.record(80, 0)
        |> ProgressTracker.record(95, 1_000)

      # Wait a long time after the last sample with the same fast rate;
      # the projection should clamp to 99 (so we don't say done before
      # the agent has actually finished).
      assert %{percent: 99} = ProgressTracker.estimate(samples, 5_000)
    end
  end

  describe "bar/2" do
    test "draws a fixed-width bar at 0%" do
      assert ProgressTracker.bar(0, 8) == "░░░░░░░░"
    end

    test "draws a fixed-width bar at 100%" do
      assert ProgressTracker.bar(100, 8) == "████████"
    end

    test "draws a fixed-width bar at 50%" do
      assert ProgressTracker.bar(50, 8) == "████░░░░"
    end

    test "clamps percent inputs" do
      assert ProgressTracker.bar(-10, 4) == "░░░░"
      assert ProgressTracker.bar(150, 4) == "████"
    end
  end

  describe "format_eta/1" do
    test "renders MM:SS for short durations" do
      assert ProgressTracker.format_eta(0) == "0:00"
      assert ProgressTracker.format_eta(45) == "0:45"
      assert ProgressTracker.format_eta(125) == "2:05"
    end

    test "renders Hh MMm for long durations" do
      assert ProgressTracker.format_eta(3700) == "1h 1m"
    end

    test "renders empty string for :unknown so the column reads as blank" do
      assert ProgressTracker.format_eta(:unknown) == ""
    end
  end
end
