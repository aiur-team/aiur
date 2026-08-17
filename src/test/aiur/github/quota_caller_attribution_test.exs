defmodule Aiur.GitHub.QuotaCallerAttributionTest do
  @moduledoc """
  U8: the budget breakdown must be a measurement, not an inference.

  The daemon burned a fresh 5,000 GraphQL points in about 20 minutes while
  making 192 REST calls, and the first confident answer to "who spent it" was
  wrong. These tests assert the two properties that make the replacement
  trustworthy: costs come from GitHub's own `rateLimit { cost }` rather than
  from an assumption, and the per-caller rows add up to what the credential's
  own window says was spent.
  """

  use Aiur.TestSupport

  alias Aiur.GitHub.Quota

  @now ~U[2026-08-09 21:30:00Z]
  @reset ~U[2026-08-09 22:00:00Z]

  test "ranks callers by points, not by call count" do
    quota = start_quota()

    # One expensive catalog read against twenty cheap viewer lookups. A
    # request-count ranking puts the viewer first and is blind to the query
    # that actually drains the budget.
    observe(quota, "build_order_catalog", 104, 4896)

    for index <- 1..20 do
      observe(quota, "bot_identity", 1, 4895 - index)
    end

    assert [top, second | _rest] = graphql_callers(Quota.snapshot(quota))

    assert top.caller == "build_order_catalog"
    assert top.points == 104
    assert top.calls == 1

    assert second.caller == "bot_identity"
    assert second.points == 20
    assert second.calls == 20
  end

  test "reports points per hour against the elapsed part of the window" do
    quota = start_quota()

    # Half an hour into the window, so 100 points so far is a 200/hour rate.
    # Dividing by a whole hour instead would report 100 and understate a
    # caller by half exactly where the number matters.
    observe(quota, "comment_poll_batch", 100, 4900)

    [caller] = graphql_callers(Quota.snapshot(quota))

    assert caller.elapsed_seconds == 1800
    assert caller.points_per_hour == 200.0
  end

  test "prices a query that reported its cost as reported, not assumed" do
    quota = start_quota()

    observe(quota, "review_threads_unaddressed", 26, 4974)

    [caller] = graphql_callers(Quota.snapshot(quota))

    assert caller.points == 26
    refute caller.estimated?
  end

  test "marks a query that did not report a cost as estimated" do
    quota = start_quota()

    # An uninstrumented query is counted at one point. That understates it, so
    # the row says so rather than flattering the ranking.
    Quota.observe(quota, unpriced_graphql_request("legacy_caller"), graphql_response(nil, 4999))
    [caller] = graphql_callers(Quota.snapshot(quota))

    assert caller.points == 1
    assert caller.estimated?
  end

  test "treats a nonsense reported cost as unpriced rather than believing it" do
    quota = start_quota()

    # A negative cost would subtract from the total the reconciliation checks
    # against, turning a broken reading into an apparently tighter breakdown.
    Quota.observe(quota, graphql_request("hostile_caller"), graphql_response(-500, 4999))

    [caller] = graphql_callers(Quota.snapshot(quota))

    assert caller.points == 1
    assert caller.estimated?
  end

  test "the breakdown reconciles with the window's own used figure" do
    quota = start_quota()

    # `used` is `limit - remaining` on the credential's own window: 5000 - 4870
    # = 130, which is exactly what the three rows below add up to.
    observe(quota, "build_order_catalog", 104, 4896)
    observe(quota, "comment_poll_batch", 20, 4876)
    observe(quota, "bot_identity", 6, 4870)

    snapshot = Quota.snapshot(quota)
    graphql = snapshot.reconciliation["graphql"]

    assert snapshot.windows["graphql"].used == 130
    assert graphql.attributed == 130
    assert graphql.spend == 130
    assert graphql.delta == 0
    assert graphql.reconciled?

    # And the ranking itself sums to the same figure, so the table an operator
    # reads is the table that reconciles.
    assert snapshot |> graphql_callers() |> Enum.map(& &1.points) |> Enum.sum() == 130
  end

  test "a breakdown that does not add up says so instead of claiming coverage" do
    quota = start_quota()

    # 5000 - 4000 = 1000 points spent on this credential, of which Aiur saw 20.
    # Calls made outside this process are real spend, and a ranking that
    # silently presented 2% of the window as the whole story would be exactly
    # the confidently-wrong answer this unit exists to prevent.
    observe(quota, "comment_poll_batch", 20, 4000)

    graphql = Quota.snapshot(quota).reconciliation["graphql"]

    assert graphql.attributed == 20
    assert graphql.spend == 1000
    assert graphql.delta == -980
    refute graphql.reconciled?

    # A shortfall is unmeasured spend, not a defect. An excess would be a double
    # count, and collapsing the two loses the only one worth alarming on.
    assert graphql.direction == :shortfall
  end

  test "distinguishes a double count from unmeasured spend" do
    quota = start_quota()

    # Two responses that each report 300 points against a window claiming only
    # 100 were spent: points cannot be billed twice, so this is an accounting bug.
    observe(quota, "comment_poll_batch", 300, 4950)
    observe(quota, "comment_poll_batch", 300, 4900)

    graphql = Quota.snapshot(quota).reconciliation["graphql"]

    assert graphql.attributed == 600
    assert graphql.spend == 100
    assert graphql.direction == :excess
    refute graphql.reconciled?
  end

  test "declines a per-hour rate it has too little window to extrapolate from" do
    # One second into a window, one point extrapolates to 3,600/hour. That figure
    # is printed against the 5,000/hour ceiling, so an artefact there would rank a
    # trivial call above the real leader.
    # The window opened an hour before its reset, so this clock sits one second in.
    quota = start_quota(clock: fn -> DateTime.add(@reset, -3599, :second) end)

    observe(quota, "bot_identity", 1, 4999)

    [caller] = graphql_callers(Quota.snapshot(quota))

    assert caller.points == 1
    assert caller.points_per_hour == nil
  end

  test "never carries the request token into the snapshot" do
    quota = start_quota()

    observe(quota, "comment_poll_batch", 10, 4990)

    refute inspect(Quota.snapshot(quota)) =~ "secret"
  end

  test "an unobserved budget reports no reconciliation rather than a zero" do
    quota = start_quota()

    snapshot = Quota.snapshot(quota)

    assert snapshot.reconciliation == %{}
    assert snapshot.callers == []
  end

  test "keeps the caller and the consumer as separate dimensions" do
    quota = start_quota()

    # A batch query names many tickets and belongs to one poller. Both readings
    # stay available: "which ticket is expensive" and "which code path is
    # expensive" are different questions and the second is the one #2084 asks.
    Quota.observe(
      quota,
      %{
        method: :post,
        url: "https://api.github.com/graphql",
        token: "secret",
        caller: "comment_poll_batch",
        body: %{"query" => "query B { x }", "variables" => %{"number" => 2073}}
      },
      graphql_response(40, 4960)
    )

    snapshot = Quota.snapshot(quota)

    assert [%{caller: "comment_poll_batch", points: 40}] = graphql_callers(snapshot)
    assert [%{consumer: "ticket:2073", cost: 40}] = snapshot.attribution
  end

  defp graphql_callers(snapshot), do: Enum.filter(snapshot.callers, &(&1.resource == "graphql"))

  defp observe(quota, caller, cost, remaining) do
    Quota.observe(quota, graphql_request(caller), graphql_response(cost, remaining))
  end

  defp graphql_request(caller) do
    %{
      method: :post,
      url: "https://api.github.com/graphql",
      token: "secret",
      caller: caller,
      body: %{"query" => "query A { rateLimit { cost } x }", "variables" => %{}}
    }
  end

  defp unpriced_graphql_request(caller) do
    %{
      method: :post,
      url: "https://api.github.com/graphql",
      token: "secret",
      caller: caller,
      body: %{"query" => "query A { x }", "variables" => %{}}
    }
  end

  defp graphql_response(cost, remaining) do
    data = if is_integer(cost), do: %{"rateLimit" => %{"cost" => cost, "remaining" => remaining}}, else: %{}

    {:ok,
     %{
       status: 200,
       headers: [
         {"x-ratelimit-resource", "graphql"},
         {"x-ratelimit-limit", "5000"},
         {"x-ratelimit-remaining", Integer.to_string(remaining)},
         {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(@reset))}
       ],
       body: %{"data" => data}
     }}
  end

  defp start_quota(opts \\ []) do
    start_supervised!({Quota, Keyword.merge([name: nil, clock: fn -> @now end, hold_dir: nil], opts)})
  end
end
