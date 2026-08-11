defmodule Aiur.GitHub.QuotaTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Quota

  @now ~U[2026-08-09 21:00:00Z]
  @reset ~U[2026-08-09 22:00:00Z]

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
             observed_at: @now
           }

    assert snapshot.windows["graphql"].remaining == 4400
    assert snapshot.windows["graphql"].used_percent == 12.0
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

    assert_receive {:alert, "system.github.quota.core.low", opts}
    assert opts[:needs_attention]
    assert opts[:reason] =~ "500 of 5000"
    assert opts[:reason] =~ "2026-08-09T22:00:00Z"

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 499))
    _snapshot = Quota.snapshot(quota)
    refute_receive {:alert, "system.github.quota.core.low", _opts}
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
    assert_receive {:alert, "system.github.quota.core.low", _opts}

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 501))
    _snapshot = Quota.snapshot(quota)

    assert_receive {:alert, "system.github.quota.core.low.resolved", opts}
    refute opts[:needs_attention]
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

  test "attributes rolling reads and writes to ticket-shaped requests without inventing unknown ownership" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 4999))
    Quota.observe(quota, request(:patch, "/repos/owner/repo/issues/1670"), response("core", 5000, 4998))
    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 4997))
    Quota.observe(quota, graphql_request("mutation AddLabel { addLabelsToLabelable(input: {}) { clientMutationId } }", %{"number" => 1671}), response("graphql", 5000, 4999))

    snapshot = Quota.snapshot(quota)

    assert snapshot.attribution == [
             %{consumer: "ticket:1670", resource: "core", reads: 1, writes: 1, requests: 2, points: 2},
             %{consumer: "unattributed", resource: "core", reads: 1, writes: 0, requests: 1, points: 1}
           ]

    assert snapshot.coverage["core"] == %{attributed_points: 2, spent_points: 3, percent: 66.7}
  end

  test "attributes GraphQL points inside the authoritative reset window and ranks the heavy consumer" do
    quota = start_quota()

    Quota.observe(
      quota,
      graphql_request("query AiurCommentPollBatch { viewer { login } rateLimit { cost } }", %{}),
      graphql_response(5000, 4974, 26)
    )

    Quota.observe(
      quota,
      Map.put(graphql_request("query Light { viewer { login } rateLimit { cost } }", %{}), :consumer, "ticket:light"),
      graphql_response(5000, 4973, 1)
    )

    snapshot = Quota.snapshot(quota)

    assert snapshot.attribution == [
             %{consumer: "github:AiurCommentPollBatch", resource: "graphql", reads: 1, writes: 0, requests: 1, points: 26},
             %{consumer: "ticket:light", resource: "graphql", reads: 1, writes: 0, requests: 1, points: 1}
           ]

    assert snapshot.coverage["graphql"] == %{attributed_points: 27, spent_points: 27, percent: 100.0}
  end

  test "reports partial GraphQL coverage instead of treating an uncosted request as one point" do
    quota = start_quota()

    Quota.observe(
      quota,
      Map.put(graphql_request("query Uncosted { viewer { login } }", %{}), :consumer, "ticket:unknown-cost"),
      response("graphql", 5000, 4974)
    )

    snapshot = Quota.snapshot(quota)

    assert snapshot.attribution == []
    assert snapshot.coverage["graphql"] == %{attributed_points: 0, spent_points: 26, percent: 0.0}
  end

  test "drops prior attribution when GitHub advances the resource reset window" do
    {:ok, clock} = Agent.start_link(fn -> @now end)
    quota = start_quota(clock: fn -> Agent.get(clock, & &1) end)

    Quota.observe(
      quota,
      Map.put(graphql_request("query OldWindow { viewer { login } rateLimit { cost } }", %{}), :consumer, "ticket:old"),
      graphql_response(5000, 4974, 26)
    )

    next_reset = DateTime.add(@reset, 3600, :second)
    Agent.update(clock, fn _ -> DateTime.add(@reset, 1, :second) end)

    Quota.observe(
      quota,
      Map.put(graphql_request("query NewWindow { viewer { login } rateLimit { cost } }", %{}), :consumer, "ticket:new"),
      graphql_response(5000, 4999, 1, next_reset)
    )

    snapshot = Quota.snapshot(quota)

    assert snapshot.attribution == [
             %{consumer: "ticket:new", resource: "graphql", reads: 1, writes: 0, requests: 1, points: 1}
           ]

    assert snapshot.coverage["graphql"] == %{attributed_points: 1, spent_points: 1, percent: 100.0}
  end

  test "hydrates all primary resources from the rate-limit endpoint body" do
    quota = start_quota()

    body = %{
      "resources" => %{
        "core" => %{"limit" => 5000, "remaining" => 4200, "reset" => DateTime.to_unix(@reset)},
        "graphql" => %{"limit" => 5000, "remaining" => 3900, "reset" => DateTime.to_unix(@reset)},
        "search" => %{"limit" => 30, "remaining" => 29, "reset" => DateTime.to_unix(@reset)}
      }
    }

    Quota.observe(quota, request(:get, "/rate_limit"), {:ok, %{status: 200, headers: [], body: body}})

    snapshot = Quota.snapshot(quota)
    assert Map.keys(snapshot.windows) |> Enum.sort() == ["core", "graphql"]
    assert snapshot.windows["core"].remaining == 4200
    assert snapshot.windows["graphql"].remaining == 3900
  end

  test "includes recent agent-shell attribution and ignores stale or malformed rows" do
    path = Path.join(System.tmp_dir!(), "aiur-gh-quota-#{System.unique_integer([:positive])}.tsv")
    now_unix = DateTime.to_unix(@now)

    File.write!(
      path,
      "#{now_unix}\tticket:1670\tcore\tread\t1\n#{now_unix}\tticket:1671\tgraphql\twrite\t7\n#{now_unix - 3601}\tticket:999\tcore\tread\t1\nmalformed\n"
    )

    on_exit(fn -> File.rm(path) end)
    quota = start_quota(shell_log_path: path)
    Quota.observe(quota, request(:get, "/rate_limit"), rate_limit_response(5000, 4999, 5000, 4993))

    assert Quota.snapshot(quota).attribution == [
             %{consumer: "ticket:1671", resource: "graphql", reads: 0, writes: 1, requests: 1, points: 7},
             %{consumer: "ticket:1670", resource: "core", reads: 1, writes: 0, requests: 1, points: 1}
           ]
  end

  test "publishes and clears resource-specific shell holds" do
    hold_dir = Path.join(System.tmp_dir!(), "aiur-gh-holds-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(hold_dir) end)
    quota = start_quota(hold_dir: hold_dir)

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 0))
    _snapshot = Quota.snapshot(quota)

    assert File.read!(Path.join(hold_dir, "core-hold")) == "#{DateTime.to_unix(@reset)}\n"

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 100))
    _snapshot = Quota.snapshot(quota)
    refute File.exists?(Path.join(hold_dir, "core-hold"))
  end

  # The exact failure observed in the field: `gh` began returning 403 "API rate
  # limit exceeded" while `GET /rate_limit` still reported 4077/5000 core
  # remaining. The primary window is healthy, so nothing held the caller back
  # and every rejected call was retried straight away.
  test "a secondary limit holds the resource even though the primary window reads healthy" do
    {:ok, clock} = Agent.start_link(fn -> @now end)
    quota = start_quota(clock: fn -> Agent.get(clock, & &1) end)

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 4077))
    assert :ok = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), secondary_response("core", 4077, 45))

    assert {:hold, hold} = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
    assert hold.resource == "core"
    assert hold.reset_at == DateTime.add(@now, 45, :second)
    # The backoff is resource-scoped; GraphQL was never refused.
    assert :ok = Quota.preflight(quota, graphql_request("query { viewer { login } }", %{}))

    Agent.update(clock, fn _ -> DateTime.add(@now, 46, :second) end)
    assert :ok = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
  end

  test "a secondary limit alerts, sheds dispatch, publishes a shell hold, and resolves on expiry" do
    parent = self()
    hold_dir = Path.join(System.tmp_dir!(), "aiur-gh-secondary-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(hold_dir) end)
    {:ok, clock} = Agent.start_link(fn -> @now end)

    quota =
      start_quota(
        clock: fn -> Agent.get(clock, & &1) end,
        hold_dir: hold_dir,
        emit_fun: fn name, opts ->
          send(parent, {:alert, name, opts})
          :ok
        end
      )

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), secondary_response("core", 4077, 45))

    assert_receive {:alert, "system.github.quota.core.secondary", opts}
    assert opts[:needs_attention]
    assert opts[:reason] =~ "secondary rate limit"
    assert opts[:reason] =~ DateTime.to_iso8601(DateTime.add(@now, 45, :second))

    # A backoff must shed new dispatch, not merely block in-flight callers.
    assert {:hold, %{resource: "core"}} = Quota.dispatch_status(quota)
    assert File.read!(Path.join(hold_dir, "core-secondary-hold")) == "#{DateTime.to_unix(DateTime.add(@now, 45, :second))}\n"

    assert [%{resource: "core", seconds_remaining: 45}] = Quota.snapshot(quota).backoffs

    Agent.update(clock, fn _ -> DateTime.add(@now, 46, :second) end)
    assert Quota.snapshot(quota).backoffs == []
    assert_receive {:alert, "system.github.quota.core.secondary.resolved", _opts}
    refute File.exists?(Path.join(hold_dir, "core-secondary-hold"))
  end

  test "a secondary limit without Retry-After falls back to a bounded wait and never shortens an active hold" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), secondary_response("core", 4077, nil))

    assert {:hold, %{reset_at: reset_at}} = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
    assert reset_at == DateTime.add(@now, 60, :second)

    # A later, shorter rejection must not pull the deadline back in.
    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), secondary_response("core", 4077, 5))
    assert {:hold, %{reset_at: ^reset_at}} = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
  end

  test "an exhausted-window rejection is left to the window hold rather than double-counted as secondary" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), secondary_response("core", 0, 45))

    assert Quota.snapshot(quota).backoffs == []
    assert {:hold, %{reset_at: @reset}} = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
  end

  # A false positive here would stall every agent for a minute on an ordinary
  # permission error, so the backoff must key off the rate-limit signal alone.
  test "an ordinary 403 permission denial does not back the fleet off" do
    quota = start_quota()

    denial =
      {:ok,
       %{
         status: 403,
         headers: [{"x-ratelimit-resource", "core"}, {"x-ratelimit-limit", "5000"}, {"x-ratelimit-remaining", "4077"}],
         body: %{"message" => "Resource not accessible by integration"}
       }}

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), denial)

    assert Quota.snapshot(quota).backoffs == []
    assert :ok = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
  end

  test "refreshes immediately and schedules the next probe after completion" do
    parent = self()

    _quota =
      start_quota(
        refresh?: true,
        refresh_interval_ms: 10,
        refresh_fun: fn -> send(parent, :refreshed) end
      )

    assert_receive :refreshed, 500
    assert_receive :refreshed, 500
  end

  defp start_quota(opts \\ []) do
    start_supervised!({Quota, Keyword.merge([name: nil, clock: fn -> @now end, hold_dir: nil], opts)})
  end

  defp request(method, path) do
    %{method: method, url: "https://api.github.com#{path}", token: "secret"}
  end

  defp graphql_request(query, variables) do
    %{
      method: :post,
      url: "https://api.github.com/graphql",
      token: "secret",
      body: %{"query" => query, "variables" => variables}
    }
  end

  # GitHub answers a secondary/abuse limit with a 403 whose body carries the
  # rate-limit wording, a still-healthy `x-ratelimit-remaining`, and usually a
  # `Retry-After` in seconds.
  defp secondary_response(resource, remaining, retry_after) do
    headers =
      [
        {"x-ratelimit-resource", resource},
        {"x-ratelimit-limit", "5000"},
        {"x-ratelimit-remaining", Integer.to_string(remaining)},
        {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(@reset))}
      ] ++ if(retry_after, do: [{"retry-after", Integer.to_string(retry_after)}], else: [])

    {:ok,
     %{
       status: 403,
       headers: headers,
       body: %{"message" => "You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}
     }}
  end

  defp response(resource, limit, remaining) do
    {:ok,
     %{
       status: 200,
       headers: [
         {"x-ratelimit-resource", resource},
         {"x-ratelimit-limit", Integer.to_string(limit)},
         {"x-ratelimit-remaining", Integer.to_string(remaining)},
         {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(@reset))}
       ],
       body: %{}
     }}
  end

  defp graphql_response(limit, remaining, cost, reset \\ @reset) do
    {:ok, response} = response("graphql", limit, remaining, reset)
    {:ok, put_in(response, [:body], %{"data" => %{"rateLimit" => %{"cost" => cost}}})}
  end

  defp response(resource, limit, remaining, reset) do
    {:ok,
     %{
       status: 200,
       headers: [
         {"x-ratelimit-resource", resource},
         {"x-ratelimit-limit", Integer.to_string(limit)},
         {"x-ratelimit-remaining", Integer.to_string(remaining)},
         {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(reset))}
       ],
       body: %{}
     }}
  end

  defp rate_limit_response(core_limit, core_remaining, graphql_limit, graphql_remaining) do
    {:ok,
     %{
       status: 200,
       headers: [],
       body: %{
         "resources" => %{
           "core" => %{"limit" => core_limit, "remaining" => core_remaining, "reset" => DateTime.to_unix(@reset)},
           "graphql" => %{"limit" => graphql_limit, "remaining" => graphql_remaining, "reset" => DateTime.to_unix(@reset)}
         }
       }
     }}
  end
end
