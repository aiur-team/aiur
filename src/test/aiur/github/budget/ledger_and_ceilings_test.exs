defmodule Aiur.GitHub.Budget.LedgerAndCeilingsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Aiur.GitHub.BudgetTestSupport

  alias Aiur.GitHub.BudgetTestSupport

  alias Aiur.GitHub.Budget

  setup do
    BudgetTestSupport.setup()
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
    opts = [state_dir: root, enabled?: true, python: Path.join(root, "missing-python"), timeout_ms: 1_000]

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
end
