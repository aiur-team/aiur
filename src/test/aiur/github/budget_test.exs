defmodule Aiur.GitHub.BudgetTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.GitHub.{Budget, CredentialHeadroom}

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-github-budget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous = Application.get_env(:aiur, :github_budget_enabled?)
    Application.put_env(:aiur, :github_budget_enabled?, true)
    CredentialHeadroom.reset()

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:github_budget_enabled?, previous)
      CredentialHeadroom.reset()
    end)

    {:ok, root: root}
  end

  test "one credential keeps its admission history across token rotation", %{root: root} do
    credential_key = Budget.identity_key("machine_user:primary:aiur-bot")
    opts = [state_dir: root, stagger_ms: 0, credential_key: credential_key]

    assert {:ok, first} = Budget.acquire(request("token-before-rotation", "/repos/owner/repo/issues/2236"), opts)
    assert :ok = Budget.release(first, opts)
    assert {:ok, second} = Budget.acquire(request("token-after-rotation", "/repos/owner/repo/issues/2236"), opts)
    assert :ok = Budget.release(second, opts)

    assert %{admissions: [_, _]} = Budget.snapshot("token-after-rotation", opts)

    assert %{actors: [actor]} = Budget.usage(state_dir: root)
    assert actor.token_key == credential_key
    assert actor.core.used == 2
  end

  test "the first stable identity adopts an active token-hash ledger", %{root: root} do
    legacy_opts = [state_dir: root, stagger_ms: 0]
    token = "pre-upgrade-token"

    assert {:ok, legacy} = Budget.acquire(request(token, "/repos/owner/repo/issues/2236"), legacy_opts)
    assert :ok = Budget.release(legacy, legacy_opts)

    stable_opts = Keyword.put(legacy_opts, :credential_key, Budget.identity_key("machine_user:primary:aiur-bot"))
    assert {:ok, current} = Budget.acquire(request(token, "/repos/owner/repo/issues/2236"), stable_opts)
    assert :ok = Budget.release(current, stable_opts)

    assert %{admissions: [_, _]} = Budget.snapshot(token, stable_opts)
  end

  test "distinct stable credentials stay isolated even when their tokens overlap", %{root: root} do
    token = "shared-token"
    first_opts = [state_dir: root, stagger_ms: 0, credential_key: Budget.identity_key("machine_user:first:same-login")]
    second_opts = [state_dir: root, stagger_ms: 0, credential_key: Budget.identity_key("machine_user:second:same-login")]

    assert {:ok, first} = Budget.acquire(request(token, "/repos/owner/repo/issues/2236"), first_opts)
    assert :ok = Budget.release(first, first_opts)
    assert {:ok, second} = Budget.acquire(request(token, "/repos/owner/repo/issues/2236"), second_opts)
    assert :ok = Budget.release(second, second_opts)

    assert %{admissions: [_]} = Budget.snapshot(token, first_opts)
    assert %{admissions: [_]} = Budget.snapshot(token, second_opts)
  end

  test "two independent callers sharing a token cannot exceed the global in-flight ceiling", %{root: root} do
    opts = [state_dir: root, max_inflight: 1, max_inflight_per_endpoint: 1, requests_per_minute: 20, stagger_ms: 0]
    request = request("shared-token", "/repos/owner/repo/issues/1477")

    assert {:ok, first} = Budget.acquire(request, opts)

    waiter = Task.async(fn -> Budget.acquire(request, opts) end)

    assert Task.yield(waiter, 80) == nil
    assert :ok = Budget.release(first, opts)
    assert {:ok, second} = Task.await(waiter, 1_000)
    assert :ok = Budget.release(second, opts)
  end

  test "active consumers reconcile conflicting ceilings to the strictest policy", %{root: root} do
    strict = [state_dir: root, consumer_key: "strict", max_inflight: 1, max_inflight_per_endpoint: 1, requests_per_minute: 20, stagger_ms: 0]
    loose = [state_dir: root, consumer_key: "loose", max_inflight: 2, max_inflight_per_endpoint: 2, requests_per_minute: 20, stagger_ms: 0]
    request = request("shared-token", "/repos/owner/repo/issues/1477")

    assert {:ok, first} = Budget.acquire(request, strict)
    waiter = Task.async(fn -> Budget.acquire(request, loose) end)

    assert Task.yield(waiter, 80) == nil
    assert :ok = Budget.release(first, strict)
    assert {:ok, second} = Task.await(waiter, 1_000)
    assert :ok = Budget.release(second, loose)
  end

  test "the endpoint-family ceiling does not consume capacity in other families", %{root: root} do
    opts = [state_dir: root, max_inflight: 2, max_inflight_per_endpoint: 1, requests_per_minute: 20, stagger_ms: 0]
    issues = request("shared-token", "/repos/owner/repo/issues/1477")
    pulls = request("shared-token", "/repos/owner/repo/pulls/1477")

    assert {:ok, first} = Budget.acquire(issues, opts)
    waiter = Task.async(fn -> Budget.acquire(issues, opts) end)

    assert Task.yield(waiter, 80) == nil
    assert {:ok, pulls_lease} = Budget.acquire(pulls, opts)
    assert :ok = Budget.release(pulls_lease, opts)
    assert :ok = Budget.release(first, opts)
    assert {:ok, second} = Task.await(waiter, 1_000)
    assert :ok = Budget.release(second, opts)
  end

  test "a secondary limit cools down every endpoint family for the token", %{root: root} do
    opts = [state_dir: root, max_inflight: 4, max_inflight_per_endpoint: 2, requests_per_minute: 20, stagger_ms: 0]
    issues = request("shared-token", "/repos/owner/repo/issues/1477")
    pulls = request("shared-token", "/repos/owner/repo/pulls/1477")

    assert :ok = Budget.observe(issues, secondary_response(1), opts)

    waiter = Task.async(fn -> Budget.acquire(pulls, opts) end)

    assert Task.yield(waiter, 80) == nil
    assert {:ok, lease} = Task.await(waiter, 1_500)
    assert :ok = Budget.release(lease, opts)
  end

  test "an exhausted response without a reset still creates a global fallback cooldown", %{root: root} do
    opts = [state_dir: root, max_inflight: 4, max_inflight_per_endpoint: 2, requests_per_minute: 20, stagger_ms: 0]
    issues = request("shared-token", "/repos/owner/repo/issues/1477")
    pulls = request("shared-token", "/repos/owner/repo/pulls/1477")

    assert :ok =
             Budget.observe(
               issues,
               {:ok, %{status: 403, headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "5"}], body: %{"message" => "rate limit exceeded"}}},
               opts
             )

    assert {:hold, %{reason: :shared_budget}} = Budget.acquire(pulls, Keyword.put(opts, :timeout_ms, 1_000))
  end

  test "a configured broker failure is not reported as shared quota exhaustion", %{root: root} do
    opts = [state_dir: root, enabled?: true, python: Path.join(root, "missing-python"), timeout_ms: 10]

    assert {:error, :github_budget_broker_unavailable} =
             Budget.acquire(request("shared-token", "/repos/owner/repo/issues/1477"), opts)
  end

  test "a box without python3 fails open to :bypass so requests stay unmetered (#2376)", %{root: root} do
    # No explicit `:python` (equivalent to `System.find_executable("python3")`
    # returning nil on a stock box): the broker cannot run, so `acquire/2` must
    # fail open to unmetered operation rather than erroring every request.
    opts = [state_dir: root, enabled?: true, python: nil]

    assert :bypass = Budget.acquire(request("shared-token", "/repos/owner/repo/issues/1477"), opts)
  end

  test "warn_metering_unavailable/0 logs once, clearly, when python3 is absent", %{root: root} do
    log =
      capture_log(fn ->
        assert :ok = Budget.warn_metering_unavailable(state_dir: root, enabled?: true, python: nil)
      end)

    assert log =~ "budget metering is disabled"
    assert log =~ "python3 was not found"
    assert log =~ "run unmetered"
  end

  test "warn_metering_unavailable/0 stays silent when the broker can run", %{root: root} do
    log =
      capture_log(fn ->
        assert :ok = Budget.warn_metering_unavailable(state_dir: root, enabled?: true, python: "python3")
      end)

    assert log == ""
  end

  test "lease duration can outlive the broker command timeout" do
    assert %{lease_ttl_ms: 25_000} =
             Budget.guard_settings(timeout_ms: 1_500, lease_timeout_ms: 10_000)
  end

  test "database lock cannot hold admission beyond its wall-clock budget", %{root: root} do
    broker_pid_path = Path.join(root, "broker.pid")
    python = broker_wrapper(root, broker_pid_path)
    opts = [state_dir: root, enabled?: true]
    token = "locked-budget-token"

    # Create the schema before taking an exclusive lock so the broker blocks
    # specifically on SQLite admission rather than setup.
    assert %{inflight: %{}} = Budget.snapshot(token, opts)
    lock = lock_database(Budget.database_path(opts))

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :github_budget_broker_unavailable} =
             Budget.acquire(
               request(token, "/repos/owner/repo/issues/1477"),
               opts |> Keyword.put(:python, python) |> Keyword.put(:timeout_ms, 300)
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms >= 250
    assert elapsed_ms < 1_000
    broker_pid = broker_pid_path |> File.read!() |> String.trim()
    wait_until(fn -> not os_process_alive?(broker_pid) end)

    close_port(lock)
  end

  test "database lock cannot hold release beyond its absolute deadline", %{root: root} do
    broker_pid_path = Path.join(root, "release-broker.pid")
    python = broker_wrapper(root, broker_pid_path)
    opts = [state_dir: root, enabled?: true]
    request = request("locked-release-token", "/repos/owner/repo/issues/1477")

    # The setup acquire spawns `python3` and creates the broker database. That is
    # not the window under test, so it must not be charged the 300 ms deadline
    # the release is measured against. A loaded runner can spend more than that
    # on one admission before the database lock is even taken (#1983).
    assert {:ok, lease} = Budget.acquire(request, opts)
    lock = lock_database(Budget.database_path(opts))
    deadline_at = System.monotonic_time(:millisecond) + 300
    started_at = System.monotonic_time(:millisecond)

    assert :ok =
             Budget.release(
               lease,
               opts
               |> Keyword.put(:python, python)
               |> Keyword.put(:timeout_ms, 300)
               |> Keyword.put(:deadline_at, deadline_at)
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms >= 250
    assert elapsed_ms < 1_000
    broker_pid = broker_pid_path |> File.read!() |> String.trim()
    wait_until(fn -> not os_process_alive?(broker_pid) end)

    close_port(lock)
  end

  test "caller death reaps a blocked broker process", %{root: root} do
    broker_pid_path = Path.join(root, "abandoned-broker.pid")
    python = broker_wrapper(root, broker_pid_path)
    opts = [state_dir: root, enabled?: true, python: python, timeout_ms: 30_000]
    token = "abandoned-budget-token"

    assert %{inflight: %{}} = Budget.snapshot(token, state_dir: root, enabled?: true)
    lock = lock_database(Budget.database_path(opts))

    caller =
      spawn(fn ->
        Budget.acquire(request(token, "/repos/owner/repo/issues/1477"), opts)
      end)

    caller_ref = Process.monitor(caller)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    wait_until(fn -> File.exists?(broker_pid_path) end)
    broker_pid = broker_pid_path |> File.read!() |> String.trim()

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 2_000
    wait_until(fn -> not os_process_alive?(broker_pid) end)
    close_port(lock)
  end

  test "refuses an unsafe shared state path", %{root: root} do
    path = Path.join(root, "not-a-directory")
    File.write!(path, "not a directory")

    assert {:error, {:unsafe_budget_state_dir, ^path, :regular}} = Budget.ensure_state_dir(state_dir: path)
  end

  test "a malformed broker wait response is not reported as shared quota exhaustion", %{root: root} do
    fake_python = Path.join(root, "malformed-broker")
    File.write!(fake_python, "#!/bin/sh\nprintf '%s\\n' 'wait malformed'\n")
    File.chmod!(fake_python, 0o755)

    assert {:error, :github_budget_broker_unavailable} =
             Budget.acquire(
               request("shared-token", "/repos/owner/repo/issues/1477"),
               state_dir: root,
               enabled?: true,
               python: fake_python,
               timeout_ms: 10
             )
  end

  test "a typed shared hold preserves resource and absolute reset", %{root: root} do
    fake_python = Path.join(root, "typed-hold-broker")
    reset_at_ms = System.system_time(:millisecond) + 60_000
    File.write!(fake_python, "#!/bin/sh\nprintf '%s\\n' 'hold shared graphql #{reset_at_ms}'\n")
    File.chmod!(fake_python, 0o755)

    assert {:hold, %{reason: :shared_budget, resource: "graphql", reset_at: reset_at}} =
             Budget.acquire(
               request("shared-token", "/graphql"),
               state_dir: root,
               enabled?: true,
               python: fake_python,
               timeout_ms: 1_000
             )

    assert DateTime.to_unix(reset_at, :millisecond) == reset_at_ms
  end

  test "malformed typed shared holds are broker failures", %{root: root} do
    fake_python = Path.join(root, "malformed-typed-hold-broker")
    File.write!(fake_python, "#!/bin/sh\nprintf '%s\\n' 'hold shared admin never'\n")
    File.chmod!(fake_python, 0o755)

    assert {:error, :github_budget_broker_unavailable} =
             Budget.acquire(
               request("shared-token", "/graphql"),
               state_dir: root,
               enabled?: true,
               python: fake_python,
               timeout_ms: 1_000
             )
  end

  test "an exhausted successful response shares the resource named by GitHub", %{root: root} do
    opts = [state_dir: root, max_inflight: 4, max_inflight_per_endpoint: 2, requests_per_minute: 20, stagger_ms: 0]
    core = request("shared-token", "/repos/owner/repo/issues/1477")
    graphql = request("shared-token", "/graphql")
    reset_at = System.system_time(:second) + 60

    response =
      {:ok,
       %{
         status: 200,
         headers: [
           {"x-ratelimit-resource", "graphql"},
           {"x-ratelimit-remaining", "0"},
           {"x-ratelimit-reset", Integer.to_string(reset_at)}
         ]
       }}

    assert :ok = Budget.observe(core, response, opts)

    assert {:hold, %{reason: :shared_budget, resource: "graphql"}} =
             Budget.acquire(graphql, Keyword.put(opts, :timeout_ms, 1_000))

    assert {:ok, lease} = Budget.acquire(core, opts)
    assert :ok = Budget.release(lease, opts)
  end

  # #2409 root cause: GitHub meters `/search/*` against its own ~30 req/min
  # pool, so a search response must be classified as `search` — never folded
  # into `core`. Before this fix a search-pool exhaustion (a `search` header
  # with `remaining: 0`) fell through `response_resource` to the request's
  # bucket and created a *core* hold, which then denied every core request —
  # including dispatch-authorization timeline fetches — until the search pool
  # reset.
  test "a search-pool exhaustion holds only search, never core", %{root: root} do
    opts = [state_dir: root, max_inflight: 4, max_inflight_per_endpoint: 2, requests_per_minute: 20, stagger_ms: 0]
    core = request("shared-token", "/repos/owner/repo/issues/1477")
    search = request("shared-token", "/search/issues?q=repo:owner/repo+label:agent")
    reset_at = System.system_time(:second) + 60

    assert Budget.request_resource(search) == "search"
    assert Budget.request_resource(core) == "core"

    response =
      {:ok,
       %{
         status: 200,
         headers: [
           {"x-ratelimit-resource", "search"},
           {"x-ratelimit-remaining", "0"},
           {"x-ratelimit-reset", Integer.to_string(reset_at)}
         ]
       }}

    assert :ok = Budget.observe(core, response, opts)

    # The search pool is held...
    assert {:hold, %{reason: :shared_budget, resource: "search"}} =
             Budget.acquire(search, Keyword.put(opts, :timeout_ms, 1_000))

    # ...but core is untouched: the timeline fetch that dispatch authorization
    # relies on still goes through.
    assert {:ok, lease} = Budget.acquire(core, opts)
    assert :ok = Budget.release(lease, opts)
  end

  test "a rate-limit pool the guard does not model never becomes a core hold", %{root: root} do
    opts = [state_dir: root, max_inflight: 4, max_inflight_per_endpoint: 2, requests_per_minute: 20, stagger_ms: 0]
    core = request("shared-token", "/repos/owner/repo/issues/1477")
    reset_at = System.system_time(:second) + 60

    response =
      {:ok,
       %{
         status: 200,
         headers: [
           {"x-ratelimit-resource", "integration_manifest"},
           {"x-ratelimit-remaining", "0"},
           {"x-ratelimit-reset", Integer.to_string(reset_at)}
         ]
       }}

    assert :ok = Budget.observe(core, response, opts)

    # No modeled pool was exhausted, so no resource hold is issued — a core
    # request must not be held because some other GitHub pool reset.
    assert {:ok, lease} = Budget.acquire(core, opts)
    assert :ok = Budget.release(lease, opts)
  end

  test "simultaneous fan-out is staggered and reports the measured burst width", %{root: root} do
    opts = [state_dir: root, max_inflight: 6, max_inflight_per_endpoint: 6, requests_per_minute: 20, stagger_ms: 10]
    request = request("shared-token", "/repos/owner/repo/pulls/1477/reviews")

    leases =
      1..4
      |> Task.async_stream(fn _ -> Budget.acquire(request, opts) end, max_concurrency: 4, timeout: 2_000)
      |> Enum.map(fn {:ok, {:ok, lease}} -> lease end)

    snapshot = Budget.snapshot("shared-token", opts)
    admitted_at = Enum.map(snapshot.admissions, & &1.admitted_at_ms)

    assert length(admitted_at) == 4
    assert Enum.max(admitted_at) - Enum.min(admitted_at) >= 3

    Enum.each(leases, &Budget.release(&1, opts))
  end

  test "keeps token material out of the broker key and endpoint names remain bounded" do
    key = Budget.token_key("secret-token-value")

    assert key =~ ~r/\A[a-f0-9]{64}\z/
    refute key =~ "secret"
    assert Budget.endpoint_family(request("token", "/repos/owner/repo/issues/1477/comments")) == "issues"
    assert Budget.endpoint_family(request("token", "/graphql")) == "graphql"
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
    # ceiling, and the hold names the actor budget as the reason.
    assert {:hold, %{reason: :actor_budget, resource: "core"}} =
             Budget.acquire(request, Keyword.put(opts, :timeout_ms, 200))

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

    # Core is at its ceiling of 2.
    assert {:hold, %{reason: :actor_budget, resource: "core"}} =
             Budget.acquire(core, Keyword.put(opts, :timeout_ms, 200))

    # GraphQL still has headroom (0 of 1 used), so it is admitted.
    assert {:ok, g1} = Budget.acquire(graphql, opts)

    # Now GraphQL is at its ceiling of 1, and the hold names the graphql resource.
    assert {:hold, %{reason: :actor_budget, resource: "graphql"}} =
             Budget.acquire(graphql, Keyword.put(opts, :timeout_ms, 200))

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

    actor =
      opts
      |> Budget.usage()
      |> Map.fetch!(:actors)
      |> Enum.find(&(&1.consumer_key == Budget.token_key("workspace:/conditional-reader")))

    assert actor.core.used == 0
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
      assert {:ok, lease} = Budget.acquire(request, opts)
      assert :ok = Budget.release(lease, opts)
    end

    hold_opts = Keyword.put(opts, :timeout_ms, 200)

    assert {:hold, %{reason: :actor_budget}} = Budget.acquire(request, hold_opts)
    assert_receive {:budget_alert, "system.github.budget_meter_disagreement", alert_opts}
    assert alert_opts[:needs_attention]
    assert alert_opts[:reason] =~ "local billed=2/2"
    assert alert_opts[:reason] =~ "GitHub used=0/10"

    assert {:hold, %{reason: :actor_budget}} = Budget.acquire(request, hold_opts)
    refute_receive {:budget_alert, _, _}

    observe_headroom(request, limit: 10, remaining: 8, reset: reset)
    assert {:hold, %{reason: :actor_budget}} = Budget.acquire(request, hold_opts)
    refute_receive {:budget_alert, _, _}

    observe_headroom(request, limit: 10, remaining: 10, reset: reset)
    assert {:hold, %{reason: :actor_budget}} = Budget.acquire(request, hold_opts)
    assert_receive {:budget_alert, "system.github.budget_meter_disagreement", _alert_opts}
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
    # the exact contradiction that stalled the fleet in #2278.
    assert :ok =
             Budget.observe(
               issues,
               {:ok, %{status: 403, headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "5"}], body: %{"message" => "rate limit exceeded"}}},
               opts
             )

    observe_headroom(pulls, limit: 100, remaining: 100, reset: reset)

    assert {:hold, %{reason: :shared_budget}} = Budget.acquire(pulls, opts)
    assert_receive {:budget_alert, "system.github.budget_meter_disagreement", alert_opts}
    assert alert_opts[:needs_attention]
    assert alert_opts[:reason] =~ "shared budget hold contradicts"
    assert alert_opts[:reason] =~ "remaining=100/100"

    assert {:hold, %{reason: :shared_budget}} = Budget.acquire(pulls, opts)
    refute_receive {:budget_alert, _, _}

    # GitHub agreeing that the credential really is spent clears the signal, so
    # the next genuine divergence is still able to speak.
    observe_headroom(pulls, limit: 100, remaining: 0, reset: reset)
    assert {:hold, %{reason: :shared_budget}} = Budget.acquire(pulls, opts)
    refute_receive {:budget_alert, _, _}

    observe_headroom(pulls, limit: 100, remaining: 100, reset: reset)
    assert {:hold, %{reason: :shared_budget}} = Budget.acquire(pulls, opts)
    assert_receive {:budget_alert, "system.github.budget_meter_disagreement", _alert_opts}
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

  defp request(token, path), do: %{method: :get, url: "https://api.github.com#{path}", token: token}

  defp secondary_response(seconds) do
    {:ok,
     %{
       status: 403,
       headers: [
         {"x-ratelimit-resource", "core"},
         {"x-ratelimit-limit", "5000"},
         {"x-ratelimit-remaining", "0"},
         {"x-ratelimit-reset", Integer.to_string(System.system_time(:second) + 60)},
         {"retry-after", Integer.to_string(seconds)}
       ],
       body: %{"message" => "You have exceeded a secondary rate limit."}
     }}
  end

  defp observe_headroom(request, opts) do
    CredentialHeadroom.observe(
      request,
      {:ok,
       %{
         status: 200,
         headers: [
           {"x-ratelimit-resource", "core"},
           {"x-ratelimit-limit", Integer.to_string(opts[:limit])},
           {"x-ratelimit-remaining", Integer.to_string(opts[:remaining])},
           {"x-ratelimit-reset", Integer.to_string(opts[:reset])}
         ]
       }}
    )
  end

  defp lock_database(path) do
    python = System.find_executable("python3") || flunk("python3 is required")

    script = "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute('BEGIN EXCLUSIVE'); print('locked', flush=True); time.sleep(30)"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(python)},
        [:binary, :exit_status, :stderr_to_stdout, args: [~c"-c", String.to_charlist(script), String.to_charlist(path)]]
      )

    on_exit(fn -> close_port(port) end)
    assert_receive {^port, {:data, "locked\n"}}, 2_000
    port
  end

  # Direct injection of a policy row whose `observed_at_ms` is ten minutes in
  # the past, so the concurrency reconcile must ignore it while the usage report
  # still retains it (the report's window is an hour, the reconcile's is two
  # minutes).
  defp insert_stale_policy(db, token_key) do
    stale_at = System.system_time(:millisecond) - 10 * 60 * 1_000

    script =
      "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); " <>
        "c.execute(\"INSERT INTO policies(token_key, consumer_key, consumer_label, max_inflight, " <>
        "max_inflight_per_endpoint, requests_per_minute, stagger_ms, core_limit_per_hour, " <>
        "graphql_limit_per_hour, observed_at_ms) VALUES (?,?,?,1,1,1,0,3,5,?)\", " <>
        "(sys.argv[2], 'stale', 'workspace:/stale', int(sys.argv[3]))); c.commit()"

    {_output, 0} =
      System.cmd("python3", ["-c", script, db, token_key, Integer.to_string(stale_at)], stderr_to_stdout: true)

    :ok
  end

  defp create_legacy_budget_database(db) do
    script =
      "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); " <>
        "c.execute('CREATE TABLE admissions (id INTEGER PRIMARY KEY AUTOINCREMENT, token_key TEXT NOT NULL, " <>
        "consumer_key TEXT NOT NULL DEFAULT \\\'\\\', endpoint_family TEXT NOT NULL, admitted_at_ms INTEGER NOT NULL)'); " <>
        "c.commit()"

    assert {_output, 0} = System.cmd("python3", ["-c", script, db], stderr_to_stdout: true)
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp broker_wrapper(root, pid_path) do
    path = Path.join(root, "python-wrapper")
    File.write!(path, "#!/bin/sh\nprintf '%s' \"$$\" > \"#{pid_path}\"\nexec python3 \"$@\"\n")
    File.chmod!(path, 0o755)
    path
  end

  defp os_process_alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true) do
      {status, 0} -> not String.starts_with?(String.trim(status), "Z")
      {_output, _status} -> false
    end
  end

  defp wait_until(predicate, attempts \\ 100) do
    cond do
      predicate.() -> :ok
      attempts <= 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(predicate, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
