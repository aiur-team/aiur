defmodule Aiur.GitHub.ReadCache.SafetyAndReadThroughTest do
  @moduledoc """
  The properties the daemon read cache is worth having only if it holds.

  Three of them are safety, and they are asserted first: a CI verdict is never
  served from cache, review state is never served from cache, and an
  unrecognised read is never served from cache. A cache that fails any of those
  is worse than no cache, because the fleet would act on a check that has since
  failed.

  The rest are effectiveness: a hit costs nothing, a write retires what it
  changed, and every one of those events is counted — the metric the agent-side
  cache shipped without, which is why nobody can say whether that one worked.
  """

  use ExUnit.Case, async: false

  alias Aiur.GitHub.ReadCache
  alias Aiur.GitHub.ReadCache.Metrics
  alias Aiur.GitHub.ReadCache.Policy
  alias Aiur.Webhooks.ModeTable

  @repo "aiur-team/aiur"

  # The cache is an application child, so it is already running. Each test starts
  # from an empty store rather than from its own process, which is also the
  # shape the daemon runs in.
  setup do
    await_read_cache()
    ReadCache.reset()
    # The TTL is mode-aware now, and these tests exercise the 30-second bucket
    # for `@repo`. Ensure it is in polling mode so a stray webhook-backed record
    # (from any test anywhere) cannot turn a 31-second ageing into a hit.
    ModeTable.delete(@repo)
    on_exit(&ReadCache.reset/0)
    :ok
  end

  # The cache is an application child, so a test that stops it hands the restart
  # to its supervisor rather than to ExUnit. Waiting for that restart is the
  # difference between a suite that is order-independent and one that fails on
  # whichever test happens to run next.
  defp await_read_cache(attempts \\ 100) do
    cond do
      # Availability rather than registration: the name is registered before
      # `init/1` builds the tables, so a `whereis` can return a pid that has no
      # store behind it yet.
      ReadCache.snapshot().available? -> :ok
      attempts > 0 -> Process.sleep(10) || await_read_cache(attempts - 1)
      true -> start_supervised!({ReadCache, sweep_interval_ms: 0})
    end
  end

  describe "safety: kinds that are never cached" do
    test "does not cache a document selecting a CI status rollup" do
      request = graphql("ci_poll_batch", ci_document())

      assert {:no_cache, :unsafe_kind} = Policy.classify(request)
      assert 2 = counted_fetches(request)
      assert %{refused: %{unsafe_kind: 2}} = Metrics.snapshot()
    end

    test "refuses a CI rollup whichever call site sends it" do
      # The refusal is on content, so a new caller cannot acquire a cacheable
      # TTL by not being in the policy table.
      assert {:no_cache, :unsafe_kind} = Policy.classify(graphql("issue_relationships", ci_document()))
      assert {:no_cache, :unsafe_kind} = Policy.classify(graphql("some_new_caller", ci_document()))
    end

    test "required-check configuration is cacheable" do
      request = rest("https://api.github.com/repos/aiur-team/aiur/branches/main/protection") |> Map.put(:caller, "ci_required_checks")
      assert {:cache, :repo_config, 300_000} = Policy.classify(request)
    end

    test "does not cache review state or merge gating" do
      for selection <- ["reviewDecision", "mergeStateStatus", "mergeable", "reviewThreads(first: 10) { nodes { id } }"] do
        request = graphql("issue_relationships", "query Q { repository(owner: $o, name: $n) { #{selection} } }")
        assert {:no_cache, :unsafe_kind} = Policy.classify(request)
      end
    end

    test "does not cache REST reads of checks, statuses or reviews" do
      for path <- ["/commits/abc/check-runs", "/check-suites", "/pulls/7/reviews", "/pulls/7/requested_reviewers"] do
        assert {:no_cache, :unsafe_kind} = Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur#{path}"))
      end
    end

    test "the cached single-pull-request body is a routing source, never a merge verdict source" do
      # Row 5 of #2352 gives `/pulls/{n}` a body cache, and that body carries
      # merge-gating fields (`mergeable`, `mergeable_state`, `merged`,
      # `requested_reviewers`, `auto_merge`) that the safety section refuses on
      # content. The cache exists for the routing decision — "is there an open
      # PR, what is its head ref/title/body" — and the `:pull` moduledoc names
      # the fields a reader must not take from it. This pins the policy
      # boundary: the parent stays cacheable for routing while every REST
      # endpoint that answers the verdict fields stays refused, so a call site
      # cannot reach a merge verdict through the REST family either.
      assert {:cache, :pull, _ttl} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/pulls/2073"))

      for path <- ["/pulls/2073/merge", "/pulls/2073/requested_reviewers", "/pulls/2073/reviews"] do
        assert {:no_cache, :unsafe_kind} = Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur#{path}")),
               "#{path} must not acquire a cacheable TTL"
      end
    end

    test "does not cache a read it has no classification for" do
      request = graphql("an_unheard_of_caller", safe_document(2073))

      assert {:no_cache, :unclassified} = Policy.classify(request)
      assert 2 = counted_fetches(request)
      assert %{refused: %{unclassified: 2}} = Metrics.snapshot()
    end

    test "does not cache a read whose repository cannot be named" do
      request = %{method: :post, url: "https://api.github.com/graphql", body: %{"query" => "query Q { viewer { login } }", "variables" => %{}}, caller: "bot_identity"}

      assert {:no_cache, :no_identity} = Policy.classify(request)
    end

    test "does not deposit a failed response" do
      request = graphql("issue_relationships", safe_document(2073))

      assert {:ok, %{status: 502}} = ReadCache.through(request, fn -> {:ok, %{status: 502, body: %{}}} end)
      assert %{totals: %{deposit: 0}} = Metrics.snapshot()
      assert 0 = ReadCache.snapshot().entries
    end

    test "does not deposit a GraphQL failure or partial failure arriving as HTTP 200" do
      request = graphql("issue_relationships", safe_document(2073))
      partial = {:ok, %{status: 200, body: %{"data" => %{"repository" => nil}, "errors" => [%{"type" => "RATE_LIMITED"}]}}}

      assert ^partial = ReadCache.through(request, fn -> partial end)
      assert 0 = ReadCache.snapshot().entries
      assert %{totals: %{deposit: 0, miss: 1}} = Metrics.snapshot()
    end

    test "a write that reached the server retires even when it failed there" do
      read = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "first"}} end)

      write = %{method: :patch, url: "https://api.github.com/repos/aiur-team/aiur/issues/2073", body: %{}}
      assert {:ok, %{status: 500}} = ReadCache.through(write, fn -> {:ok, %{status: 500, body: %{}}} end)

      assert {:ok, %{body: "second"}} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "second"}} end)
    end
  end

  describe "read-through" do
    test "serves a second identical read without fetching" do
      request = graphql("issue_relationships", safe_document(2073))

      assert {:ok, %{body: "first"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)
      assert {:ok, %{body: "first"}} = ReadCache.through(request, fn -> flunk("a hit must not fetch") end)

      assert %{totals: %{hit: 1, miss: 1, deposit: 1}} = Metrics.snapshot()
      assert 0.5 == ReadCache.snapshot().hit_rate
    end

    test "does not serve one query shape from another shape's response" do
      # Identity decides invalidation; the shape decides which bytes are served.
      # Replaying a different projection would corrupt the caller silently.
      first = graphql("issue_relationships", safe_document(2073))
      second = graphql("issue_relationships", safe_document(2073) <> "\n# a different projection")

      assert {:ok, _response} = ReadCache.through(first, fn -> {:ok, %{status: 200, body: "first"}} end)
      assert {:ok, %{body: "second"}} = ReadCache.through(second, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "misses once the TTL has passed" do
      request = graphql("issue_relationships", safe_document(2073))

      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)
      age_entries_by(31_000)

      assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
      assert %{totals: %{hit: 0, miss: 2}} = Metrics.snapshot()
    end

    test "misses an entry stamped in the future rather than reasoning about it" do
      request = graphql("issue_relationships", safe_document(2073))

      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)
      age_entries_by(-60_000)

      assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    # #2298 acceptance 5: classifying repository-configuration reads gives the
    # read cache a non-zero hit rate and stops counting them as `unclassified`.
    test "a repeated repository-config read is served from cache" do
      request = rest("https://api.github.com/repos/aiur-team/aiur/actions/workflows?per_page=100")

      assert {:cache, :repo_config, _ttl} = Policy.classify(request)

      assert {:ok, %{body: "config"}} =
               ReadCache.through(request, fn -> {:ok, %{status: 200, body: "config"}} end)

      assert {:ok, %{body: "config"}} =
               ReadCache.through(request, fn -> flunk("a repo-config hit must not fetch") end)

      assert %{totals: %{hit: 1, miss: 1, deposit: 1}, refused: %{}} = Metrics.snapshot()
      assert ReadCache.snapshot().hit_rate > 0
    end

    # #2352 acceptance: rows 1, 4 and 5 show cache hits. Each of the three
    # genuinely cacheable families serves its second read from the meter.
    test "a repeated timeline read is served from cache" do
      request = rest("https://api.github.com/repos/aiur-team/aiur/issues/2073/timeline?per_page=100")
      assert {:cache, :issue_timeline, _ttl} = Policy.classify(request)

      assert {:ok, %{body: "timeline"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "timeline"}} end)
      assert {:ok, %{body: "timeline"}} = ReadCache.through(request, fn -> flunk("a timeline hit must not fetch") end)
    end

    test "a repeated single-issue read is served from cache" do
      request = rest("https://api.github.com/repos/aiur-team/aiur/issues/2073")
      assert {:cache, :issue, _ttl} = Policy.classify(request)

      assert {:ok, %{body: "issue"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "issue"}} end)
      assert {:ok, %{body: "issue"}} = ReadCache.through(request, fn -> flunk("an issue hit must not fetch") end)
    end

    test "a repeated single-pull-request read is served from cache" do
      request = rest("https://api.github.com/repos/aiur-team/aiur/pulls/2073")
      assert {:cache, :pull, _ttl} = Policy.classify(request)

      assert {:ok, %{body: "pr"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "pr"}} end)
      assert {:ok, %{body: "pr"}} = ReadCache.through(request, fn -> flunk("a pull hit must not fetch") end)

      assert %{totals: %{hit: 1, miss: 1, deposit: 1}} = Metrics.snapshot()
    end
  end

  defp graphql(caller, document, variables \\ %{"owner" => "aiur-team", "repo" => "aiur"}) do
    %{method: :post, url: "https://api.github.com/graphql", token: "t", body: %{"query" => document, "variables" => variables}, caller: caller}
  end

  defp rest(url), do: %{method: :get, url: url, token: "t"}

  defp safe_document(number) do
    "query Q($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { t0: issueOrPullRequest(number: #{number}) { ... on Issue { title } } } }"
  end

  defp ci_document do
    "query C($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { t0: issueOrPullRequest(number: 2073) { ... on PullRequest { commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } } }"
  end

  # Runs the same request twice and answers how many times the fetcher ran, so a
  # "not cached" assertion is about observed behaviour rather than about policy
  # agreeing with itself.
  defp counted_fetches(request) do
    counter = :counters.new(1, [])
    fetch = fn -> :counters.add(counter, 1, 1) && {:ok, %{status: 200, body: "x"}} end

    ReadCache.through(request, fetch)
    ReadCache.through(request, fetch)

    :counters.get(counter, 1)
  end

  # Rewrites the deposit stamps rather than sleeping. The freshness test is
  # arithmetic on a stored timestamp, so moving the timestamp exercises exactly
  # what a real TTL expiry exercises, in no time at all.
  defp age_entries_by(ms) do
    table = :aiur_github_read_cache_entries

    for {key, response, deposited_at} <- :ets.tab2list(table) do
      :ets.insert(table, {key, response, deposited_at - ms})
    end
  end
end
