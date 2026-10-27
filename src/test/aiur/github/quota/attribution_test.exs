defmodule Aiur.GitHub.Quota.AttributionTest do
  use Aiur.TestSupport

  import Aiur.GitHub.QuotaTestSupport

  alias Aiur.GitHub.Quota

  @now ~U[2026-08-09 21:00:00Z]
  @reset ~U[2026-08-09 22:00:00Z]

  test "attributes rolling reads and writes to ticket-shaped requests without inventing unknown ownership" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 4999))
    Quota.observe(quota, request(:patch, "/repos/owner/repo/issues/1670"), response("core", 5000, 4998))
    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 4997))
    Quota.observe(quota, graphql_request("mutation AddLabel { addLabelsToLabelable(input: {}) { clientMutationId } }", %{"number" => 1671}), response("graphql", 5000, 4999))

    assert [
             %{consumer: "ticket:1670", reads: 1, writes: 1, total: 2},
             %{consumer: "ticket:1671", reads: 0, writes: 1, total: 1},
             %{consumer: "unattributed", reads: 1, writes: 0, total: 1}
           ] = drop_cost_fields(Quota.snapshot(quota).attribution)
  end

  # The bug this fixes: 5,000 GraphQL points were spent and the panel named a
  # leader with "2 requests". GraphQL bills points, so a catalog query costing
  # 26 outranks twenty-six one-point reads even though it is one call.
  test "ranks GraphQL consumers by the points the response reported, not by call count" do
    quota = start_quota()

    # Ten cheap reads: the loudest caller by request count.
    Enum.each(1..10, fn _call ->
      Quota.observe(quota, graphql_request("query Cheap { repository { id } }", %{"number" => 1670}), graphql_response(4999, 1))
    end)

    # One catalog query: a tenth of the calls, and the one actually burning the
    # budget. Cost 26 versus cost 1 is the measured figure from #1766.
    Quota.observe(quota, graphql_request("query Catalog { repository { issues { nodes { id } } } }", %{"number" => 1790}), graphql_response(4973, 26))

    assert [heaviest, loudest] = Quota.snapshot(quota).attribution

    assert heaviest.consumer == "ticket:1790"
    assert heaviest.cost == 26
    assert heaviest.total == 1
    assert heaviest.costs == %{"graphql" => 26}

    # A request-count ranking would have named this one instead.
    assert loudest.consumer == "ticket:1670"
    assert loudest.cost == 10
    assert loudest.total == 10
  end

  test "a GraphQL query that does not report its cost is counted as one point and marked estimated" do
    quota = start_quota()

    Quota.observe(quota, graphql_request("query Silent { repository { id } }", %{"number" => 1670}), response("graphql", 5000, 4974))

    assert [%{consumer: "ticket:1670", cost: 1, estimated?: true}] = Quota.snapshot(quota).attribution
    assert Quota.snapshot(quota).coverage.estimated?
  end

  test "transport errors still attribute estimated GraphQL spend" do
    quota = start_quota()

    Quota.observe(quota, graphql_request("query TimedOut { repository { id } }", %{"number" => 1670}), {:error, :fetch_deadline_exceeded})
    Quota.observe(quota, graphql_request("query Exited { repository { id } }", %{"number" => 1671}), {:error, {:github_request_task_exit, :timeout}})

    assert [
             %{consumer: "ticket:1670", total: 1, cost: 1, estimated?: true},
             %{consumer: "ticket:1671", total: 1, cost: 1, estimated?: true}
           ] = Quota.snapshot(quota).attribution
  end

  test "a Core transport error retains the API's fixed one-request charge" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), {:error, :fetch_deadline_exceeded})

    assert [%{consumer: "ticket:1670", total: 1, cost: 1, estimated?: false}] = Quota.snapshot(quota).attribution
  end

  test "a 502 without a reported GraphQL cost is visibly estimated" do
    quota = start_quota()

    Quota.observe(
      quota,
      graphql_request("query FailedGateway { repository { id } }", %{"number" => 1670}),
      {:ok, %{status: 502, headers: [], body: %{"message" => "Bad Gateway"}}}
    )

    assert [%{consumer: "ticket:1670", cost: 1, estimated?: true}] = Quota.snapshot(quota).attribution
  end

  test "a 200 GraphQL errors body without rateLimit is visibly estimated" do
    quota = start_quota()

    Quota.observe(
      quota,
      graphql_request("query Rejected { repository { id } }", %{"number" => 1670}),
      {:ok, %{status: 200, headers: [], body: %{"data" => nil, "errors" => [%{"message" => "rejected"}]}}}
    )

    assert [%{consumer: "ticket:1670", cost: 1, estimated?: true}] = Quota.snapshot(quota).attribution
  end

  test "preserves process-scoped view attribution in the caller summary" do
    quota = start_quota()
    {:label, previous_label} = Process.info(self(), :label)
    Process.set_label({Phoenix.LiveView, AiurWeb.DashboardLive, "lv:test"})

    try do
      Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 4999))
      Quota.observe(quota, request(:patch, "/repos/owner/repo/issues/1670"), response("core", 5000, 4997))
    after
      Process.set_label(previous_label)
    end

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 4998))

    callers = Quota.snapshot(quota).callers

    assert %{calls: 2, view_calls: 1} = Enum.find(callers, &(&1.caller == "rest:GET /repos/owner/repo/issues/:n"))
    assert %{calls: 1, view_calls: 1} = Enum.find(callers, &(&1.caller == "rest:PATCH /repos/owner/repo/issues/:n"))
  end

  # A conditional request answered `304` is served from GitHub's cache and is
  # never billed, so attributing a point to it invents spend that never
  # happened and inflates the coverage figure operators rely on.
  test "a not-modified response costs nothing" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), not_modified("core", 4999))

    assert [%{consumer: "ticket:1670", total: 1, cost: 0}] = Quota.snapshot(quota).attribution
  end

  # The panel must never present a leader as though it were the whole picture.
  # With 5,000 points spent and two calls seen, the honest report is that the
  # ranking accounts for a fraction of a percent.
  #
  # Per budget, and only per budget: core bills requests and GraphQL bills
  # points, on windows that reset at different times. A combined denominator
  # (5,100 "spent this window") names a quantity and a window that do not
  # exist, which is the defect #1805 reported, committed by the figure that
  # claims to quantify honesty.
  test "reports the share of each budget's real spend the ranking accounts for" do
    quota = start_quota()

    Quota.observe(quota, graphql_request("query Catalog { repository { id } }", %{"number" => 1790}), graphql_response(0, 26))
    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 4900))

    coverage = Quota.snapshot(quota).coverage

    # GitHub billed 5,000 GraphQL points this window; 26 of them are named.
    assert coverage.resources["graphql"] == %{
             attributed: 26,
             named: 26,
             spend: 5000,
             fraction: Float.round(26 / 5000, 4),
             named_fraction: Float.round(26 / 5000, 4),
             estimated?: false
           }

    # And 100 core requests, of which the one Aiur saw could not be named.
    assert coverage.resources["core"] == %{
             attributed: 1,
             named: 0,
             spend: 100,
             fraction: Float.round(1 / 100, 4),
             named_fraction: 0.0,
             estimated?: false
           }

    # There is no combined figure to render by accident.
    refute Map.has_key?(coverage, :spend)
    refute Map.has_key?(coverage, :fraction)
    refute Map.has_key?(coverage, :named_fraction)
  end

  test "coverage is unavailable rather than fabricated before any window is observed" do
    quota = start_quota()

    assert Quota.snapshot(quota).coverage.resources == %{}
  end

  # A window whose reset has passed is not the live window: attribution has
  # already fallen back to the rolling hour, so pairing it with the expired
  # window's `used` would state a coverage figure "this window" for a window
  # that closed, over calls that window never contained.
  test "reports no coverage for a budget whose window has already reset" do
    {:ok, clock} = Agent.start_link(fn -> @now end)
    quota = start_quota(clock: fn -> Agent.get(clock, & &1) end)

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 4000))

    assert %{"core" => %{spend: 1000, named: 1}} = Quota.snapshot(quota).coverage.resources

    # Past the reset, with no fresh reading from GitHub.
    Agent.update(clock, fn _ -> DateTime.add(@reset, 1, :minute) end)

    assert Quota.snapshot(quota).coverage.resources == %{}
  end

  # Attribution used to summarize a rolling hour while the meter beside it
  # counted a window that resets on GitHub's schedule, so the two spans never
  # described the same calls.
  test "attribution covers the live quota window, not a rolling hour" do
    {:ok, clock} = Agent.start_link(fn -> DateTime.add(@reset, -90, :minute) end)
    quota = start_quota(clock: fn -> Agent.get(clock, & &1) end)

    # Spent 90 minutes before the reset: inside the rolling hour when it
    # happened, but in the window before the one the meter now reports.
    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 4999))
    # `observe` is a cast; settle it before the clock moves so the observation
    # is stamped in the window it was made in.
    _settled = Quota.snapshot(quota)

    Agent.update(clock, fn _ -> DateTime.add(@reset, -50, :minute) end)
    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1790"), response("core", 5000, 4000))

    assert [%{consumer: "ticket:1790"}] = Quota.snapshot(quota).attribution
  end
end
