defmodule Aiur.AgentGitHubGuard.Reconciliation1Test do
  use Aiur.AgentGitHubGuardCase, async: true

  # #2499. Adding a ledger column is a `PRAGMA table_info` read followed by an
  # `ALTER TABLE` write, and the daemon plus every agent runs it on the same file
  # from separate processes. On a cold start they all read the same column set
  # before any of them writes, so they all decide the column is missing and all
  # try to add it; every process but the winner used to abort with `duplicate
  # column name`, which the wrapper reported as `GitHub budget broker
  # unavailable` and refused. That is a fleet whose first simultaneous reads are
  # mostly refused, on a ledger that is in fact perfectly healthy.
  #
  # The interleaving is forced rather than hoped for. An exclusive lock holds
  # every reader at its `ALTER` until all of them have taken their decision, so
  # releasing it produces exactly one winner and three losers every run.
  test "concurrent readers of different resources survive a migrating ledger", context do
    budget_root = Path.join(context.state_path, "migrating-budget")
    database = Path.join(budget_root, "budget.sqlite3")
    markers = Path.join(context.state_path, "broker-starts")

    env = [
      AIUR_GITHUB_BUDGET_ROOT: budget_root,
      AIUR_GITHUB_BUDGET_KEY: "c" <> String.duplicate("0", 63),
      AIUR_GITHUB_BUDGET_BROKER: start_marking_broker(context, markers),
      # Every reader admissible at once, so the only thing that can refuse one is
      # the migration under test rather than an in-flight ceiling or the stagger.
      AIUR_GITHUB_MAX_INFLIGHT: "8",
      AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT: "8",
      AIUR_GITHUB_REQUESTS_PER_MINUTE: "600",
      AIUR_GITHUB_STAGGER_MS: "0"
    ]

    # A ledger from before `billable_reason` existed. A genuinely fresh ledger
    # has the identical pending migration — the column is not in the `CREATE
    # TABLE` script — but this shape is reachable without racing the file into
    # existence, so the test can hold the lock before the readers arrive.
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/issues/1669"], env)
    drop_ledger_column!(database, "admissions", "billable_reason")
    File.rm_rf!(markers)
    File.mkdir_p!(markers)

    lock = lock_database(database)

    numbers = [1670, 1671, 1672, 1673, 1674, 1675]

    tasks =
      for number <- numbers do
        Task.async(fn -> run_guard(context, ["api", "repos/owner/repo/issues/#{number}"], env) end)
      end

    # A marker means that reader's broker has the ledger open and has already
    # read its schema once, so it is a short stretch of pure CPU away from its
    # own column probe — and it cannot get past the probe, because the exclusive
    # lock stops the `ALTER` that follows it. The settle covers that last stretch
    # for every reader at once.
    #
    # It only ever widens the window a regression has to be caught in. With the
    # migration correct, all six are admitted no matter when the lock drops, so
    # this cannot make the test flaky in the direction that matters; without it,
    # a reader that had not yet probed would read the winner's migrated schema
    # and pass for the wrong reason (measured: 2 runs in 10 missed the defect).
    wait_until(fn -> length(File.ls!(markers)) >= length(numbers) end)
    Process.sleep(200)
    close_port(lock)

    results = Enum.map(tasks, &Task.await(&1, 30_000))
    assert Enum.all?(results, &match?({"ok\n", 0}, &1)), inspect(results)
  end

  test "an unavailable budget root names the root and recovery configuration", context do
    parent_file = Path.join(context.state_path, "not-a-directory")
    budget_root = Path.join(parent_file, "github-budget")
    File.mkdir_p!(context.state_path)
    File.write!(parent_file, "blocking file")

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace)
             )

    assert output =~ "shared budget unavailable"
    assert output =~ budget_root
    assert output =~ "repair ownership/permissions and redispatch"
    assert output =~ "agent.codex.turn_sandbox_policy.writableRoots"
    refute File.exists?(context.calls)
  end

  test "a configured budget fingerprints credentials with shasum when sha256sum is unavailable", context do
    budget_root = Path.join(context.state_path, "host-budget")
    credential = "shared-macos-credential"
    path = isolated_command_path(context, ~w(python3 shasum))

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               GITHUB_TOKEN: credential,
               PATH: path
             )

    key = :crypto.hash(:sha256, credential) |> Base.encode16(case: :lower)

    assert {snapshot, 0} =
             System.cmd("python3", [
               AgentGitHubGuard.budget_broker_path(context.workspace),
               "snapshot",
               "--db",
               Path.join(budget_root, "budget.sqlite3"),
               "--token-key",
               key
             ])

    assert %{"admissions" => [%{}]} = Jason.decode!(snapshot)
  end

  test "a configured budget refuses network calls when python3 is unavailable", context do
    budget_root = Path.join(context.state_path, "host-budget")
    path = isolated_command_path(context, ~w(shasum))

    assert {output, 127} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               PATH: path
             )

    assert output =~ "python3 is required to enforce the governed gh call deadline"
    assert output =~ "python3"
    refute File.exists?(context.calls)
  end

  test "a configured budget refuses api rate_limit when python3 is unavailable", context do
    budget_root = Path.join(context.state_path, "host-budget")
    path = isolated_command_path(context, ~w(shasum))

    assert {output, 127} =
             run_guard(context, ["api", "rate_limit"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               PATH: path
             )

    assert output =~ "python3 is required to enforce the governed gh call deadline"
    assert output =~ "python3"
    refute File.exists?(context.calls)
  end

  # GitHub bills `rate_limit` at zero (#2328), so an explicit probe is still
  # admitted through the shared core budget (it takes an RPM slot, an in-flight
  # lease, and a stagger) but must be written to the ledger non-billable — it
  # never counts toward a per-actor hourly core ceiling or the core family
  # total the ceilings are re-derived from.
  test "api rate_limit is admitted non-billable in either spelling", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)

    # `/rate_limit` is accepted with or without its leading slash and is never
    # booked to `rest`/core: family `rate_limit`, resource `none`, billable
    # false — the same row the daemon's Budget path records through the shared
    # EndpointPolicy table (#2353).
    #
    # Each spelling uses its own token key, so the second iteration's assertion
    # cannot pass on the first iteration's ledger row: the `/rate_limit`
    # spelling is only asserted when THIS run recorded its own row. (A shared
    # key made the `Enum.any?` a tautology — iteration 1's row satisfied it no
    # matter what iteration 2 recorded.)
    for {spelling, suffix} <- [{"rate_limit", "a"}, {"/rate_limit", "b"}] do
      key = suffix <> String.duplicate("0", 63)

      assert {"5000 0 5000 0", 0} =
               run_guard(context, ["api", spelling],
                 AIUR_GITHUB_BUDGET_ROOT: budget_root,
                 AIUR_GITHUB_BUDGET_KEY: key,
                 AIUR_GITHUB_BUDGET_BROKER: broker
               )

      assert {snapshot, 0} =
               System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

      decoded = Jason.decode!(snapshot)
      assert Enum.any?(decoded["admissions"], &(&1["endpoint_family"] == "rate_limit" and &1["resource"] == "none" and &1["billable"] == false))
    end
  end

  # The second-order half of #2328: the recovery path probes rate limit exactly
  # when the fleet is under pressure, so the probe must not spend local budget.
  # On a rate-limit failure the wrapper admits the original call (billable) and
  # the probe (non-billable), and the core family total the ceilings are
  # derived from counts only the original call.
  test "a rate-limit probe on failure is admitted non-billable and leaves the core total honest", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    reset = System.os_time(:second) + 3_600

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_REPO_STATE_PATH: "",
               AIUR_AGENT_QUOTA_STATE_PATH: "",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_BUDGET_CONSUMER: "workspace:/agent-2328",
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: API rate limit exceeded",
               FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => admissions} = Jason.decode!(snapshot)
    assert Enum.map(admissions, &{&1["endpoint_family"], &1["billable"]}) == [{"issues", true}, {"rate_limit", false}]

    actor =
      Budget.usage(state_dir: budget_root, enabled?: true)
      |> Map.fetch!(:actors)
      |> Enum.find(&(&1.consumer_label == "workspace:/agent-2328"))

    # The billable core figure — what the ceilings are re-derived from — holds
    # only the original call; the probe no longer pads it.
    assert actor.core.used == 1
  end

  # `rate_limit` stays non-billable for the *hourly ceiling* but still counts
  # for pacing: the broker's requests-per-minute slot is consumed by a free
  # probe exactly as it would be by a billed call (#2284's "no quota can still
  # cost a slot"). One rate_limit admission is therefore enough to hold the
  # next request in the same minute.
  test "a guarded 304 response is reconciled as unbilled", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670/timeline"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_CORE_LIMIT_PER_HOUR: "1",
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 304\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"billable" => false}]} = Jason.decode!(snapshot)

    # A healthy reconcile leaves no stale-broker marker behind.
    refute File.exists?(Path.join(context.state_path, "github-quota/broker-reconcile-stale"))
  end

  test "a broker whose reconcile fails structurally raises one alert and leaves the 304 billable", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = stale_broker_path(context)
    key = "a" <> String.duplicate("0", 63)
    marker = Path.join(context.state_path, "github-quota/broker-reconcile-stale")

    run_304 = fn ->
      run_guard(context, ["api", "repos/owner/repo/issues/1670/timeline"],
        AIUR_GITHUB_BUDGET_ROOT: budget_root,
        AIUR_GITHUB_BUDGET_KEY: key,
        AIUR_GITHUB_BUDGET_BROKER: broker,
        # High enough that the second admission (run 2) is admitted: the first
        # run's 304 stays billable because the broker cannot reconcile, so a
        # limit of 1 would hold the second run behind the actor ceiling for the
        # rest of the hour and hang the test (#2307).
        AIUR_GITHUB_CORE_LIMIT_PER_HOUR: "10",
        AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
        FAKE_GH_INCLUDE_HEADERS: "1",
        FAKE_GH_HEADERS: "HTTP/2 304\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
      )
    end

    assert {output, 0} = run_304.()
    # The request still succeeds (a failed reconcile is not a request failure),
    # but the structural failure is surfaced exactly once and the 304 stays
    # billable.
    assert output =~ "is stale for this ledger"
    assert File.exists?(marker)

    assert {snapshot, 0} =
             System.cmd("python3", [AgentGitHubGuard.budget_broker_path(context.workspace), "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"billable" => true}]} = Jason.decode!(snapshot)

    # A second 304 does not re-write the marker (exactly one alert, not
    # per-request noise): the sentinel proves the guard never rewrote it. The
    # reason tag is `reconcile` — this broker acquires fine but cannot
    # reconcile — so even the second run's successful acquire must NOT clear
    # it; only a successful reconcile clears a reconcile-reason marker.
    File.write!(marker, "sentinel\nreconcile\n")
    assert {"ok\n", 0} = run_304.()
    assert File.read!(marker) == "sentinel\nreconcile\n"
  end

  test "a broker that predates the ledger schema fails open at acquire and raises one alert", context do
    budget_root = Path.join(context.state_path, "host-budget")
    db = Path.join(budget_root, "budget.sqlite3")
    key = "a" <> String.duplicate("0", 63)
    stale = pre2284_broker_path(context)
    marker = Path.join(context.state_path, "github-quota/broker-reconcile-stale")

    # The current broker opens the ledger first — the production sequence for a
    # daemon that restarts onto the current release — installing the schema
    # trigger a pre-#2284 broker cannot satisfy (#2307 review: the trigger fires
    # on exactly this broker population, so the guard must fail OPEN on the
    # abort rather than returning 75 and turning a billing leak into a total
    # `gh` outage).
    assert {_output, 0} =
             System.cmd("python3", [
               Budget.broker_path(),
               "acquire",
               "--db",
               db,
               "--token-key",
               key,
               "--resource",
               "core",
               "--consumer-key",
               key,
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
               "35000",
               "--core-limit",
               "10",
               "--graphql-limit",
               "10"
             ])

    run = fn ->
      run_guard(context, ["api", "repos/owner/repo/issues/1670/timeline"],
        AIUR_GITHUB_BUDGET_ROOT: budget_root,
        AIUR_GITHUB_BUDGET_KEY: key,
        AIUR_GITHUB_BUDGET_BROKER: stale,
        AIUR_GITHUB_CORE_LIMIT_PER_HOUR: "10",
        AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
        FAKE_GH_INCLUDE_HEADERS: "1",
        FAKE_GH_HEADERS: "HTTP/2 304\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
      )
    end

    # Fail open: the gh call still happens and succeeds even though the stale
    # broker's acquire aborted (no lease, no admission), and the marker is
    # written exactly once so the daemon raises a fleet alert.
    assert {output, 0} = run.()
    assert output =~ "is stale for this ledger"
    assert File.exists?(marker)

    File.write!(marker, "sentinel\n")
    assert {"ok\n", 0} = run.()
    assert File.read!(marker) == "sentinel\n"
  end

  test "a healthy broker that prints to stderr before granting is still admitted", context do
    # The acquire's 2>&1 merge exists so a stale-broker abort's trigger/stamp
    # message is visible to budget_stale_abort, but it also merges a HEALTHY
    # broker's stderr (a Python DeprecationWarning, a wrapper notice, a locale
    # complaint) into the parse stream. The guard must take the last non-empty
    # line — the actual grant — not prefix-match the merged stream, or a
    # working broker's stderr noise would turn admission into a hard 75 with
    # gh never called (#2307 review).
    budget_root = Path.join(context.state_path, "host-budget")
    broker = noisy_broker_path(context)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670/timeline"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_CORE_LIMIT_PER_HOUR: "1",
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 200\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
             )
  end

  test "a reconcile failure outside the legacy three-literal allowlist still alerts", context do
    # Regression guard for the widened structural detection (#2307 review): the
    # old allowlist matched only "invalid choice: 'reconcile'", the stamp, and
    # the trigger message, and silently swallowed everything else — so a broker
    # that could not reconcile for any OTHER reason (broken install, unreadable
    # ledger, missing module) stayed invisible. Every non-transient reconcile
    # failure must surface one alert; only a transient SQLite lock is exempt.
    budget_root = Path.join(context.state_path, "host-budget")
    broker = broken_reconcile_broker_path(context)
    key = "a" <> String.duplicate("0", 63)
    marker = Path.join(context.state_path, "github-quota/broker-reconcile-stale")

    assert {output, 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670/timeline"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_CORE_LIMIT_PER_HOUR: "10",
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 304\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
             )

    assert output =~ "is stale for this ledger"
    assert File.exists?(marker)
  end

  test "an interrupted reconcile is not reported as a stale broker", context do
    # STALE is not SLOW. A `reconcile`-reason marker is cleared by nothing but a
    # later successful reconcile, so classifying a transient fault as structural
    # latches a permanent fleet alert on a workspace whose broker is current.
    # #2457 makes that live: a single daemon restart produced 28 broker timeouts
    # in ten minutes. Here the reconcile call dies by signal and prints nothing —
    # the shape of an interrupted broker, never of one that predates the ledger
    # schema (every structural failure prints argparse usage, the trigger/stamp
    # refusal, or a traceback). No marker, no alert.
    budget_root = Path.join(context.state_path, "host-budget")
    broker = killed_reconcile_broker_path(context)
    key = "a" <> String.duplicate("0", 63)
    marker = Path.join(context.state_path, "github-quota/broker-reconcile-stale")

    assert {output, 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670/timeline"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_CORE_LIMIT_PER_HOUR: "10",
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 304\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
             )

    refute output =~ "is stale for this ledger"
    refute File.exists?(marker)
  end
end
