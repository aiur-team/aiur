defmodule AiurWeb.OperatorControlCenter.GithubCache.ChartsTest do
  @moduledoc """
  The inline-SVG chart builders behind the `/github-cache` history charts.

  Pure functions over `Aiur.GitHub.CacheHistory` samples: each renders a themed,
  self-contained `<svg>` (or `""` when there are not enough samples to draw), so
  the page can render them without a client charting library.
  """

  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.GithubCache.Charts

  @t0 DateTime.to_unix(~U[2026-08-18 12:00:00Z], :millisecond)

  defp samples do
    for i <- 0..4 do
      %{
        t_ms: @t0 + i * 30_000,
        total: 10 + i,
        with_body: 8 + i,
        bodyless: 2,
        fresh: 6 + i,
        stale: 2,
        expired: 1,
        unknown: 1
      }
    end
  end

  test "entries_over_time renders a chart with the three series" do
    svg = Charts.entries_over_time(samples())

    assert svg =~ ~s(role="img")
    assert svg =~ ~s(aria-label="Cache entries over time")
    assert svg =~ "viewBox=\"0 0 760 200\""

    # total, with body, validator-only — one stroke path each, plus the grid.
    assert svg =~ "stroke=\"var(--fg)\""
    assert svg =~ "stroke=\"var(--good)\""
    assert svg =~ "stroke=\"var(--attention)\""
    assert length(Regex.scan(~r/<path/, svg)) == 3
  end

  test "freshness_over_time renders a stacked area for the four buckets" do
    svg = Charts.freshness_over_time(samples())

    assert svg =~ ~s(aria-label="Cache freshness over time")
    assert svg =~ "fill=\"var(--good)\""
    assert svg =~ "fill=\"var(--attention)\""
    assert svg =~ "fill=\"var(--blocking)\""
    assert svg =~ "fill=\"var(--faint)\""
    assert length(Regex.scan(~r/<path/, svg)) == 4
  end

  test "the freshness stack tops out at the total" do
    svg = Charts.freshness_over_time(samples())

    # The stacked paths are each a closed polygon; their top edges all pass
    # through the point at y = yf(total). Asserting every bucket is drawn as a
    # closed region catches a chart that draws lines instead of a stack.
    assert length(Regex.scan(~r/ Z/, svg)) == 4
  end

  test "renders nothing when there are not enough samples to draw" do
    assert Charts.entries_over_time([]) == ""
    assert Charts.freshness_over_time([]) == ""

    assert Charts.entries_over_time([hd(samples())]) == ""
    assert Charts.freshness_over_time([hd(samples())]) == ""
  end
end
