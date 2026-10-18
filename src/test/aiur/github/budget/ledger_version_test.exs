defmodule Aiur.GitHub.Budget.LedgerVersionTest do
  use ExUnit.Case, async: false

  import Aiur.GitHub.BudgetTestSupport

  alias Aiur.GitHub.BudgetTestSupport

  alias Aiur.GitHub.Budget

  setup do
    BudgetTestSupport.setup()
  end

  test "a non-billable rate_limit admission still consumes a rate-per-minute pacing slot", %{root: root} do
    # The #2328 shape: a probe the caller knows GitHub bills at zero is written
    # to the ledger non-billable but still occupies a pacing slot, exactly as a
    # billed call would (#2284's "a request that costs no quota can still cost
    # a slot").
    db = Budget.database_path(state_dir: root)
    broker = Budget.broker_path()
    token = "rate-limit-pacing-token"
    key = Budget.token_key(token)

    assert {"granted " <> _lease, 0} =
             System.cmd("python3", [
               broker,
               "acquire",
               "--db",
               db,
               "--token-key",
               key,
               "--resource",
               "core",
               "--consumer-key",
               Budget.token_key("workspace:/agent-2328"),
               "--consumer-label",
               "workspace:/agent-2328",
               "--endpoint-family",
               "rate_limit",
               "--billable",
               "0",
               "--max-inflight",
               "4",
               "--max-inflight-per-endpoint",
               "2",
               "--requests-per-minute",
               "1",
               "--stagger-ms",
               "0",
               "--lease-ttl-ms",
               "35000",
               "--core-limit",
               "0",
               "--graphql-limit",
               "0"
             ])

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", db, "--token-key", key])

    assert %{"admissions" => [%{"endpoint_family" => "rate_limit", "billable" => false}]} = Jason.decode!(snapshot)

    # One free admission fills the single requests-per-minute slot, so a second
    # admission in the same minute is paced even though the first cost nothing.
    assert {:hold, %{reason: :shared_budget}} =
             Budget.acquire(
               request(token, "/repos/owner/repo/issues/1477"),
               state_dir: root,
               requests_per_minute: 1,
               stagger_ms: 0,
               timeout_ms: 300
             )
  end

  test "an existing admissions table migrates before response reconciliation", %{root: root} do
    db = Budget.database_path(state_dir: root)
    create_legacy_budget_database(db)

    opts = [
      state_dir: root,
      max_inflight: 2,
      max_inflight_per_endpoint: 2,
      requests_per_minute: 20,
      stagger_ms: 0,
      consumer_key: "workspace:/migrated-reader",
      agent_core_limit_per_hour: 1,
      agent_graphql_limit_per_hour: 1
    ]

    request = request("migrated-token", "/repos/owner/repo/issues/1477")
    assert {:ok, lease} = Budget.acquire(request, opts)
    assert :ok = Budget.observe(request, lease, {:ok, %{status: 304, headers: [], body: ""}}, opts)
    assert :ok = Budget.release(lease, opts)
    assert {:ok, second} = Budget.acquire(request, opts)
    assert :ok = Budget.release(second, opts)
  end

  test "usage reports each actor's Core/GraphQL used and limit with a reset", %{root: root} do
    opts = [
      state_dir: root,
      max_inflight: 10,
      max_inflight_per_endpoint: 10,
      requests_per_minute: 100,
      stagger_ms: 0,
      consumer_key: "workspace:/agent-42",
      agent_core_limit_per_hour: 3,
      agent_graphql_limit_per_hour: 5
    ]

    core = request("shared-token", "/repos/owner/repo/issues/1477")
    graphql = request("shared-token", "/graphql")

    assert {:ok, c1} = Budget.acquire(core, opts)
    assert {:ok, c2} = Budget.acquire(core, opts)
    assert {:ok, g1} = Budget.acquire(graphql, opts)
    :ok = Budget.release(c1, opts)
    :ok = Budget.release(c2, opts)
    :ok = Budget.release(g1, opts)

    usage = Budget.usage(state_dir: root)

    actor =
      Enum.find(usage.actors, &(&1.consumer_key == Budget.token_key("workspace:/agent-42")))

    assert actor.consumer_label == "workspace:/agent-42"
    assert actor.core.used == 2
    assert actor.core.limit == 3
    assert is_integer(actor.core.reset_at_ms)
    assert actor.graphql.used == 1
    assert actor.graphql.limit == 5
    assert is_integer(actor.graphql.reset_at_ms)
  end

  test "a contradictory actor hold raises one alert and rearms after convergence", %{root: root} do
    test_pid = self()

    opts = [
      state_dir: root,
      max_inflight: 10,
      max_inflight_per_endpoint: 10,
      requests_per_minute: 100,
      stagger_ms: 0,
      timeout_ms: 500,
      broker_server: start_supervised!({Aiur.GitHub.BudgetBroker, name: nil}),
      consumer_key: "workspace:/contradictory-reader",
      agent_core_limit_per_hour: 2,
      agent_graphql_limit_per_hour: 2,
      alert_fun: fn name, alert_opts ->
        send(test_pid, {:budget_alert, name, alert_opts})
        :ok
      end
    ]

    request = request("shared-token", "/repos/owner/repo/issues/1477")
    reset = System.system_time(:second) + 3_600
    observe_headroom(request, limit: 10, remaining: 10, reset: reset)

    for _ <- 1..2 do
      assert {:ok, lease} = acquire_retrying_timeout(request, opts)
      assert :ok = Budget.release(lease, opts)
    end

    hold_opts = Keyword.put(opts, :timeout_ms, 200)

    # At its ceiling, each attempt holds or times out; retries cannot double-consume
    # (#2286).
    assert {:hold, %{reason: :actor_budget}} = acquire_retrying_timeout(request, hold_opts)
    assert_receive {:budget_alert, "system.github.budget_meter_disagreement", alert_opts}, 1000
    assert alert_opts[:needs_attention]
    assert alert_opts[:reason] =~ "local billed=2/2"
    assert alert_opts[:reason] =~ "GitHub used=0/10"

    assert {:hold, %{reason: :actor_budget}} = acquire_retrying_timeout(request, hold_opts)
    refute_receive {:budget_alert, _, _}, 100

    observe_headroom(request, limit: 10, remaining: 8, reset: reset)
    assert {:hold, %{reason: :actor_budget}} = acquire_retrying_timeout(request, hold_opts)
    refute_receive {:budget_alert, _, _}, 100

    observe_headroom(request, limit: 10, remaining: 10, reset: reset)
    assert {:hold, %{reason: :actor_budget}} = acquire_retrying_timeout(request, hold_opts)
    assert_receive {:budget_alert, "system.github.budget_meter_disagreement", _alert_opts}, 1000
  end

  test "a shared cooldown outliving the credential window raises one alert", %{root: root} do
    test_pid = self()

    opts = [
      state_dir: root,
      max_inflight: 4,
      max_inflight_per_endpoint: 2,
      requests_per_minute: 20,
      stagger_ms: 0,
      timeout_ms: 300,
      alert_fun: fn name, alert_opts ->
        send(test_pid, {:budget_alert, name, alert_opts})
        :ok
      end
    ]

    issues = request("shared-token", "/repos/owner/repo/issues/1477")
    pulls = request("shared-token", "/repos/owner/repo/pulls/1477")
    reset = System.system_time(:second) + 3_600

    # The cooldown the broker sets from a rate-limited response, standing while
    # the credential's own fresh window still reports the whole limit unspent —
    # the exact contradiction that stalled the fleet in #2278. This write must
    # land for the cooldown to exist at all, so it gets a deadline that is not
    # competitive with `python3` subprocess startup under CI load (a retry on
    # `acquire` cannot recover a cooldown that was never recorded) (#2286).
    assert :ok =
             Budget.observe(
               issues,
               {:ok, %{status: 403, headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "5"}], body: %{"message" => "rate limit exceeded"}}},
               Keyword.put(opts, :timeout_ms, 5_000)
             )

    observe_headroom(pulls, limit: 100, remaining: 100, reset: reset)

    assert {:hold, %{reason: :shared_budget}} = acquire_retrying_timeout(pulls, opts)
    assert_receive {:budget_alert, "system.github.budget_meter_disagreement", alert_opts}, 1000
    assert alert_opts[:needs_attention]
    assert alert_opts[:reason] =~ "shared budget hold contradicts"
    assert alert_opts[:reason] =~ "remaining=100/100"

    assert {:hold, %{reason: :shared_budget}} = acquire_retrying_timeout(pulls, opts)
    refute_receive {:budget_alert, _, _}, 100

    # GitHub agreeing that the credential really is spent clears the signal, so
    # the next genuine divergence is still able to speak.
    observe_headroom(pulls, limit: 100, remaining: 0, reset: reset)
    assert {:hold, %{reason: :shared_budget}} = acquire_retrying_timeout(pulls, opts)
    refute_receive {:budget_alert, _, _}, 100

    observe_headroom(pulls, limit: 100, remaining: 100, reset: reset)
    assert {:hold, %{reason: :shared_budget}} = acquire_retrying_timeout(pulls, opts)
    assert_receive {:budget_alert, "system.github.budget_meter_disagreement", _alert_opts}, 1000
  end

  test "usage degrades to an empty actor list when the broker is disabled", %{root: root} do
    previous = Application.get_env(:aiur, :github_budget_enabled?)
    Application.put_env(:aiur, :github_budget_enabled?, false)
    on_exit(fn -> restore_env(:github_budget_enabled?, previous) end)

    assert Budget.usage(state_dir: root) == %{actors: []}
  end

  test "a stale policy row does not constrain the reconcile but stays in the usage report", %{root: root} do
    opts = [
      state_dir: root,
      max_inflight: 4,
      max_inflight_per_endpoint: 4,
      requests_per_minute: 100,
      stagger_ms: 0,
      consumer_key: "workspace:/fresh",
      agent_core_limit_per_hour: 3,
      agent_graphql_limit_per_hour: 5
    ]

    request = request("shared-token", "/repos/owner/repo/issues/1477")
    assert {:ok, _} = Budget.acquire(request, opts)

    # A consumer that went idle ten minutes ago keeps a policy row (the usage
    # report needs its label and limits for the hour), but its old max_inflight
    # of 1 must not constrain the fleet in the meantime.
    insert_stale_policy(Budget.database_path(state_dir: root), Budget.token_key("shared-token"))

    assert {:ok, l1} = Budget.acquire(request, opts)
    assert {:ok, l2} = Budget.acquire(request, opts)
    :ok = Budget.release(l1, opts)
    :ok = Budget.release(l2, opts)

    usage = Budget.usage(state_dir: root)
    assert Enum.any?(usage.actors, &(&1.consumer_label == "workspace:/stale"))
  end

  test "a current broker stamps the ledger with its version", %{root: root} do
    opts = [state_dir: root, stagger_ms: 0]
    assert {:ok, lease} = Budget.acquire(request("stamp-token", "/repos/owner/repo/issues/1477"), opts)
    assert :ok = Budget.release(lease, opts)

    assert {"1\n", 0} =
             System.cmd("python3", [
               "-c",
               "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(\"SELECT value FROM broker_meta WHERE key='broker_version'\").fetchone()[0])",
               Budget.database_path(state_dir: root)
             ])
  end

  test "a read-only command does not stamp the ledger or install the trigger", %{root: root} do
    db = Budget.database_path(state_dir: root)
    key = Budget.token_key("read-token")

    # snapshot is a read command; it must not take a schema write (the version
    # stamp or the lease trigger) on the shared ledger just to report on it
    # (#2307 review).
    assert {_output, 0} =
             System.cmd("python3", [Budget.broker_path(), "snapshot", "--db", db, "--token-key", key], stderr_to_stdout: true)

    script =
      "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); " <>
        "print(c.execute(\"SELECT COUNT(*) FROM broker_meta\").fetchone()[0]); " <>
        "print(c.execute(\"SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='admissions_require_lease'\").fetchone()[0])"

    assert {"0\n0\n", 0} = System.cmd("python3", ["-c", script, db], stderr_to_stdout: true)

    # The first write installs both.
    opts = [state_dir: root, stagger_ms: 0]
    assert {:ok, lease} = Budget.acquire(request("read-token", "/repos/owner/repo/issues/1477"), opts)
    assert :ok = Budget.release(lease, opts)

    assert {"1\n1\n", 0} = System.cmd("python3", ["-c", script, db], stderr_to_stdout: true)
  end

  test "a broker older than the ledger version stamp refuses to write with a clear message", %{root: root} do
    opts = [state_dir: root, stagger_ms: 0]
    db = Budget.database_path(state_dir: root)
    request = request("stamp-token", "/repos/owner/repo/issues/1477")
    assert {:ok, lease} = Budget.acquire(request, opts)
    assert :ok = Budget.release(lease, opts)

    # Stamp the ledger past this broker's version, exactly as the next release's
    # broker would when it opens the shared ledger. This broker is now stale.
    bump_broker_version(db, 99)

    key = Budget.token_key("stamp-token")

    {output, status} =
      System.cmd(
        "python3",
        [
          Budget.broker_path(),
          "acquire",
          "--db",
          db,
          "--token-key",
          key,
          "--resource",
          "core",
          "--consumer-key",
          Budget.token_key("stale-writer"),
          "--endpoint-family",
          "issues",
          "--max-inflight",
          "2",
          "--max-inflight-per-endpoint",
          "2",
          "--requests-per-minute",
          "20",
          "--stagger-ms",
          "0",
          "--lease-ttl-ms",
          "35000"
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "refusing to write: ledger is stamped version 99"
    assert output =~ "this broker is version"

    # Nothing was written by the stale broker: the ledger still holds only the
    # admission the current broker created before the stamp was bumped.
    snapshot = Budget.snapshot("stamp-token", state_dir: root)
    assert length(snapshot.admissions) == 1
  end

  test "a broker that omits the lease id cannot write an admission", %{root: root} do
    db = Budget.database_path(state_dir: root)
    opts = [state_dir: root, stagger_ms: 0]
    assert {:ok, lease} = Budget.acquire(request("lease-trigger-token", "/repos/owner/repo/issues/1477"), opts)
    assert :ok = Budget.release(lease, opts)

    # A pre-#2284 broker's INSERT names no `lease_id`; the schema trigger must
    # refuse it loudly instead of leaving a row the current broker can never
    # reconcile or refund (#2307).
    {output, status} =
      System.cmd(
        "python3",
        [
          "-c",
          "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); " <>
            "c.execute(\"INSERT INTO admissions(token_key, consumer_key, endpoint_family, admitted_at_ms) VALUES ('k','c','issues',1)\"); c.commit()",
          db
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "refusing admission without a lease_id"
  end
end
