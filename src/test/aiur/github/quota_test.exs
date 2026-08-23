defmodule Aiur.GitHub.QuotaTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Quota
  alias Aiur.Workspace.Layout

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
    assert_receive {:alert, "system.github.quota.core.exhausted", _opts}

    # Ten poll cycles across three successive windows, exhausted throughout.
    # The reset moving is the window rolling over, not the condition clearing.
    Enum.each(1..10, fn cycle ->
      reset = DateTime.add(@reset, cycle * 600, :second)
      Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 0, reset))
      _snapshot = Quota.snapshot(quota)
    end)

    refute_receive {:alert, "system.github.quota.core.exhausted.resolved", _opts}
    refute_receive {:alert, "system.github.quota.core.exhausted", _opts}

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 4905))
    _snapshot = Quota.snapshot(quota)

    assert_receive {:alert, "system.github.quota.core.exhausted.resolved", opts}
    assert opts[:reason] =~ "4905 of 5000"

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 4906))
    _snapshot = Quota.snapshot(quota)
    refute_receive {:alert, "system.github.quota.core.exhausted.resolved", _opts}
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
    assert snapshot.attribution == []
  end

  test "includes recent agent-shell attribution and ignores stale or malformed rows" do
    path = Path.join(System.tmp_dir!(), "aiur-gh-quota-#{System.unique_integer([:positive])}.tsv")
    now_unix = DateTime.to_unix(@now)

    File.write!(
      path,
      "#{now_unix}\tticket:1670\tread\tcore\n#{now_unix}\tticket:1671\twrite\tgraphql\n#{now_unix}\tticket:1672\tread\n#{now_unix - 3601}\tticket:999\tread\tcore\nmalformed\n"
    )

    on_exit(fn -> File.rm(path) end)
    quota = start_quota(shell_log_path: path)

    assert [
             %{consumer: "ticket:1670", reads: 1, writes: 0, total: 1, cost: 1, costs: %{"core" => 1}, estimated?: false},
             # An agent shell cannot see what a GraphQL query cost, so its row
             # is one point and says so rather than passing for an exact figure.
             %{consumer: "ticket:1671", reads: 0, writes: 1, total: 1, cost: 1, costs: %{"graphql" => 1}, estimated?: true},
             # Rows written before the resource column are still counted, against core.
             %{consumer: "ticket:1672", reads: 1, writes: 0, total: 1, cost: 1, costs: %{"core" => 1}, estimated?: false}
           ] = Quota.snapshot(quota).attribution
  end

  # The call-site column lets `github-cost` name the agent-side spend by gh
  # subcommand instead of folding the whole fleet into one `agent-shell:gh`
  # row (#2299). A row written before the column existed still parses and keeps
  # the undifferentiated caller. A `search` row keeps its call site too; Aiur
  # does not meter a separate search window, so it counts against core like any
  # other resource the meter does not name.
  test "names agent-shell callers by gh subcommand from the call-site column" do
    path = Path.join(System.tmp_dir!(), "aiur-gh-quota-#{System.unique_integer([:positive])}.tsv")
    now_unix = DateTime.to_unix(@now)

    File.write!(
      path,
      "#{now_unix}\tticket:1670\tread\tgraphql\tpr view\n" <>
        "#{now_unix}\tticket:1671\tread\tgraphql\tissue list\n" <>
        "#{now_unix}\tticket:1672\tread\tcore\tapi\n" <>
        "#{now_unix}\tticket:1673\tread\tcore\n" <>
        "#{now_unix}\tticket:1674\tread\tsearch\tsearch repos\n"
    )

    on_exit(fn -> File.rm(path) end)
    quota = start_quota(shell_log_path: path)

    callers = Quota.snapshot(quota).callers

    # Ranked within budget: core rows first, then graphql, each by caller name.
    # The `search` row counts against core (Aiur does not meter a separate
    # search window), so it sits with the other core callers.
    assert Enum.map(callers, & &1.caller) == [
             "agent-shell:gh",
             "agent-shell:gh api",
             "agent-shell:gh search repos",
             "agent-shell:gh issue list",
             "agent-shell:gh pr view"
           ]

    # The ranking still splits by budget: the GraphQL subcommands stay out of
    # the core list and the REST ones stay out of the GraphQL list.
    assert [%{caller: "agent-shell:gh pr view", resource: "graphql"}] =
             Enum.filter(callers, &(&1.caller == "agent-shell:gh pr view"))

    assert [%{caller: "agent-shell:gh api", resource: "core"}] =
             Enum.filter(callers, &(&1.caller == "agent-shell:gh api"))

    assert [%{caller: "agent-shell:gh search repos", resource: "core"}] =
             Enum.filter(callers, &(&1.caller == "agent-shell:gh search repos"))
  end

  # The guard allowlists the call-site column, and the reader re-checks it: a
  # row whose call site carries a character outside the safe set is not named.
  # An injected call site must never appear as its own ranked row — the whole
  # point of the column is to make agent spend attributable, and a forged row
  # is exactly the surface that trust would be spent on (#2299 review).
  test "a call site outside the safe character set falls back to the undifferentiated caller" do
    path = Path.join(System.tmp_dir!(), "aiur-gh-quota-#{System.unique_integer([:positive])}.tsv")
    now_unix = DateTime.to_unix(@now)

    File.write!(
      path,
      "#{now_unix}\tticket:1670\tread\tgraphql\tpr;view\n" <>
        "#{now_unix}\tticket:1671\tread\tcore\n"
    )

    on_exit(fn -> File.rm(path) end)
    quota = start_quota(shell_log_path: path)

    callers = Quota.snapshot(quota).callers

    refute Enum.any?(callers, &(&1.caller == "agent-shell:gh pr;view"))
    assert Enum.map(callers, & &1.caller) == ["agent-shell:gh", "agent-shell:gh"]
  end

  # The wrapper appends a credential fingerprint and its own pid to each
  # agent request row (#2255), after the call-site column, so the daemon can
  # attribute a call to the ticket AND the credential pool AND the exact
  # subprocess. Rows written before the columns carried them must keep parsing
  # (the existing tests above), and rows carrying them must flow through.
  test "reads the credential fingerprint and wrapper pid from agent request rows" do
    now_unix = DateTime.to_unix(@now)

    assert %{consumer: "ticket:1670", resource: "core", token_key: "abc123", pid: 4242} =
             Quota.parse_shell_observation("#{now_unix}\tticket:1670\tread\tcore\tapi\tabc123\t4242")

    assert %{consumer: "ticket:1671", resource: "graphql", token_key: nil, pid: nil} =
             Quota.parse_shell_observation("#{now_unix}\tticket:1671\twrite\tgraphql")

    assert %{consumer: "ticket:1670", token_key: nil, pid: nil} =
             Quota.parse_shell_observation("#{now_unix}\tticket:1670\tread\tcore\tapi\t\tbad-pid")

    assert Quota.parse_shell_observation("malformed") == nil
  end

  # Agent-shell attribution never reached the panel: the log lives under each
  # workspace's dot directory, which `Path.wildcard/1` will not descend into
  # without `match_dot: true`, and a workspace root written in tilde form
  # (`~/code/aiur-workspaces`) was never expanded. Either alone matches nothing,
  # so every agent `gh` call went uncounted while the meter still billed it
  # (#1805). This exercises both at once, as production does.
  test "finds the agent-shell log through a dot directory under a tilde-form workspace root" do
    relative = "aiur-quota-test-#{System.unique_integer([:positive])}"
    root = Path.join(System.user_home!(), relative)
    on_exit(fn -> File.rm_rf(root) end)

    quota_dir = Path.join([Layout.issue_workspace_path(root, "1790"), ".aiur-runtime", "github-quota"])
    File.mkdir_p!(quota_dir)
    File.write!(Path.join(quota_dir, "agent-requests.tsv"), "#{DateTime.to_unix(@now)}\tticket:1790\tread\tcore\n")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join("~", relative))

    quota = start_quota()

    assert [%{consumer: "ticket:1790"}] = Quota.snapshot(quota).attribution
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

    quota =
      start_quota(clock: fn -> Agent.get(clock, & &1) end)

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 4077))
    assert :ok = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), generic_rate_limit_response("core", 4077))

    assert {:hold, hold} = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
    assert hold.resource == "core"
    assert hold.reset_at == DateTime.add(@now, 60, :second)
    # The backoff is resource-scoped; GraphQL was never refused.
    assert :ok = Quota.preflight(quota, graphql_request("query { viewer { login } }", %{}))

    Agent.update(clock, fn _ -> DateTime.add(@now, 61, :second) end)

    assert :ok = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
  end

  test "a secondary limit with zero remaining does not become a primary dispatch hold" do
    quota = start_quota()

    Quota.observe(quota, graphql_request("query { viewer { login } }", %{}), secondary_response("graphql", 0, 45))

    snapshot = Quota.snapshot(quota)
    refute Map.has_key?(snapshot.windows, "graphql")
    assert [%{resource: "graphql", seconds_remaining: 45}] = snapshot.backoffs
    assert {:hold, %{resource: "graphql", reset_at: reset_at}} = Quota.preflight(quota, graphql_request("query { viewer { login } }", %{}))
    assert reset_at == DateTime.add(@now, 45, :second)
    assert Quota.dispatch_status(quota) == :available
  end

  test "a secondary limit alerts, keeps dispatch available, publishes a shell hold, and resolves on expiry" do
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

    # The resource preflight is backed off, but a short secondary limit must
    # not turn into a fleet-wide dispatch hold.
    assert Quota.dispatch_status(quota) == :available
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

  test "a secondary-limit signal wins even when the response reports zero remaining" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), secondary_response("core", 0, 45))

    snapshot = Quota.snapshot(quota)
    refute Map.has_key?(snapshot.windows, "core")
    assert [%{resource: "core", seconds_remaining: 45}] = snapshot.backoffs
    assert {:hold, %{reset_at: reset_at}} = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
    assert reset_at == DateTime.add(@now, 45, :second)
    assert Quota.dispatch_status(quota) == :available
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

  test "a scheduled refresh that restores headroom wakes fleet admission without restarting" do
    parent = self()
    name = :"github-quota-recovery-#{System.unique_integer([:positive])}"
    {:ok, quota_state} = Agent.start_link(fn -> {@now, 500} end)

    refresh_fun = fn ->
      {now, remaining} = Agent.get(quota_state, & &1)
      reset = now |> DateTime.add(900, :second) |> DateTime.to_unix()

      Quota.observe(
        name,
        request(:get, "/rate_limit"),
        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{
             "resources" => %{
               "core" => %{"limit" => 5000, "remaining" => remaining, "reset" => reset},
               "graphql" => %{"limit" => 5000, "remaining" => 5000, "reset" => reset}
             }
           }
         }}
      )
    end

    quota =
      start_quota(
        name: name,
        refresh?: true,
        refresh_interval_ms: 10,
        refresh_fun: refresh_fun,
        clock: fn -> quota_state |> Agent.get(&elem(&1, 0)) end,
        recovery_fun: fn -> send(parent, :github_quota_recovered) end
      )

    assert eventually(fn -> match?({:hold, %{resource: "core", remaining: 500}}, Quota.dispatch_status(quota)) end)
    refute_receive :github_quota_recovered

    Agent.update(quota_state, fn {_now, _remaining} -> {DateTime.add(@reset, 1, :second), 4500} end)

    assert_receive :github_quota_recovered, 500
    assert eventually(fn -> Quota.dispatch_status(quota) == :available end)
    refute_receive :github_quota_recovered, 30
  end

  test "a primary window reset wakes fleet admission without another observation" do
    parent = self()
    {:ok, clock} = Agent.start_link(fn -> @now end)

    quota =
      start_quota(
        clock: fn -> Agent.get(clock, & &1) end,
        recovery_fun: fn -> send(parent, :github_quota_recovered) end
      )

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 500))
    assert {:hold, %{resource: "core"}} = Quota.dispatch_status(quota)

    token = :sys.get_state(quota).recovery_timer_token
    Agent.update(clock, fn _ -> DateTime.add(@reset, 1, :second) end)
    send(quota, {:dispatch_recovery, token})

    assert_receive :github_quota_recovered
    assert Quota.dispatch_status(quota) == :available
  end

  # An anonymous read spends the 60/hr unauthenticated IP allowance. GitHub
  # still labels the response `core`, so keying off the header alone would let a
  # `limit: 60` window overwrite the authenticated one and hold the whole fleet.
  test "meters anonymous reads in their own window instead of the authenticated core one" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 3750))
    Quota.observe(quota, anonymous_request("/repos/owner/repo/contents/CODEOWNERS"), response("core", 60, 2))

    snapshot = Quota.snapshot(quota)

    assert snapshot.windows["core"].limit == 5000
    assert snapshot.windows["core"].remaining == 3750

    assert snapshot.windows["core:anonymous"].limit == 60
    assert snapshot.windows["core:anonymous"].remaining == 2
  end

  test "an exhausted anonymous allowance does not hold authenticated dispatch" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 5000))
    Quota.observe(quota, anonymous_request("/repos/owner/repo/contents/CODEOWNERS"), response("core", 60, 0))

    assert Quota.dispatch_status(quota) == :available
    assert Quota.preflight(quota, request(:get, "/repos/owner/repo/issues/1670")) == :ok
  end

  test "holds a further anonymous read once the anonymous allowance is exhausted" do
    quota = start_quota()

    Quota.observe(quota, anonymous_request("/repos/owner/repo/contents/CODEOWNERS"), response("core", 60, 0))

    assert {:hold, hold} = Quota.preflight(quota, anonymous_request("/repos/owner/repo/contents/CODEOWNERS"))
    assert hold.resource == "core:anonymous"
  end

  defp anonymous_request(path) do
    %{method: :get, url: "https://api.github.com#{path}", token: nil, anonymous: true}
  end

  defp start_quota(opts \\ []) do
    # Request logging is disabled here unless a test opts in; otherwise the
    # resolved default path would point at this checkout's repo state and every
    # observe would write a stray file.
    start_supervised!({Quota, Keyword.merge([name: nil, clock: fn -> @now end, hold_dir: nil, request_log_path: nil], opts)})
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
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

  defp generic_rate_limit_response(resource, remaining) do
    {:ok,
     %{
       status: 403,
       headers: [
         {"x-ratelimit-resource", resource},
         {"x-ratelimit-limit", "5000"},
         {"x-ratelimit-remaining", Integer.to_string(remaining)},
         {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(@reset))}
       ],
       body: %{"message" => "API rate limit exceeded"}
     }}
  end

  # A GraphQL response that reports what the query spent, the way the Build
  # Order catalog query does since `rateLimit { cost }` was added to it (#1766).
  defp graphql_response(remaining, cost) do
    {:ok, response} = response("graphql", 5000, remaining)

    {:ok, %{response | body: %{"data" => %{"rateLimit" => %{"cost" => cost, "remaining" => remaining, "limit" => 5000}}}}}
  end

  # The block the transport's injected `rateLimit { limit cost remaining
  # resetAt }` selection brings back on every instrumented query.
  defp rate_limit_block(remaining) do
    %{
      "rateLimit" => %{
        "cost" => 1,
        "limit" => 5000,
        "remaining" => remaining,
        "resetAt" => DateTime.to_iso8601(@reset)
      }
    }
  end

  defp reported_graphql_response(remaining) do
    {:ok, %{status: 200, headers: [], body: %{"data" => rate_limit_block(remaining)}}}
  end

  defp not_modified(resource, remaining) do
    {:ok, response} = response(resource, 5000, remaining)
    {:ok, %{response | status: 304}}
  end

  defp drop_cost_fields(attribution), do: Enum.map(attribution, &Map.drop(&1, [:cost, :costs, :estimated?]))

  defp response(resource, limit, remaining, reset \\ @reset) do
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
end
