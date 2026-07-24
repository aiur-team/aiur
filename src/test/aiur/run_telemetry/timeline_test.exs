defmodule Aiur.RunTelemetry.TimelineTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.Timeline

  @minute 60_000
  @hour 3_600_000
  @day 24 * @hour

  describe "identity/0" do
    test "passes wall-clock milliseconds straight through" do
      timeline = Timeline.identity()

      assert Timeline.project(timeline, 1_000) == 1_000
      assert Timeline.project(timeline, 999_999_999) == 999_999_999
    end

    test "reports the raw wall-clock span so a single session is charted as-is" do
      assert Timeline.span_ms(Timeline.identity(), 1_000, 1_000 + @hour) == @hour
    end
  end

  describe "active/2 span detection" do
    test "samples inside the idle threshold stay in one span" do
      stamps = for i <- 0..10, do: i * @minute

      timeline = Timeline.active(stamps, max_idle_gap_ms: 15 * @minute)

      assert timeline.spans == [{0, 10 * @minute}]
      assert timeline.total_ms == 10 * @minute
    end

    test "a gap wider than the threshold splits the span" do
      stamps = [0, @minute, 2 * @minute, 2 * @minute + @day, 2 * @minute + @day + @minute]

      timeline = Timeline.active(stamps, max_idle_gap_ms: 15 * @minute)

      assert timeline.spans == [{0, 2 * @minute}, {2 * @minute + @day, 2 * @minute + @day + @minute}]
    end

    test "a gap exactly at the threshold is not a split, so the boundary is not off by one" do
      timeline = Timeline.active([0, 15 * @minute], max_idle_gap_ms: 15 * @minute)

      assert timeline.spans == [{0, 15 * @minute}]
    end

    test "unsorted and non-integer input is tolerated rather than trusted" do
      timeline = Timeline.active([2 * @minute, nil, 0, "x", @minute], max_idle_gap_ms: 15 * @minute)

      assert timeline.spans == [{0, 2 * @minute}]
    end

    test "no usable timestamps degrades to the pass-through projection" do
      assert Timeline.active([]) == Timeline.identity()
      assert Timeline.active([nil, :bad]) == Timeline.identity()
    end
  end

  describe "active/2 projection" do
    # Two half-hour sessions three days apart: one hour of real work, three days
    # of calendar. Everything downstream must see the hour.
    setup do
      session_one = for i <- 0..30, do: i * @minute
      session_two = for i <- 0..30, do: 3 * @day + i * @minute

      {:ok, timeline: Timeline.active(session_one ++ session_two, max_idle_gap_ms: 15 * @minute)}
    end

    test "reports elapsed active time, not calendar time", %{timeline: timeline} do
      # This is the whole point: a three-day-wide build measures one hour.
      assert timeline.total_ms == 60 * @minute
      assert Timeline.span_ms(timeline, 0, 3 * @day + 30 * @minute) == 60 * @minute
    end

    test "the second session begins immediately after the first on the axis", %{timeline: timeline} do
      assert Timeline.project(timeline, 0) == 0
      assert Timeline.project(timeline, 30 * @minute) == 30 * @minute
      assert Timeline.project(timeline, 3 * @day) == 30 * @minute
      assert Timeline.project(timeline, 3 * @day + 10 * @minute) == 40 * @minute
    end

    test "a timestamp inside an elided gap clamps to the end of the preceding span", %{timeline: timeline} do
      # A merge recorded overnight must land at the close of the session that
      # produced it, not vanish and not jump into the next session.
      assert Timeline.project(timeline, @day) == 30 * @minute
      assert Timeline.project(timeline, 2 * @day) == 30 * @minute
    end

    test "projection is monotonic across the whole wall-clock range", %{timeline: timeline} do
      probes = [0, 10 * @minute, 30 * @minute, @day, 3 * @day, 3 * @day + 20 * @minute, 9 * @day]
      projected = Enum.map(probes, &Timeline.project(timeline, &1))

      assert projected == Enum.sort(projected)
    end

    test "timestamps before and after all activity clamp to the axis bounds", %{timeline: timeline} do
      assert Timeline.project(timeline, -@day) == 0
      assert Timeline.project(timeline, 99 * @day) == timeline.total_ms
    end
  end

  test "a scope with a single measured moment still reports a usable axis length" do
    timeline = Timeline.active([5_000])

    # Zero would make every downstream bucket division degenerate.
    assert timeline.total_ms == 1
  end
end
