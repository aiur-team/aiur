defmodule Aiur.GitHub.Quota.WindowsAndAlertsTest do
  use Aiur.TestSupport

  import Aiur.GitHub.QuotaTestSupport

  alias Aiur.GitHub.Quota

  @now ~U[2026-08-09 21:00:00Z]
  @reset ~U[2026-08-09 22:00:00Z]

  test "strict snapshots surface an unavailable meter" do
    assert catch_exit(Quota.snapshot!(:aiur_github_quota_not_running))
  end

  test "projects rate-limit headers into exact core and GraphQL windows" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 3750))
    Quota.observe(quota, graphql_request("query Ticket($number: Int!) { repository { issue(number: $number) { id } } }", %{"number" => 1670}), response("graphql", 5000, 4400))

    snapshot = Quota.snapshot(quota)

    assert snapshot.state == :observed

    assert snapshot.windows["core"] == %{
             resource: "core",
             limit: 5000,
             remaining: 3750,
             remaining_percent: 75.0,
             used: 1250,
             used_percent: 25.0,
             reset_at: @reset,
             observed_at: @now,
             # The window's own span, not just its end. A consumer needs both to
             # tell "another consumer spent this" from "I was not running yet".
             started_at: DateTime.add(@reset, -3600, :second)
           }

    assert snapshot.windows["graphql"].remaining == 4400
    assert snapshot.windows["graphql"].used_percent == 12.0
  end

  # Every instrumented GraphQL response already carries the endpoint's own
  # answer for the points budget. Reading it is what lets the daemon learn its
  # real remaining budget from the calls it is already making, rather than
  # waiting for the next `/rate_limit` refresh to discover it is out.
  test "learns the GraphQL window from the rateLimit block a response reports" do
    quota = start_quota()

    Quota.observe(quota, graphql_request("query A { viewer { login } }", %{}), reported_graphql_response(1234))

    snapshot = Quota.snapshot(quota)

    assert snapshot.windows["graphql"].limit == 5000
    assert snapshot.windows["graphql"].remaining == 1234
    assert snapshot.windows["graphql"].reset_at == @reset
  end

  test "the reported block wins over the headers, being the endpoint's own answer" do
    quota = start_quota()

    {:ok, headers_only} = response("graphql", 5000, 4400)
    reported = put_in(headers_only.body, %{"data" => rate_limit_block(77)})

    Quota.observe(quota, graphql_request("query A { viewer { login } }", %{}), {:ok, reported})

    assert Quota.snapshot(quota).windows["graphql"].remaining == 77
  end

  test "a GraphQL response without a reported block still falls back to its headers" do
    quota = start_quota()

    Quota.observe(quota, graphql_request("query A { viewer { login } }", %{}), response("graphql", 5000, 4400))

    assert Quota.snapshot(quota).windows["graphql"].remaining == 4400
  end

  test "the snapshot states how far back the meter can see" do
    # Attribution lives in this process and dies with it, while GitHub keeps
    # counting across a restart. Without this figure a consumer cannot tell
    # "nobody else spent it" from "I was not running when it was spent", and
    # would blame the daemon's own forgotten calls on somebody else.
    booted_mid_window = start_quota(started_at: DateTime.add(@reset, -1800, :second))
    Quota.observe(booted_mid_window, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 3750))
    snapshot = Quota.snapshot(booted_mid_window)

    assert snapshot.observing_since == DateTime.add(@reset, -1800, :second)
    assert DateTime.compare(snapshot.observing_since, snapshot.windows["core"].started_at) == :gt
  end

  test "a meter cannot claim to see further back than the rolling attribution window" do
    # A long-lived daemon still only retains an hour of observations, so its
    # reach is bounded by the rolling window rather than by its uptime.
    long_lived = start_quota(started_at: DateTime.add(@now, -86_400, :second))
    Quota.observe(long_lived, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 3750))
    snapshot = Quota.snapshot(long_lived)

    assert snapshot.observing_since == DateTime.add(@now, -3600, :second)
  end

  test "the low-water crossing alerts once per resource window and names the reset" do
    parent = self()

    quota =
      start_quota(
        emit_fun: fn name, opts ->
          send(parent, {:alert, name, opts})
          :ok
        end
      )

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 500))
    _snapshot = Quota.snapshot(quota)

    assert_receive {:alert, "system.github.quota.core.low", opts}, 1000
    assert opts[:needs_attention]
    assert opts[:reason] =~ "500 of 5000"
    assert opts[:reason] =~ "2026-08-09T22:00:00Z"

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 499))
    _snapshot = Quota.snapshot(quota)
    refute_receive {:alert, "system.github.quota.core.low", _opts}, 100
  end

  test "resolves a quota attention after the resource recovers" do
    parent = self()

    quota =
      start_quota(
        emit_fun: fn name, opts ->
          send(parent, {:alert, name, opts})
          :ok
        end
      )

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 500))
    _snapshot = Quota.snapshot(quota)
    assert_receive {:alert, "system.github.quota.core.low", _opts}, 1000

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 501))
    _snapshot = Quota.snapshot(quota)

    assert_receive {:alert, "system.github.quota.core.low.resolved", opts}, 1000
    refute opts[:needs_attention]
  end

  test "a window rollover with the resource still exhausted does not report the alert cleared" do
    parent = self()

    quota =
      start_quota(
        emit_fun: fn name, opts ->
          send(parent, {:alert, name, opts})
          :ok
        end
      )

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 0))
    _snapshot = Quota.snapshot(quota)
    assert_receive {:alert, "system.github.quota.core.exhausted", _opts}, 1000

    # Ten poll cycles across three successive windows, exhausted throughout.
    # The reset moving is the window rolling over, not the condition clearing.
    Enum.each(1..10, fn cycle ->
      reset = DateTime.add(@reset, cycle * 600, :second)
      Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 0, reset))
      _snapshot = Quota.snapshot(quota)
    end)

    refute_receive {:alert, "system.github.quota.core.exhausted.resolved", _opts}, 100
    refute_receive {:alert, "system.github.quota.core.exhausted", _opts}, 100

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 4905))
    _snapshot = Quota.snapshot(quota)

    assert_receive {:alert, "system.github.quota.core.exhausted.resolved", opts}, 1000
    assert opts[:reason] =~ "4905 of 5000"

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 4906))
    _snapshot = Quota.snapshot(quota)
    refute_receive {:alert, "system.github.quota.core.exhausted.resolved", _opts}, 100
  end

  test "exhaustion blocks only the depleted resource until its reset" do
    {:ok, clock} = Agent.start_link(fn -> @now end)
    quota = start_quota(clock: fn -> Agent.get(clock, & &1) end)

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 0))
    _snapshot = Quota.snapshot(quota)

    assert {:hold, hold} = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
    assert hold.resource == "core"
    assert hold.reset_at == @reset
    assert :ok = Quota.preflight(quota, graphql_request("query { viewer { login } }", %{}))
    assert :ok = Quota.preflight(quota, request(:get, "/rate_limit"))

    Agent.update(clock, fn _ -> DateTime.add(@reset, 1, :second) end)
    assert :ok = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
  end

  test "new dispatch is held at the ten-percent floor and fails open before observation" do
    quota = start_quota()

    assert Quota.dispatch_status(quota) == :available

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 501))
    assert Quota.dispatch_status(quota) == :available

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 500))

    assert {:hold, %{resource: "core", remaining: 500, limit: 5000, reset_at: @reset}} =
             Quota.dispatch_status(quota)
  end
end
