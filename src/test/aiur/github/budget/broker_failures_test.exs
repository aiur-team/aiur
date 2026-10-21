defmodule Aiur.GitHub.Budget.BrokerFailuresTest do
  use ExUnit.Case, async: false

  import Aiur.GitHub.BudgetTestSupport

  alias Aiur.GitHub.BudgetTestSupport

  alias Aiur.GitHub.Budget

  setup do
    BudgetTestSupport.setup()
  end

  test "database lock cannot hold admission beyond its wall-clock budget", %{root: root} do
    broker_pid_path = Path.join(root, "broker.pid")
    python = broker_wrapper(root, broker_pid_path)

    opts = [
      state_dir: root,
      enabled?: true,
      kill_fun: fn pid ->
        Process.sleep(500)
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      end
    ]

    token = "locked-budget-token"

    # Create schema first so the exclusive lock blocks admission, not setup.
    assert %{inflight: %{}} = Budget.snapshot(token, opts)
    lock = lock_database(Budget.database_path(opts))

    started_at = System.monotonic_time(:millisecond)

    # A lock beyond the 300 ms deadline must classify as timeout, not malformed (#2286).
    assert {:error, :github_budget_broker_timeout} =
             Budget.acquire(
               request(token, "/repos/owner/repo/issues/1477"),
               opts |> Keyword.put(:python, python) |> Keyword.put(:timeout_ms, 300)
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms >= 250
    assert elapsed_ms < 1_000
    broker_pid = broker_pid_path |> File.read!() |> String.trim()
    assert_process_exits(broker_pid)

    close_port(lock)
  end

  test "database lock cannot hold release beyond its absolute deadline", %{root: root} do
    broker_pid_path = Path.join(root, "release-broker.pid")
    python = broker_wrapper(root, broker_pid_path)
    opts = [state_dir: root, enabled?: true]
    request = request("locked-release-token", "/repos/owner/repo/issues/1477")

    # Exclude setup acquire from the 300 ms release deadline; loaded runners can
    # spend longer than that creating the broker database (#1983).
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
    assert_process_exits(broker_pid)

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
    assert_process_exits(broker_pid)
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

    # The deadline is generous so the fake broker is allowed to answer: this
    # assertion tests that a malformed `wait` reply classifies as
    # `:github_budget_broker_unavailable`, not that the subprocess can start
    # within a deadline competitive with `python3` startup under CI load — a
    # tight deadline would degrade the verdict to `:github_budget_broker_timeout`
    # and fail the wrong assertion (#2286).
    assert {:error, :github_budget_broker_unavailable} =
             Budget.acquire(
               request("shared-token", "/repos/owner/repo/issues/1477"),
               state_dir: root,
               enabled?: true,
               python: fake_python,
               timeout_ms: 1_000
             )
  end

  # #4791: a retry that times out is a hold only when the admission deadline cut it off.
  describe "a broker that answers wait and then stalls" do
    setup %{root: root} do
      server = start_supervised!({__MODULE__.WaitThenStallBroker, test: self()})
      %{opts: [state_dir: root, enabled?: true, broker_server: server]}
    end

    test "is a broker timeout when the per-command bound fires with admission time left", %{opts: opts} do
      acquire =
        Task.async(fn ->
          Budget.acquire(request("shared-token", "/repos/owner/repo/issues/1"), opts ++ [timeout_ms: 5_000, command_timeout_ms: 1_000])
        end)

      assert_receive {:broker_call, 2}, 1_000
      assert {:error, :github_budget_broker_timeout} = Task.await(acquire, 2_000)
    end

    test "is a hold when the admission deadline cuts the retry off", %{opts: opts} do
      acquire =
        Task.async(fn ->
          Budget.acquire(request("shared-token", "/repos/owner/repo/issues/1"), opts ++ [timeout_ms: 1_500, command_timeout_ms: 5_000])
        end)

      assert_receive {:broker_call, 2}, 1_000
      assert {:hold, %{reason: :shared_budget}} = Task.await(acquire, 2_000)
    end
  end

  test "a first attempt cut off by the admission deadline stays a broker timeout", %{root: root} do
    fake_python = Path.join(root, "stalled-broker")
    File.write!(fake_python, "#!/bin/sh\nsleep 10\n")
    File.chmod!(fake_python, 0o755)

    assert {:error, :github_budget_broker_timeout} =
             Budget.acquire(request("shared-token", "/repos/owner/repo/issues/1"), state_dir: root, enabled?: true, python: fake_python, timeout_ms: 500)
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

  defmodule WaitThenStallBroker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{test: opts[:test], calls: 0}}

    @impl true
    def handle_call({:command, _broker, _args, _deadline_at, _submitted_at}, _from, %{calls: 0} = state) do
      {:reply, {:ok, "wait 50", 0}, %{state | calls: 1}}
    end

    def handle_call({:command, _broker, _args, deadline_at, _submitted_at}, from, state) do
      send(state.test, {:broker_call, 2})
      delay = max(deadline_at - System.monotonic_time(:millisecond), 0)
      Process.send_after(self(), {:reply_timeout, from}, delay)
      {:noreply, %{state | calls: 2}}
    end

    @impl true
    def handle_info({:reply_timeout, from}, state) do
      GenServer.reply(from, :timeout)
      {:noreply, state}
    end
  end
end
