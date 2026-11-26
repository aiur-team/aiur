defmodule Aiur.AgentGitHubGuard.Reconciliation2Test do
  use Aiur.AgentGitHubGuardCase, async: true

  test "a successful acquire clears a stale-broker marker left by an earlier structural failure", context do
    # The marker previously cleared only via the 304/reconcile path, so a
    # refreshed workspace that never happened to see a 304 kept alerting
    # forever. A successful acquire is proof the current broker is in charge
    # and must clear it too (#2307 review). The reason tag is `acquire` — the
    # broker could not even be admitted before — which is exactly the marker a
    # successful grant is allowed to clear (a `reconcile`-reason marker is only
    # cleared by a successful reconcile, so it never re-alerts per 304).
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    marker = Path.join(context.state_path, "github-quota/broker-reconcile-stale")
    File.mkdir_p!(Path.dirname(marker))
    File.write!(marker, "sentinel\nacquire\n")

    # A 200 (not 304) so the reconcile path is never consulted: only the
    # acquire-side clear may remove the marker.
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

    refute File.exists?(marker)
  end

  test "a high-level pr view 304 is reconciled as unbilled and its transcript is stripped", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    # `gh` emits `[git remote -v]` / `[git config ...]` subprocess lines BEFORE
    # the first request marker; they are part of the debug transcript, not
    # caller-facing stderr, so they must be stripped too (#2353 review).
    git_lines = "[git remote -v]\n[git config --get-regexp ^remote\\..*\\.gh-resolved$]"

    assert {output, 0} =
             run_guard(context, ["pr", "view", "1670", "--json", "body"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_DEBUG_STATUS: "304",
               FAKE_GH_DEBUG_PRE: git_lines,
               FAKE_GH_DEBUG_ERROR: "gh: a real error after the transcript"
             )

    # `gh` prints the 304 status only under GH_DEBUG=api; the wrapper consumes
    # it for reconciliation and strips the transcript — request markers, status
    # lines, and the `[git ...]` subprocess lines alike — so the caller's
    # stderr is unchanged, while a genuine error printed after the request
    # survives.
    assert output =~ "gh: a real error after the transcript"
    refute output =~ "Request at"
    refute output =~ "HTTP/2.0 304"
    refute output =~ "git remote -v"
    refute output =~ "git config --get-regexp"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"endpoint_family" => "pulls", "billable" => false}]} = Jason.decode!(snapshot)
  end

  test "a high-level 304 among 200s stays billable", context do
    # `gh pr view` can issue several HTTP requests under one lease. A 304 after
    # a 200 must NOT mark the whole lease free — that under-reports spend
    # (#2353 review). Only a lease whose EVERY observed status is 304 is
    # reconciled as unbilled.
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {_output, 0} =
             run_guard(context, ["pr", "view", "1670", "--json", "body"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_DEBUG_STATUSES: "200 304"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"endpoint_family" => "pulls", "billable" => true}]} = Jason.decode!(snapshot)
  end

  test "a high-level lease whose every status is 304 is reconciled as unbilled", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\n", 0} =
             run_guard(context, ["pr", "view", "1670", "--json", "body"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_DEBUG_STATUSES: "304 304"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"endpoint_family" => "pulls", "billable" => false}]} = Jason.decode!(snapshot)
  end

  test "a high-level issue view 304 is reconciled as unbilled", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\n", 0} =
             run_guard(context, ["issue", "view", "1670", "--json", "body"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_DEBUG_STATUS: "304"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"endpoint_family" => "issues", "billable" => false}]} = Jason.decode!(snapshot)
  end

  test "a high-level search 304 is reconciled as unbilled", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\n", 0} =
             run_guard(context, ["search", "issues", "state:open"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_DEBUG_STATUS: "304"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"endpoint_family" => "search", "billable" => false}]} = Jason.decode!(snapshot)
  end

  test "a 304 in every gh api family is reconciled as unbilled", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    api_families = [
      {"pulls", "repos/owner/repo/pulls/1670"},
      {"issues", "repos/owner/repo/issues/1670"},
      {"actions", "repos/owner/repo/actions/runs/123"},
      {"labels", "repos/owner/repo/labels/bug"},
      {"rest", "repos/owner/repo"},
      {"graphql", "graphql"}
    ]

    for {family, endpoint} <- api_families do
      assert {"ok\n", 0} =
               run_guard(context, ["api", endpoint],
                 AIUR_GITHUB_BUDGET_ROOT: budget_root,
                 AIUR_GITHUB_BUDGET_KEY: key,
                 AIUR_GITHUB_BUDGET_BROKER: broker,
                 AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
                 FAKE_GH_INCLUDE_HEADERS: "1",
                 FAKE_GH_HEADERS: "HTTP/2 304\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
               )

      assert {snapshot, 0} =
               System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

      decoded = Jason.decode!(snapshot)
      assert Enum.any?(decoded["admissions"], &(&1["endpoint_family"] == family and &1["billable"] == false))
    end
  end

  test "a host gh call with no explicit key binds the resolved credential identity", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    formatted = Path.join(context.workspace, "host-identity-derivations")

    # No AIUR_GITHUB_BUDGET_KEY: the Executor wrapper resolves the token itself
    # (`gh auth token`) and derives the credential's stable identity from the
    # login that token authenticates as — here the keyring login the fake gh
    # reports, standing in for its-everdred (#2353). The derivation invokes
    # `gh api user --jq .login`, which the fake `gh` logs to FAKE_GH_FORMAT_ARGS.
    assert {"ok\n", 0} =
             run_executor_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_FORMAT_OUTPUT: "its-everdred\n",
               FAKE_GH_FORMAT_ARGS: formatted,
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 200\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
             )

    token_key = sha256_hex("ok")
    identity_key = sha256_hex("aiur-github-credential-v1\0machine_user:primary:its-everdred")

    assert {snapshot, 0} =
             System.cmd("python3", [
               broker,
               "snapshot",
               "--db",
               Path.join(budget_root, "budget.sqlite3"),
               "--token-key",
               token_key,
               "--identity-key",
               identity_key
             ])

    assert %{"admissions" => [%{"endpoint_family" => "issues"}]} = Jason.decode!(snapshot)

    # A second host call reuses the cached identity (one `api user` derivation
    # per credential), still binding the same key.
    assert {"ok\n", 0} =
             run_executor_guard(context, ["api", "repos/owner/repo/pulls/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_FORMAT_OUTPUT: "its-everdred\n",
               FAKE_GH_FORMAT_ARGS: formatted,
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 200\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [
               broker,
               "snapshot",
               "--db",
               Path.join(budget_root, "budget.sqlite3"),
               "--token-key",
               token_key,
               "--identity-key",
               identity_key
             ])

    admissions = Jason.decode!(snapshot)["admissions"]
    assert Enum.map(admissions, & &1["endpoint_family"]) == ["issues", "pulls"]

    # M15: the second call read the identity cache rather than re-deriving, so
    # `gh api user` ran exactly once across both calls.
    assert line_count(formatted) == 1
  end

  test "a local auth token read never triggers identity derivation", context do
    # Finding 2: derivation used to run before command classification, so EVERY
    # guarded `gh` call paid a `gh api user` round trip on first use — including
    # `auth token`, the boot gate behind Config.keyring_token/0, which must stay
    # a local read. Gating the derivation on admission means a non-admitted
    # `resource=none` call never hits the network.
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    formatted = Path.join(context.workspace, "auth-token-derivations")

    assert {"ok\n", 0} =
             run_executor_guard(context, ["auth", "token"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_FORMAT_OUTPUT: "its-everdred\n",
               FAKE_GH_FORMAT_ARGS: formatted
             )

    # The fake `gh` logs formatter invocations (`gh api user --jq .login` is
    # one) to FAKE_GH_FORMAT_ARGS; a local read must log none.
    refute File.exists?(formatted)
  end

  test "a failed identity derivation is cached so an outage is not re-paid per call", context do
    # Finding 2: a derivation that cannot resolve the login (GitHub
    # unreachable) must not be re-attempted on every admitted call. The failure
    # is cached under the budget root for `budget_identity_retry_ttl` seconds,
    # so a second call in the same window performs no `gh api user`.
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    formatted = Path.join(context.workspace, "failed-derivations")

    base_env = [
      AIUR_GITHUB_BUDGET_ROOT: budget_root,
      AIUR_GITHUB_BUDGET_BROKER: broker,
      AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
      # A bare newline login means `gh api user --jq .login` resolves no
      # identity, exactly as when GitHub is unreachable.
      FAKE_GH_FORMAT_OUTPUT: "\n",
      FAKE_GH_FORMAT_ARGS: formatted,
      FAKE_GH_INCLUDE_HEADERS: "1",
      FAKE_GH_HEADERS: "HTTP/2 200\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
    ]

    assert {"ok\n", 0} = run_executor_guard(context, ["api", "repos/owner/repo/issues/1670"], base_env)
    assert {"ok\n", 0} = run_executor_guard(context, ["api", "repos/owner/repo/pulls/1670"], base_env)

    # One `api user` invocation total — the second call honoured the cached
    # failure instead of re-paying the timeout.
    assert line_count(formatted) == 1
  end
end
