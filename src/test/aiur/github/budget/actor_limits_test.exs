defmodule Aiur.GitHub.Budget.ActorLimitsTest do
  use ExUnit.Case, async: false

  import Aiur.GitHub.BudgetTestSupport

  alias Aiur.GitHub.BudgetTestSupport

  alias Aiur.GitHub.Budget

  setup do
    BudgetTestSupport.setup()
  end

  test "keeps token material out of the broker key and endpoint names remain bounded" do
    key = Budget.token_key("secret-token-value")

    assert key =~ ~r/\A[a-f0-9]{64}\z/
    refute key =~ "secret"
    assert Budget.endpoint_family(request("token", "/repos/owner/repo/issues/1477/comments")) == "issues"
    assert Budget.endpoint_family(request("token", "/graphql")) == "graphql"
  end

  test "a daemon /rate_limit poll is recorded non-billable with its own family", %{root: root} do
    opts = [state_dir: root, stagger_ms: 0, credential_key: Budget.identity_key("machine_user:primary:aiur-daemon[bot]")]

    assert {:ok, lease} = Budget.acquire(request("token", "/rate_limit"), opts)
    assert :ok = Budget.release(lease, opts)

    # GitHub meters `/rate_limit` at zero quota, so the ledger must not report
    # it as spend: family `rate_limit` (not `rest`), resource `none` (not a
    # pool), billable false (#2353).
    assert %{admissions: [%{endpoint_family: "rate_limit", resource: "none", billable: false}]} =
             Budget.snapshot("token", opts)

    # And the pool usage the acceptance reconciles against never counts it.
    assert %{actors: [actor]} = Budget.usage(state_dir: root)
    assert actor.core.used == 0
    assert actor.graphql.used == 0
    assert actor.search.used == 0
  end

  test "a billable core call stays billable in the ledger", %{root: root} do
    opts = [state_dir: root, stagger_ms: 0]

    assert {:ok, lease} = Budget.acquire(request("token", "/repos/owner/repo/issues/1477"), opts)
    assert :ok = Budget.release(lease, opts)

    assert %{admissions: [%{endpoint_family: "issues", resource: "core", billable: true}]} =
             Budget.snapshot("token", opts)

    assert %{actors: [actor]} = Budget.usage(state_dir: root)
    assert actor.core.used == 1
  end

  test "resolves the broker from the installed application private directory" do
    assert Budget.broker_path() ==
             :aiur
             |> :code.priv_dir()
             |> to_string()
             |> Path.join("github_budget.py")
  end

  test "an agent hitting its hourly Core ceiling holds only that agent, not the daemon", %{root: root} do
    opts = [
      state_dir: root,
      max_inflight: 10,
      max_inflight_per_endpoint: 10,
      requests_per_minute: 100,
      stagger_ms: 0,
      consumer_key: "workspace:/agent-42",
      agent_core_limit_per_hour: 3,
      agent_graphql_limit_per_hour: 10
    ]

    request = request("shared-token", "/repos/owner/repo/issues/1477")

    leases =
      for _ <- 1..3 do
        assert {:ok, lease} = Budget.acquire(request, opts)
        lease
      end

    # The fourth request from the same agent holds because it hit the Core
    # ceiling, and the hold names the actor budget as the reason. The verdict
    # is returned as soon as the broker answers, so the only race is `python3`
    # subprocess startup under parallel CI load. The broker reports that
    # deadline expiry distinctly as `:github_budget_broker_timeout`, and the
    # assertion retries it instead of failing on runner load (#2286).
    assert {:hold, %{reason: :actor_budget, resource: "core"}} =
             acquire_retrying_timeout(request, Keyword.put(opts, :timeout_ms, 1_000))

    Enum.each(leases, &Budget.release(&1, opts))

    # A different actor (the daemon) on the same token is not held by the
    # agent's ceiling: its own admission is far under the daemon limit.
    daemon_opts = Keyword.drop(opts, [:consumer_key])
    assert {:ok, daemon_lease} = Budget.acquire(request, daemon_opts)
    assert :ok = Budget.release(daemon_lease, daemon_opts)
  end

  test "an actor's Core ceiling does not hold its GraphQL calls and vice versa", %{root: root} do
    opts = [
      state_dir: root,
      max_inflight: 10,
      max_inflight_per_endpoint: 10,
      requests_per_minute: 100,
      stagger_ms: 0,
      consumer_key: "workspace:/agent-7",
      agent_core_limit_per_hour: 2,
      agent_graphql_limit_per_hour: 1
    ]

    core = request("shared-token", "/repos/owner/repo/issues/1477")
    graphql = request("shared-token", "/graphql")

    assert {:ok, c1} = Budget.acquire(core, opts)
    assert {:ok, c2} = Budget.acquire(core, opts)

    # Core is at its ceiling of 2. The hold is returned as soon as the broker
    # answers, but `python3` subprocess startup can race a single deadline
    # under parallel CI load; the broker reports that expiry distinctly as
    # `:github_budget_broker_timeout`, which the assertion retries instead of
    # failing on runner load (#2286).
    assert {:hold, %{reason: :actor_budget, resource: "core"}} =
             acquire_retrying_timeout(core, Keyword.put(opts, :timeout_ms, 1_000))

    # GraphQL still has headroom (0 of 1 used), so it is admitted.
    assert {:ok, g1} = Budget.acquire(graphql, opts)

    # Now GraphQL is at its ceiling of 1, and the hold names the graphql resource.
    assert {:hold, %{reason: :actor_budget, resource: "graphql"}} =
             acquire_retrying_timeout(graphql, Keyword.put(opts, :timeout_ms, 1_000))

    :ok = Budget.release(c1, opts)
    :ok = Budget.release(c2, opts)
    :ok = Budget.release(g1, opts)
  end

  test "a zero per-actor ceiling disables the hold", %{root: root} do
    opts = [
      state_dir: root,
      max_inflight: 10,
      max_inflight_per_endpoint: 10,
      requests_per_minute: 100,
      stagger_ms: 0,
      consumer_key: "workspace:/agent-9",
      agent_core_limit_per_hour: 0,
      agent_graphql_limit_per_hour: 0
    ]

    request = request("shared-token", "/repos/owner/repo/issues/1477")

    leases =
      for _ <- 1..5 do
        assert {:ok, lease} = Budget.acquire(request, opts)
        lease
      end

    Enum.each(leases, &Budget.release(&1, opts))
  end

  test "a 304 response does not consume the actor hourly ceiling", %{root: root} do
    opts = [
      state_dir: root,
      max_inflight: 10,
      max_inflight_per_endpoint: 10,
      requests_per_minute: 100,
      stagger_ms: 0,
      consumer_key: "workspace:/conditional-reader",
      agent_core_limit_per_hour: 1,
      agent_graphql_limit_per_hour: 1
    ]

    request = request("shared-token", "/repos/owner/repo/issues/1477/timeline")

    assert {:ok, first} = Budget.acquire(request, opts)
    assert :ok = Budget.observe(request, first, {:ok, %{status: 304, headers: [], body: ""}}, opts)
    assert :ok = Budget.observe(request, first, {:ok, %{status: 304, headers: [], body: ""}}, opts)
    assert :ok = Budget.release(first, opts)

    assert {:ok, second} = Budget.acquire(request, opts)
    assert :ok = Budget.observe(request, second, {:ok, %{status: 304, headers: [], body: ""}}, opts)
    assert :ok = Budget.release(second, opts)

    # The snapshot says *why* each admission stopped being billable, so a bare
    # `billable = false` is distinguishable from any other unbilled state.
    assert %{admissions: [%{billable: false, billable_reason: "304"}, %{billable: false, billable_reason: "304"}]} =
             Budget.snapshot("shared-token", state_dir: root)

    actor =
      opts
      |> Budget.usage()
      |> Map.fetch!(:actors)
      |> Enum.find(&(&1.consumer_key == Budget.token_key("workspace:/conditional-reader")))

    assert actor.core.used == 0
  end

  test "a reconcile failure against a broker without the reconcile subcommand is logged", %{root: root} do
    # A pre-#2284 broker copy: it can admit and release, but has no `reconcile`
    # subcommand, so the daemon's reconcile call on a 304 exits non-zero the
    # way argparse's "invalid choice" does. The failure must be visible in the
    # daemon log, not read as "reconciliation did not fire".
    stale_broker = Path.join(root, "stale-broker.py")

    File.write!(stale_broker, """
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == "reconcile":
        sys.stderr.write("usage: aiur-github-budget ... invalid choice: 'reconcile'\\n")
        sys.exit(2)
    sys.exit(0)
    """)

    File.chmod!(stale_broker, 0o755)

    opts = [state_dir: root, broker_path: stale_broker, stagger_ms: 0]
    request = request("shared-token", "/repos/owner/repo/issues/1477")
    # A lease the current broker would have granted; only the reconcile call
    # matters here, and it must fail against the stale broker.
    lease = %{id: "lease-1", token_key: Budget.token_key("shared-token")}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Budget.observe(request, lease, {:ok, %{status: 304, headers: [], body: ""}}, opts)
      end)

    assert log =~ "github_budget_reconcile_failed"
  end

  test "a lease-less admission stays billable in the actor ledger", %{root: root} do
    opts = [
      state_dir: root,
      max_inflight: 10,
      max_inflight_per_endpoint: 10,
      requests_per_minute: 100,
      stagger_ms: 0,
      consumer_key: "workspace:/lease-less-reader",
      agent_core_limit_per_hour: 3,
      agent_graphql_limit_per_hour: 1
    ]

    request = request("lease-less-token", "/repos/owner/repo/issues/1477")

    # `acquire` writes the actor's policy row (the `usage` inventory) and one
    # leased, billable admission. Then inject the exact row a pre-#2284 writer
    # (one that wrote the admission without taking a lease) leaves behind. Its
    # status is unknown, so it must stay billable and count as spend: GitHub
    # was charged for it, and no lease means nothing can ever prove it was a
    # 304.
    assert {:ok, lease} = Budget.acquire(request, opts)
    assert :ok = Budget.release(lease, opts)

    db = Budget.database_path(state_dir: root)

    assert :ok =
             insert_lease_less_admission(
               db,
               "lease-less-token",
               Budget.token_key("workspace:/lease-less-reader"),
               "issues",
               1
             )

    actor =
      opts
      |> Budget.usage()
      |> Map.fetch!(:actors)
      |> Enum.find(&(&1.consumer_key == Budget.token_key("workspace:/lease-less-reader")))

    # Both the leased admission and the lease-less one count: dropping the
    # lease-less row from the ledger would report only 1.
    assert actor.core.used == 2
  end
end
