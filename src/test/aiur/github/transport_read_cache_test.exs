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
  alias Aiur.Webhooks.ModeTable

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

  test "the :pull TTL owns within-window repeats; If-None-Match is the post-expiry backstop" do
    # #2352 review, point 2: `Client.fetch_open_pull_request` runs through the
    # transport read cache, whose `:pull` entry key is `{method, url, body}` and
    # carries no validator. So inside the TTL a repeat is served the held body —
    # a cache hit, with no request at all and no `If-None-Match` sent — and the
    # ETag path only fires once the entry expires. This drives both layers
    # together through the real transport (an injected `request_fun` would
    # bypass the cache, which is why none of the diff's earlier tests saw the
    # interplay): the first read is a 200 + deposit, the second is a cache hit,
    # and after expiry the third read sends `If-None-Match` and GitHub's `304`
    # is the free answer.
    ModeTable.delete("owner/repo")
    on_exit(fn -> ModeTable.delete("owner/repo") end)

    test_process = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_process, {:pulls_request, Plug.Conn.get_req_header(conn, "if-none-match")})

      case Plug.Conn.get_req_header(conn, "if-none-match") do
        [] ->
          conn
          |> Plug.Conn.put_resp_header("etag", ~s("v1"))
          |> Req.Test.json(%{"number" => 4242, "state" => "open", "head" => %{"ref" => "x"}})

        [_etag] ->
          conn
          |> Plug.Conn.put_resp_header("etag", ~s("v1"))
          |> Plug.Conn.send_resp(304, "")
      end
    end)

    url = "https://api.github.com/repos/owner/repo/pulls/4242"
    unconditional = %{method: :get, url: url, token: "test-gh-token"}

    # First read: a `:pull` miss, so the request reaches the socket and the
    # body (with its ETag) is deposited.
    assert {:ok, %{status: 200, body: %{"number" => 4242}}} = Transport.default_request_fun(unconditional)
    assert_receive {:pulls_request, []}
    assert %{totals: %{hit: 0, miss: 1, deposit: 1}} = ReadCache.snapshot()

    # Second read inside the TTL: a cache hit. No request is sent and no
    # If-None-Match is produced — the TTL owns this window.
    assert {:ok, %{status: 200, body: %{"number" => 4242}}} = Transport.default_request_fun(unconditional)
    refute_receive {:pulls_request, _}, 50
    assert %{totals: %{hit: 1, miss: 1, deposit: 1}} = ReadCache.snapshot()

    # Once the entry expires, the conditional read carries the held validator
    # and GitHub's 304 is the free backstop.
    age_entries_by(31_000)

    assert {:ok, %{status: 304}} =
             Transport.default_request_fun(Map.put(unconditional, :etag, ~s("v1")))

    assert_receive {:pulls_request, [~s("v1")]}
    assert %{totals: %{hit: 1, miss: 2, deposit: 1}} = ReadCache.snapshot()
  end

  # The cache is an application child that another test may have stopped; wait
  # for its supervisor rather than racing it.
  defp await_read_cache(attempts \\ 100) do
    cond do
      ReadCache.snapshot().available? -> :ok
      attempts > 0 -> Process.sleep(10) || await_read_cache(attempts - 1)
      true -> start_supervised!({ReadCache, sweep_interval_ms: 0})
    end
  end

  defp attributed_calls(snapshot) do
    snapshot |> Map.get(:callers, []) |> Enum.reduce(0, fn caller, total -> total + caller.calls end)
  end

  # Rewrites the deposit stamps rather than sleeping. The freshness test is
  # arithmetic on a stored timestamp, so moving the timestamp exercises exactly
  # what a real TTL expiry exercises, in no time at all (same trick as
  # `Aiur.GitHub.ReadCacheTest`).
  defp age_entries_by(ms) do
    table = :aiur_github_read_cache_entries

    for {key, response, deposited_at} <- :ets.tab2list(table) do
      :ets.insert(table, {key, response, deposited_at - ms})
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
