defmodule Aiur.GitHub.BudgetTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Budget

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-github-budget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous = Application.get_env(:aiur, :github_budget_enabled?)
    Application.put_env(:aiur, :github_budget_enabled?, true)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:github_budget_enabled?, previous)
    end)

    {:ok, root: root}
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
               {:ok, %{status: 403, headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "1"}], body: %{"message" => "rate limit exceeded"}}},
               opts
             )

    assert {:hold, %{reason: :shared_budget}} = Budget.acquire(pulls, Keyword.put(opts, :timeout_ms, 10))
  end

  test "a configured broker failure fails closed", %{root: root} do
    opts = [state_dir: root, enabled?: true, python: Path.join(root, "missing-python"), timeout_ms: 10]

    assert {:hold, %{reason: :shared_budget}} =
             Budget.acquire(request("shared-token", "/repos/owner/repo/issues/1477"), opts)
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
             Budget.acquire(graphql, Keyword.put(opts, :timeout_ms, 10))

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

  defp request(token, path), do: %{method: :get, url: "https://api.github.com#{path}", token: token}

  defp secondary_response(seconds) do
    {:ok,
     %{
       status: 403,
       headers: [
         {"x-ratelimit-resource", "core"},
         {"x-ratelimit-limit", "5000"},
         {"x-ratelimit-remaining", "4077"},
         {"retry-after", Integer.to_string(seconds)}
       ],
       body: %{"message" => "You have exceeded a secondary rate limit."}
     }}
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
