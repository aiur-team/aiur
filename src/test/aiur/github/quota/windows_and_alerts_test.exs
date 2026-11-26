defmodule Aiur.GitHub.Quota.WindowsAndAlertsTest do
  use Aiur.TestSupport

  import Aiur.GitHub.QuotaTestSupport

  alias Aiur.GitHub.{Budget, Quota}

  @now ~U[2026-08-09 21:00:00Z]
  @reset ~U[2026-08-09 22:00:00Z]

  test "strict snapshots surface an unavailable meter" do
    assert catch_exit(Quota.snapshot!(:aiur_github_quota_not_running))
  end

  test "meter alerts once when its last quota sample is older than ten minutes and rearms on a new sample" do
    parent = self()
    clock = start_supervised!({Agent, fn -> @now end})

    quota =
      start_quota(
        clock: fn -> Agent.get(clock, & &1) end,
        freshness_check_interval_ms: 10,
        emit_fun: fn name, opts ->
          send(parent, {:alert, name, opts})
          :ok
        end
      )

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 3750))
    assert eventually(fn -> Quota.snapshot(quota).state == :observed end)
    Agent.update(clock, &DateTime.add(&1, 601, :second))
    send(quota, :check_sample_freshness)
    assert_receive {:alert, "system.github.quota.sample_stale", opts}, 1000
    assert opts[:needs_attention]
    assert opts[:reason] =~ "2026-08-09T21:00:00Z"
    refute_receive {:alert, "system.github.quota.sample_stale", _}, 50

    send(quota, {:quota_sampled, DateTime.add(@now, 601, :second)})
    assert_receive {:alert, "system.github.quota.sample_stale.resolved", clear_opts}, 1000
    refute clear_opts[:needs_attention]
    Agent.update(clock, &DateTime.add(&1, 1_202, :second))
    send(quota, :check_sample_freshness)
    assert_receive {:alert, "system.github.quota.sample_stale", next_opts}, 1000
    assert next_opts[:reason] =~ "2026-08-09T21:10:01Z"
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

  test "interleaved credentials retain separate windows while the primary meter stays pinned" do
    quota = start_quota()
    agent_key = Budget.token_key("secret")
    operator_key = Budget.token_key("operator-secret")

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 22))

    operator_request =
      request(:get, "/repos/owner/repo/issues")
      |> Map.put(:token, "operator-secret")
      |> Map.put(:credential_id, "ci_readiness")
      |> Map.put(:credential_key, operator_key)

    Quota.observe(quota, operator_request, response("core", 5000, 4900))

    unkeyed_operator_request =
      request(:get, "/repos/owner/repo/issues")
      |> Map.put(:credential_id, "ci_readiness")
      |> Map.delete(:credential_key)

    Quota.observe(quota, unkeyed_operator_request, response("core", 5000, 4800))

    snapshot = Quota.snapshot(quota)

    assert snapshot.windows["core"].remaining == 22
    assert snapshot.credential_windows[agent_key]["core"].remaining == 22
    assert snapshot.credential_windows[operator_key]["core"].remaining == 4900
    refute Map.has_key?(snapshot.windows, "core:ci_readiness")
    assert {:hold, %{remaining: 22}} = Quota.dispatch_status(quota)

    healthy_agent_quota =
      start_supervised!(
        {Quota, name: nil, clock: fn -> @now end, hold_dir: nil, request_log_path: nil},
        id: :healthy_agent_quota
      )

    Quota.observe(healthy_agent_quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 4159))
    Quota.observe(healthy_agent_quota, operator_request, response("core", 5000, 22))
    assert Quota.dispatch_status(healthy_agent_quota) == :available
  end

  test "unkeyed non-primary observations do not replace the primary window" do
    quota = start_quota()
    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 4159))

    request =
      request(:get, "/repos/owner/repo/issues")
      |> Map.put(:credential_id, "ci_readiness")
      |> Map.delete(:credential_key)

    Quota.observe(quota, request, response("core", 5000, 4900))

    assert Quota.snapshot(quota).windows["core"].remaining == 4159
  end

  test "untagged credential responses cannot replace the primary window" do
    quota = start_quota()
    operator_key = Budget.token_key("operator-secret")
    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 3248))

    unregistered_request = %{
      method: :get,
      url: "https://api.github.com/repos/owner/repo/issues",
      token: "operator-secret"
    }

    Quota.observe(quota, unregistered_request, response("core", 5000, 4548))

    snapshot = Quota.snapshot(quota)
    assert snapshot.windows["core"].remaining == 3248
    assert snapshot.credential_windows[operator_key]["core"].remaining == 4548
  end

  test "issue dependency endpoint buckets stay separate from primary core" do
    quota = start_quota()
    primary_request = request(:get, "/repos/owner/repo/issues")
    dependency_request = %{primary_request | url: "https://api.github.com/repos/owner/repo/issues/42/dependencies/blocked_by"}
    sub_issue_request = %{primary_request | url: "https://api.github.com/repos/owner/repo/issues/42/sub_issues"}
    dependency_reset = DateTime.add(@now, 15 * 60, :second)
    sub_issue_reset = DateTime.add(@now, 20 * 60, :second)

    Quota.observe(quota, primary_request, response("core", 5000, 2766))
    Quota.observe(quota, dependency_request, response("core", 5000, 4514, dependency_reset))
    Quota.observe(quota, sub_issue_request, response("core", 5000, 4498, sub_issue_reset))

    snapshot = Quota.snapshot(quota)
    assert snapshot.windows["core"].remaining == 2766
    assert snapshot.credential_windows[Budget.token_key("secret")]["core"].remaining == 2766
    assert snapshot.credential_windows[Budget.token_key("secret")]["core:issue_dependencies"].remaining == 4514
    assert snapshot.credential_windows[Budget.token_key("secret")]["core:sub_issues"].remaining == 4498
    refute Map.has_key?(snapshot.windows, "core:issue_dependencies")
    refute Map.has_key?(snapshot.windows, "core:sub_issues")
    assert Quota.dispatch_status(quota) == :available
  end

  test "expired credential windows are pruned before another observation is stored" do
    quota = start_quota()
    key = Budget.token_key("old-operator-token")
    old_request = request(:get, "/repos/owner/repo/issues") |> Map.put(:credential_id, "ci_readiness") |> Map.put(:credential_key, key)
    Quota.observe(quota, old_request, response("core", 5000, 4900, DateTime.add(@now, -1, :second)))
    Quota.snapshot(quota)

    new_request = %{old_request | credential_key: Budget.token_key("new-operator-token")}
    Quota.observe(quota, new_request, response("core", 5000, 4800))

    snapshot = Quota.snapshot(quota)
    refute Map.has_key?(snapshot.credential_windows, key)
    assert map_size(snapshot.credential_windows) == 1

    quota_state = :sys.get_state(quota)
    refute Map.has_key?(quota_state.credential_windows, {key, "core"})
    assert map_size(quota_state.credential_windows) == 1
  end

  test "rotating tokens with one credential id reuse one quota window" do
    quota = start_quota()
    reset = DateTime.add(@now, 3600, :second)

    Enum.each(1..200, fn number ->
      request =
        request(:get, "/repos/owner/repo/issues")
        |> Map.put(:token, "rotating-jwt-#{number}")
        |> Map.put(:credential_id, "github_app")
        |> Map.delete(:credential_key)

      Quota.observe(quota, request, response("core", 5000, 5000 - number, reset))
    end)

    snapshot = Quota.snapshot(quota)
    key = Budget.identity_key("github-credential:github_app")
    assert map_size(snapshot.credential_windows) == 1
    assert snapshot.credential_windows[key]["core"].remaining == 4800
    refute Map.has_key?(snapshot.windows, "core")
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

  test "REST rate_limit body does not replace the GraphQL window" do
    quota = start_quota()

    Quota.observe(quota, graphql_request("query A { viewer { login } }", %{}), reported_graphql_response(4603))

    rate_limit_body = %{
      "resources" => %{
        "core" => %{"limit" => 5000, "remaining" => 2766, "reset" => DateTime.to_unix(@reset)},
        "graphql" => %{"limit" => 5000, "remaining" => 4952, "reset" => DateTime.to_unix(@reset)}
      }
    }

    Quota.observe(quota, request(:get, "/rate_limit"), {:ok, %{status: 200, headers: [], body: rate_limit_body}})

    snapshot = Quota.snapshot(quota)
    assert snapshot.windows["core"].remaining == 2766
    assert snapshot.windows["graphql"].remaining == 4603
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
