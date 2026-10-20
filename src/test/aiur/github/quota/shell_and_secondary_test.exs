defmodule Aiur.GitHub.Quota.ShellAndSecondaryTest do
  use Aiur.TestSupport

  import Aiur.GitHub.QuotaTestSupport

  alias Aiur.GitHub.Quota
  alias Aiur.GitHub.Quota.ShellObservations
  alias Aiur.Workspace.Layout

  @now ~U[2026-08-09 21:00:00Z]
  @reset ~U[2026-08-09 22:00:00Z]

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
    path = Aiur.TestSupport.tmp_root!("aiur-gh-quota") <> ".tsv"
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
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    quota_dir = Path.join([Layout.issue_workspace_path(root, "1790"), ".aiur-runtime", "github-quota"])
    File.mkdir_p!(quota_dir)
    File.write!(Path.join(quota_dir, "agent-requests.tsv"), "#{DateTime.to_unix(@now)}\tticket:1790\tread\tcore\n")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join("~", relative))

    quota = start_quota()

    assert [%{consumer: "ticket:1790"}] = Quota.snapshot(quota).attribution
  end

  # #4791: reading every workspace's log on the Quota call took 2-5 s; a log
  # untouched since the window opened cannot hold an in-window row, so it is not read.
  test "skips agent-shell logs not modified since the attribution window opened" do
    root = Aiur.TestSupport.tmp_root!("quota-shell-mtime")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    for {ticket, mtime} <- [{"1", DateTime.add(@now, -7200, :second)}, {"2", @now}] do
      path = Path.join([root, ticket, "agent-requests.tsv"])
      File.mkdir_p!(Path.dirname(path))
      # Both rows sit inside the window, so only the mtime filter can drop ticket 1.
      File.write!(path, "#{DateTime.to_unix(@now) - 60}\tticket:#{ticket}\tread\tcore\n")
      File.touch!(path, DateTime.to_unix(mtime))
    end

    state = %{shell_log_path: Path.join([root, "*", "agent-requests.tsv"]), shell_observations: [], shell_refreshed_at: nil}
    assert [%{consumer: "ticket:2"}] = ShellObservations.refresh_shell_observations(state, @now).shell_observations
  end

  # The agent `gh` guard writes `broker-reconcile-stale` exactly once per stale
  # period, when its broker cannot write to the current ledger (schema trigger
  # or version stamp abort at acquire) or cannot reconcile 304s (#2307). This
  # process turns that marker into one fleet alert per workspace — latched on
  # the marker path so a persistent marker does not re-alert on every refresh,
  # and rearmed once the marker disappears (a refreshed broker has recovered).
  test "a stale-broker marker raises one fleet alert per workspace and rearms on recovery" do
    parent = self()
    root = Path.join(System.tmp_dir!(), "aiur-gh-stale-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    quota_dir = Path.join([root, "ws-2307", ".aiur-runtime", "github-quota"])
    File.mkdir_p!(quota_dir)
    marker = Path.join(quota_dir, "broker-reconcile-stale")
    File.write!(marker, "workspace:/ws-2307\n")

    stale_broker_path = Path.join([root, "*", ".aiur-runtime", "github-quota", "broker-reconcile-stale"])

    quota =
      start_quota(
        stale_broker_path: stale_broker_path,
        emit_fun: fn name, opts ->
          send(parent, {:alert, name, opts})
          :ok
        end
      )

    _snapshot = Quota.snapshot(quota)

    assert_receive {:alert, "system.github.budget.broker_reconcile_stale", opts}, 1000
    assert opts[:needs_attention]
    assert opts[:severity] == "warning"
    assert opts[:message] =~ "ws-2307"
    assert opts[:message] =~ "workspace:/ws-2307"
    assert opts[:message] =~ "cannot reconcile 304 responses"

    # A persistent marker latches: the next refresh does not re-alert.
    _snapshot = Quota.snapshot(quota)
    refute_receive {:alert, "system.github.budget.broker_reconcile_stale", _opts}, 100

    # Removing the marker (a refreshed broker recovered) rearms the latch, so a
    # second stale period alerts again rather than staying permanently silent.
    File.rm!(marker)
    _snapshot = Quota.snapshot(quota)
    refute_receive {:alert, "system.github.budget.broker_reconcile_stale", _opts}, 100

    File.write!(marker, "workspace:/ws-2307\n")
    _snapshot = Quota.snapshot(quota)
    assert_receive {:alert, "system.github.budget.broker_reconcile_stale", _opts}, 1000
  end

  test "publishes and clears resource-specific shell holds" do
    hold_dir = Aiur.TestSupport.tmp_root!("aiur-gh-holds")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(hold_dir) end)
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
    hold_dir = Aiur.TestSupport.tmp_root!("aiur-gh-secondary")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(hold_dir) end)
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

    assert_receive {:alert, "system.github.quota.core.secondary", opts}, 1000
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
    assert_receive {:alert, "system.github.quota.core.secondary.resolved", _opts}, 1000
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
end
