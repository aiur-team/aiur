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

  describe "spend_over_time/1" do
    test "draws one band per series band, remainder last" do
      svg = Charts.spend_over_time(series())

      assert svg =~ ~s(aria-label="graphql spend over time, by caller")
      assert length(Regex.scan(~r/<path/, svg)) == 3
      # A 2px surface gap, so two adjacent bands never read as one region.
      assert svg =~ "stroke=\"var(--surface)\" stroke-width=\"2\""
      # The remainder is drawn last, so it is the top of the stack and the top
      # of the stack is the credential's own spend.
      assert svg |> String.split("var(--ghc-series-outside)") |> hd() =~ "var(--ghc-series-1)"
    end

    test "every band carries its name, so identity is never colour alone" do
      svg = Charts.spend_over_time(series())

      assert svg =~ "<title>comment_poll_batch"
      assert svg =~ "<title>not issued by this daemon"
    end

    test "band_color never cycles the categorical palette" do
      # A sixth caller folds into the neutral tail rather than borrowing slot
      # one's hue and claiming to be that caller.
      assert Charts.band_color(%{kind: :caller, slot: 1}) == "var(--ghc-series-1)"
      assert Charts.band_color(%{kind: :caller, slot: 5}) == "var(--ghc-series-5)"
      assert Charts.band_color(%{kind: :caller, slot: 6}) == "var(--ghc-series-other)"
      assert Charts.band_color(%{kind: :other, slot: nil}) == "var(--ghc-series-other)"
      assert Charts.band_color(%{kind: :outside, slot: nil}) == "var(--ghc-series-outside)"
    end

    test "an attributed-only chart carries the qualifier in its accessible label" do
      # A chart of what this daemon issued, read as the whole bill, is the exact
      # mistake this page exists to prevent — so the scope is in the label, not
      # only in the caption beside it.
      svg = Charts.spend_over_time(%{series() | scope: :attributed})

      assert svg =~ "not the whole bill"
      refute Charts.spend_over_time(series()) =~ "not the whole bill"
    end

    test "shades and labels history from before the current credential window" do
      series = %{series() | current_window_started_at_ms: @t0 + 60_000}
      svg = Charts.spend_over_time(series)

      assert svg =~ ~s(data-role="pre-window-history")
      assert svg =~ ~s(data-role="current-window-boundary")
      assert svg =~ ~s(<rect x="44" y="14" width="351.0")
      assert svg =~ ~s(<line x1="395.0" x2="395.0")
      assert svg =~ "before current window"
      assert svg =~ "current window"
    end

    test "does not connect stacked bands across a credential-window reset" do
      points =
        series().points
        |> Enum.with_index()
        |> Enum.map(fn {point, index} ->
          values = if index < 2, do: %{"comment_poll_batch" => 4_800}, else: %{"comment_poll_batch" => 2}
          %{point | values: values}
        end)

      svg = Charts.spend_over_time(%{series() | points: points, current_window_started_at_ms: @t0 + 60_000})

      assert length(Regex.scan(~r/<path/, svg)) == 6
      assert length(Regex.scan(~r/<path[^>]+data-window="previous"/, svg)) == 3
      assert length(Regex.scan(~r/<path[^>]+data-window="current"/, svg)) == 3
    end

    test "omits window markers when the boundary is outside retained history" do
      for boundary <- [@t0, @t0 + 150_000, nil] do
        svg = Charts.spend_over_time(%{series() | current_window_started_at_ms: boundary})

        refute svg =~ ~s(data-role="pre-window-history")
        refute svg =~ ~s(data-role="current-window-boundary")
      end
    end

    test "renders nothing rather than an empty axis when there is nothing to draw" do
      assert Charts.spend_over_time(nil) == ""
      assert Charts.spend_over_time(%{series() | points: Enum.take(series().points, 1)}) == ""
    end
  end

  defp series do
    bands = [
      %{key: "comment_poll_batch", label: "comment_poll_batch", kind: :caller, slot: 1},
      %{key: "ci_poll_batch", label: "ci_poll_batch", kind: :caller, slot: 2},
      %{key: "__outside__", label: "not issued by this daemon", kind: :outside, slot: nil}
    ]

    points =
      for i <- 0..4 do
        %{
          t_ms: @t0 + i * 30_000,
          values: %{"comment_poll_batch" => 93 + i, "ci_poll_batch" => 10, "__outside__" => 4_800},
          attributed: 103 + i,
          spend: 4_903 + i
        }
      end

    %{
      budget: "graphql",
      scope: :bill,
      bands: bands,
      points: points,
      dropped: 0,
      estimated?: false,
      current_window_started_at_ms: @t0
    }
  end
end
