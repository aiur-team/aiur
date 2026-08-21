defmodule Aiur.GitHub.QuotaUsageTest do
  @moduledoc """
  The arithmetic behind the `/github-cache` "what is spending the budget"
  charts, asserted against the shapes that made it necessary.

  The measured incident is the fixture: 88 GraphQL calls, 182 points, every one
  priced from GitHub's own `rateLimit.cost`, against a window that had actually
  spent 5,000. A ranking of the 182 alone would have been a confident, ordered,
  96%-wrong answer to "where did the budget go", so most of what is asserted
  here is about the part the ranking cannot see.
  """

  use ExUnit.Case, async: true

  alias Aiur.GitHub.QuotaUsage

  @now ~U[2030-01-01 12:00:00Z]
  @reset ~U[2030-01-01 12:30:00Z]
  # The window runs the hour up to its reset, so it opened at 11:30.
  @window_seconds 3_600
  # A daemon restarted four minutes ago — the deploy case, and the moment an
  # operator is most likely to open this page.
  @restarted_at ~U[2030-01-01 11:56:00Z]

  describe "sample/2" do
    test "keeps the two budgets apart and never offers a combined total" do
      sample = QuotaUsage.sample(snapshot(), @now)

      assert [{"graphql", graphql}, {"core", core}] = QuotaUsage.budgets(sample)
      assert graphql.spend == 5_000
      assert core.spend == 88
      refute Map.has_key?(sample, :total)
      refute Map.has_key?(graphql, :total)
    end

    test "carries the remainder the ranking cannot explain as its own figure" do
      %{budgets: %{"graphql" => graphql}} = QuotaUsage.sample(snapshot(), @now)

      # The rows add to 182; GitHub says the window cost 5,000.
      assert graphql.attributed == 182
      assert graphql.outside == 4_818
      assert graphql.direction == :shortfall
    end

    test "the remainder is not the meter's own `unattributed` caller" do
      %{budgets: %{"graphql" => graphql}} = QuotaUsage.sample(snapshot(), @now)

      # `Quota` names a call it made but could not attribute "unattributed", and
      # it stays a caller row. Spend this daemon never issued is a different
      # fact and never borrows that word.
      assert "unattributed" in Enum.map(graphql.callers, & &1.caller)
      assert graphql.outside != 0
    end

    test "answers nil for a meter that has observed no window" do
      # Not a row of zeroes. A zero here would say "nothing was spent" about a
      # budget that may be exhausted.
      assert QuotaUsage.sample(%{state: :unknown, windows: %{}}, @now) == nil
      assert QuotaUsage.sample(%{state: :observed, windows: %{}}, @now) == nil
      assert QuotaUsage.sample(:not_a_snapshot, @now) == nil
    end

    test "a window with no observable spend carries nil, never zero" do
      snapshot = %{snapshot() | coverage: %{resources: %{}}}
      %{budgets: %{"graphql" => graphql}} = QuotaUsage.sample(snapshot, @now)

      assert graphql.spend == nil
      assert graphql.outside == nil
      assert graphql.attributed == 182
    end

    test "an over-attributed window clamps rather than inverting the stack" do
      snapshot = put_in(snapshot().coverage.resources["graphql"].spend, 100)
      %{budgets: %{"graphql" => graphql}} = QuotaUsage.sample(snapshot, @now)

      assert graphql.outside == 0
    end

    test "an assumed cost anywhere marks the budget estimated" do
      %{budgets: %{"graphql" => graphql, "core" => core}} = QuotaUsage.sample(snapshot(), @now)

      assert graphql.estimated?
      refute core.estimated?
      assert Enum.find(graphql.callers, &(&1.caller == "unattributed")).estimated?
    end
  end

  describe "whose remainder it is" do
    test "a meter that was running when the window opened may name another consumer" do
      %{budgets: %{"graphql" => graphql}} = QuotaUsage.sample(snapshot(), @now)

      assert QuotaUsage.observation_complete?(graphql)
      assert QuotaUsage.outside_label(true) == "not issued by this daemon"
      assert QuotaUsage.attributable_from(graphql) == nil
    end

    test "a meter that booted mid-window may not, because the gap holds its own forgotten calls" do
      # The restart case. GitHub kept counting across the restart and reports
      # the whole hour on the next refresh, while attribution died with the
      # process — so the shortfall is this daemon's own spend, not somebody
      # else's, and the wording must not name somebody else.
      %{budgets: %{"graphql" => graphql}} = QuotaUsage.sample(restarted_snapshot(), @now)

      refute QuotaUsage.observation_complete?(graphql)
      assert QuotaUsage.outside_label(false) == "not observed by this daemon"
    end

    test "equal spans count as complete — booting exactly on the window edge is full coverage" do
      snapshot = %{snapshot() | observing_since: window_opened_at()}
      %{budgets: %{"graphql" => graphql}} = QuotaUsage.sample(snapshot, @now)

      assert graphql.observed_from == graphql.window_started_at
      assert QuotaUsage.observation_complete?(graphql)
    end

    test "the page can say how far back it sees and when the claim becomes safe again" do
      %{budgets: %{"graphql" => graphql}} = QuotaUsage.sample(restarted_snapshot(), @now)

      # Both ends, not just their comparison: "observed since X, window opened
      # Y" tells an operator whether to wait, and a hedge does not.
      assert graphql.observed_from == @restarted_at
      assert graphql.window_started_at == window_opened_at()
      # The meter's reach is fixed at boot; the window's start only moves at the
      # reset, so the reset is when attribution covers the whole window again.
      assert QuotaUsage.attributable_from(graphql) == @reset
    end

    test "an unknown reach never counts as complete" do
      # A missing boot time must fail closed. Failing open would put the
      # confident claim back exactly where nothing is known.
      refute QuotaUsage.observation_complete?(%{})
      refute QuotaUsage.observation_complete?(%{observed_from: nil, window_started_at: window_opened_at()})
      refute QuotaUsage.observation_complete?(%{observed_from: @restarted_at, window_started_at: nil})
    end

    test "the chart's remainder band takes the same wording as the table" do
      restarted = QuotaUsage.series(samples(3, observing_since: @restarted_at), "graphql")
      complete = QuotaUsage.series(samples(3), "graphql")

      assert List.last(restarted.bands).label == "not observed by this daemon"
      assert List.last(complete.bands).label == "not issued by this daemon"
    end
  end

  describe "ranked_callers/1 and share_of_attributed/2" do
    test "ranks by points, not by call count" do
      %{budgets: %{"graphql" => graphql}} = QuotaUsage.sample(snapshot(), @now)

      # review_threads_unaddressed made 50 calls to comment_poll_batch's 9 and
      # still costs less. A request-count ranking would invert these.
      assert Enum.map(QuotaUsage.ranked_callers(graphql), & &1.caller) == [
               "comment_poll_batch",
               "review_threads_unaddressed",
               "unattributed",
               "ci_poll_batch",
               "build_order_catalog",
               "build_order_pack_status"
             ]
    end

    test "share is of the attributed total, and absent when nothing was attributed" do
      %{budgets: %{"graphql" => graphql}} = QuotaUsage.sample(snapshot(), @now)
      top = hd(QuotaUsage.ranked_callers(graphql))

      assert QuotaUsage.share_of_attributed(top, graphql) == Float.round(93 / 182, 4)
      assert QuotaUsage.share_of_attributed(top, %{attributed: 0}) == nil
    end
  end

  describe "series/2" do
    test "stacks to the window's own spend, with the remainder on top" do
      series = QuotaUsage.series(samples(3), "graphql")

      assert List.last(series.bands).kind == :outside
      point = List.last(series.points)
      assert point.values |> Map.values() |> Enum.sum() == point.spend
    end

    test "folds past the palette rather than cycling a hue" do
      series = QuotaUsage.series(samples(3), "graphql")
      caller_bands = Enum.filter(series.bands, &(&1.kind == :caller))

      assert length(caller_bands) == QuotaUsage.top_callers()
      assert Enum.map(caller_bands, & &1.slot) == Enum.to_list(1..QuotaUsage.top_callers())
      assert Enum.any?(series.bands, &(&1.kind == :other))
    end

    test "a caller keeps its slot when another overtakes it" do
      # Ranked once over the whole series, so the colour follows the caller
      # rather than its rank at one instant.
      overtaking =
        samples(3) ++
          [sample_at(3, %{"review_threads_unaddressed" => {900, 60}, "comment_poll_batch" => {93, 9}}, [])]

      series = QuotaUsage.series(overtaking, "graphql")
      slots = Map.new(series.bands, &{&1.key, &1.slot})

      assert slots["review_threads_unaddressed"] == 1
      assert slots["comment_poll_batch"] == 2
    end

    test "draws only the trailing run where the window was observed, and says how much it dropped" do
      unobserved = sample_at(0, nil, spend: nil)
      series = QuotaUsage.series([unobserved | samples(3)], "graphql")

      assert series.dropped == 1
      assert length(series.points) == 3
    end

    test "attributed_only/1 drops the remainder and says so in its scope" do
      series = QuotaUsage.series(samples(3), "graphql")
      attributed = QuotaUsage.attributed_only(series)

      assert series.scope == :bill
      assert attributed.scope == :attributed
      refute Enum.any?(attributed.bands, &(&1.kind == :outside))

      point = List.last(attributed.points)
      assert point.values |> Map.values() |> Enum.sum() == point.attributed
      refute Map.has_key?(point.values, "__outside__")
    end

    test "answers nil rather than an axis when there is nothing measured to draw" do
      assert QuotaUsage.series([], "graphql") == nil
      assert QuotaUsage.series(samples(1), "graphql") == nil
      assert QuotaUsage.series(samples(3), "core") == nil
      assert QuotaUsage.series([sample_at(0, nil, spend: nil), sample_at(1, nil, spend: nil)], "graphql") == nil
    end
  end

  # -- fixtures -------------------------------------------------------------

  # The measured incident: 88 GraphQL calls, 182 points, all reported, against a
  # window that had spent the whole 5,000.
  @graphql_callers %{
    "comment_poll_batch" => {93, 9},
    "review_threads_unaddressed" => {50, 50},
    "ci_poll_batch" => {10, 10},
    "build_order_catalog" => {8, 8},
    "build_order_pack_status" => {4, 4},
    "unattributed" => {17, 7}
  }

  defp window_opened_at, do: DateTime.add(@reset, -@window_seconds, :second)

  # A meter that has been up longer than the window — it can account for all of
  # it, so the remainder genuinely belongs to another consumer.
  defp restarted_snapshot, do: %{snapshot() | observing_since: @restarted_at}

  defp snapshot do
    %{
      state: :observed,
      observing_since: DateTime.add(window_opened_at(), -600, :second),
      windows: %{
        "graphql" => %{limit: 5_000, remaining: 0, used: 5_000, reset_at: @reset, started_at: window_opened_at()},
        "core" => %{limit: 5_000, remaining: 4_912, used: 88, reset_at: @reset, started_at: window_opened_at()}
      },
      callers:
        Enum.map(@graphql_callers, fn {caller, {points, calls}} ->
          %{
            caller: caller,
            resource: "graphql",
            points: points,
            calls: calls,
            points_per_hour: 1.0,
            estimated?: caller == "unattributed"
          }
        end) ++
          [%{caller: "bot_identity", resource: "core", points: 88, calls: 88, points_per_hour: 2.0, estimated?: false}],
      coverage: %{
        resources: %{
          "graphql" => %{attributed: 182, spend: 5_000},
          "core" => %{attributed: 88, spend: 88}
        }
      },
      reconciliation: %{
        "graphql" => %{direction: :shortfall},
        "core" => %{direction: :agrees}
      }
    }
  end

  defp samples(count, opts \\ []), do: Enum.map(0..(count - 1), &sample_at(&1, nil, opts))

  defp sample_at(index, callers, opts) do
    callers = callers || @graphql_callers
    attributed = callers |> Map.values() |> Enum.reduce(0, fn {points, _calls}, acc -> acc + points end)
    spend = Keyword.get(opts, :spend, :default)
    spend = if spend == :default, do: 5_000, else: spend

    %{
      t_ms: DateTime.to_unix(DateTime.add(@now, index * 30, :second), :millisecond),
      budgets: %{
        "graphql" => %{
          resource: "graphql",
          callers:
            Enum.map(callers, fn {caller, {points, calls}} ->
              %{caller: caller, points: points, calls: calls, points_per_hour: 1.0, estimated?: false}
            end),
          attributed: attributed,
          spend: spend,
          outside: if(is_integer(spend), do: max(spend - attributed, 0)),
          direction: :shortfall,
          estimated?: false,
          observed_from: Keyword.get(opts, :observing_since, DateTime.add(window_opened_at(), -600, :second)),
          window_started_at: window_opened_at(),
          window: %{limit: 5_000, remaining: 0, used: 5_000, reset_at: @reset}
        }
      }
    }
  end
end
