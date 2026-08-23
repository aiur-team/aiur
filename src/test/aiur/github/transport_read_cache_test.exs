defmodule Aiur.GitHub.TransportReadCacheTest do
  @moduledoc """
  Proof that the cache is actually at the chokepoint.

  `Aiur.GitHub.ReadCacheTest` asserts what the cache does when it is called.
  This asserts that `Aiur.GitHub.Transport` calls it — and, more importantly,
  that a hit is served *before* quota preflight and the socket, which is the
  only reason a hit saves a point. A cache consulted after the request was
  priced and sent would pass every test in the other file and save nothing.
  """

  use ExUnit.Case, async: false

  alias Aiur.GitHub.{Quota, ReadCache, Transport}

  setup do
    {:ok, _started} = Application.ensure_all_started(:req)
    previous_options = Application.get_env(:aiur, :github_transport_test_options)
    previous_quota = Application.get_env(:aiur, :github_quota_server)
    previous_budget_enabled = Application.get_env(:aiur, :github_budget_enabled?)

    quota = start_supervised!({Quota, name: nil, emit_fun: fn _name, _opts -> :ok end})

    Application.put_env(:aiur, :github_transport_test_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:aiur, :github_quota_server, quota)
    Application.put_env(:aiur, :github_budget_enabled?, false)

    await_read_cache()
    ReadCache.reset()

    on_exit(fn ->
      restore_env(:github_transport_test_options, previous_options)
      restore_env(:github_quota_server, previous_quota)
      restore_env(:github_budget_enabled?, previous_budget_enabled)
      ReadCache.reset()
    end)

    {:ok, quota: quota}
  end

  test "a repeated cacheable GraphQL read never reaches the socket or the quota meter", %{quota: quota} do
    test_process = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_process, :request_sent)
      Req.Test.json(conn, %{"data" => %{"repository" => %{"t0" => %{"title" => "a ticket"}}}})
    end)

    request = fn ->
      Transport.default_request_fun(%{
        method: :post,
        url: Transport.graphql_url(),
        token: "test-gh-token",
        caller: "issue_relationships",
        body: %{
          "query" => "query Q($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { t0: issueOrPullRequest(number: 2073) { ... on Issue { title } } } }",
          "variables" => %{"owner" => "aiur-team", "repo" => "aiur"}
        }
      })
    end

    assert {:ok, %{status: 200}} = request.()
    assert_receive :request_sent

    calls_after_first = Quota.snapshot(quota) |> attributed_calls()

    assert {:ok, %{status: 200, body: %{"data" => _data}}} = request.()
    refute_receive :request_sent, 50

    # The saving is only real if the second read also went unpriced. A cache
    # that returned early but still billed would look identical from the caller.
    assert calls_after_first == Quota.snapshot(quota) |> attributed_calls()
    assert %{totals: %{hit: 1, miss: 1, deposit: 1}} = ReadCache.snapshot()
  end

  test "a CI status read reaches the socket every time" do
    test_process = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_process, :request_sent)
      Req.Test.json(conn, %{"data" => %{"repository" => %{}}})
    end)

    request = fn ->
      Transport.default_request_fun(%{
        method: :post,
        url: Transport.graphql_url(),
        token: "test-gh-token",
        caller: "ci_poll_batch",
        body: %{
          "query" =>
            "query C($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { b0: pullRequests(headRefName: \"x\") { nodes { commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } } }",
          "variables" => %{"owner" => "aiur-team", "repo" => "aiur"}
        }
      })
    end

    assert {:ok, %{status: 200}} = request.()
    assert_receive :request_sent
    assert {:ok, %{status: 200}} = request.()
    assert_receive :request_sent

    assert %{refused: %{unsafe_kind: 2}, totals: %{hit: 0}} = ReadCache.snapshot()
  end

  # The cache is a shared application child that a sibling test may have
  # stopped (its ETS tables die with the process, so `snapshot/0` answers
  # `available?: false` with no entries and every read becomes a full-price
  # miss). Ensure the app-owned child is running — restarting it if a sibling
  # left it down — rather than racing it with a wall-clock poll or
  # `start_supervised!`-ing a temporary replacement that dies at module end
  # (#2397). Signal-based: the registered name answers "up".
  defp await_read_cache do
    :ok = Aiur.TestSupport.ensure_read_cache_running()
    true = ReadCache.snapshot().available?
    :ok
  end

  defp attributed_calls(snapshot) do
    snapshot |> Map.get(:callers, []) |> Enum.reduce(0, fn caller, total -> total + caller.calls end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
