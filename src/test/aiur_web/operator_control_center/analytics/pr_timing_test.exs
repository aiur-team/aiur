defmodule AiurWeb.OperatorControlCenter.Analytics.PrTimingTest do
  use ExUnit.Case, async: true
  alias Aiur.RunTelemetry.Timeline
  alias AiurWeb.OperatorControlCenter.Analytics.{Charts, Presenter, TicketRow}

  test "presenter exposes earliest PR-open and review status, and chart renders the milestone" do
    dataset = %{
      actors: %{},
      tickets: %{"1" => %{intervals: [point("dispatch", 1_000), point("pr_opened", 4_000), point("pr_opened", 2_000)]}},
      provenance: %{time_range: %{start: "1970-01-01T00:00:01Z", end: "1970-01-01T00:00:05Z"}}
    }

    model = Presenter.model(dataset, buckets: 4, axis: :absolute, range: :full)
    assert [row] = model.tickets
    assert row.pr_opened_at == 2_000
    assert row.status == :in_review
    svg = Charts.gantt(model)
    assert svg =~ ~s(class="an-pr-opened" x1="225.5" x2="225.5")
    assert svg =~ "<title>PR opened</title>"
    assert svg =~ ~s|fill="var(--attention)"|
  end

  test "status preserves merged, rework and pause precedence over review" do
    opened = [point("dispatch", 1_000), point("pr_opened", 2_000)]

    for {phases, status} <- [
          {["agent_pause", "rework_start", "pr_merged"], :merged},
          {["agent_pause", "rework_start"], :rework},
          {["agent_pause"], :paused},
          {[], :in_review}
        ] do
      intervals = opened ++ Enum.map(phases, &point(&1, 3_000))
      row = TicketRow.build("1", %{intervals: intervals}, & &1)
      assert row.status == status
      assert row.pr_opened_at == 2_000
    end
  end

  test "absent PR-open stays unknown and draws no marker" do
    row = TicketRow.build("1", %{intervals: [point("dispatch", 1_000)]}, & &1)
    assert row.pr_opened_at == nil
    assert row.status == :active
    refute Charts.gantt(%{tickets: [row], window: %{start_ms: 0, end_ms: 5_000}}) =~ "an-pr-opened"
  end

  test "PR-open projects onto the active timeline and hides outside the chart window" do
    timeline = Timeline.active([1_000, 2_000, 10_000, 11_000], max_idle_gap_ms: 2_000)
    row = TicketRow.build("1", %{intervals: [point("dispatch", 1_000), point("pr_opened", 10_500)]}, &Timeline.project(timeline, &1))
    assert row.pr_opened_at == 1_500
    refute Charts.gantt(%{tickets: [row], window: %{start_ms: 0, end_ms: 1_000}}) =~ "an-pr-opened"
  end

  defp point(phase, ms), do: %{phase: phase, status: "point", start_ms: ms, end_ms: nil}
end
