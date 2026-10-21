defmodule Aiur.GitHub.ReadCache.PolicyShapesTest do
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

  describe "policy coverage" do
    test "every declared class and refusal reason is nameable, so a report has no gaps" do
      assert :comments in Policy.classes()
      assert :unsafe_kind in Policy.no_cache_reasons()
      assert :unclassified in Policy.no_cache_reasons()
    end

    test "the shape set is small and bounded, so the refusal metric cannot grow" do
      # #2352 defect: a pathological URL must not be able to grow the refusal
      # metric map. The shapes come from a fixed classifier list (well under the
      # ~200 cap), and `Metrics.refused/2` folds anything else to
      # `:unclassified`, so the cap is structural rather than aspirational.
      assert length(Policy.shapes()) < 200
      assert :unclassified in Policy.shapes()
      assert :issue_list in Policy.shapes()
      assert :pull in Policy.shapes()
    end

    test "declares no class that identity cannot reach" do
      # A TTL row for a resource identity cannot name is a claimed saving that
      # can never happen. `:viewer` and `:org` were exactly that: repo-less
      # reads that refuse at `:no_identity` long before a TTL is consulted.
      # This asserts the table cannot drift back into advertising them.
      viewer = %{method: :post, url: "https://api.github.com/graphql", body: %{"query" => "query Q { viewer { login } }", "variables" => %{}}, caller: "bot_identity"}
      teams = rest("https://api.github.com/orgs/aiur-team/teams/reviewers/members?per_page=100")

      assert {:no_cache, :no_identity} = Policy.classify(viewer)
      assert {:no_cache, :no_identity} = Policy.classify(teams)
      refute :viewer in Policy.classes()
      refute :org in Policy.classes()
    end

    test "a repository workflow-config read is cacheable but is not a CODEOWNERS read" do
      # `/contents/` once bought a five-minute TTL for any file in the repo. The
      # only caller of one is `CIReadiness` listing `.github/workflows`, which is
      # CI *configuration*, not a CI verdict — #2298 narrows the unsafe regex and
      # classifies it, but it must never be mislabelled as a CODEOWNERS read.
      workflows = rest("https://api.github.com/repos/aiur-team/aiur/contents/.github/workflows?ref=main")

      assert {:cache, :repo_config, _ttl} = Policy.classify(workflows)
      refute :code_owners in Policy.classes()
    end

    test "CI config reads are cacheable while CI verdict reads stay refused" do
      # The `@unsafe_rest` narrowing (#2298): `/actions/workflows` is the
      # workflow *list* (configuration), so it is cacheable; verdict endpoints —
      # workflow runs, check runs, commit status — stay refused.
      assert {:cache, :repo_config, _ttl} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/actions/workflows?per_page=100"))

      assert {:cache, :repo_config, _ttl} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/branches/main/protection"))

      assert {:cache, :repo_config, _ttl} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/rulesets?includes_parents=true&per_page=100"))

      for path <- ["/actions/runs", "/actions/runs/123/jobs", "/commits/abc/status", "/commits/abc/check-runs"] do
        assert {:no_cache, :unsafe_kind} = Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur#{path}"))
      end
    end

    test "the bare repository read stays unclassified while the candidate list is named" do
      # The bare `/repos/{owner}/{repo}` is the auth-preflight probe, which must
      # exercise the current credential rather than be answered from a cache;
      # the open-issue candidate list is dispatch authority and must not be
      # served stale. Both are correctly left uncached, and neither disappears
      # into one opaque total: #2352 names the candidate list `:issue_list`,
      # and the probe — which the table deliberately does not name — is refused
      # with its route template (#2357) so the refusal report can still say
      # which call family paid.
      assert {:no_cache, {:unclassified, "rest:GET /repos/aiur-team/aiur"}} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur"))

      assert {:no_cache, {:unclassified, :issue_list}} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/issues?state=open&per_page=100"))
    end

    test "caches a numbered comment read but not the repo-wide comment stream" do
      # The stream already revalidates with an ETag, so holding its body would
      # trade a free 304 for staleness. It is still *classified* as
      # `:comment_stream` so the refusal report can name it.
      assert {:cache, :comments, _ttl} = Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/issues/2073/comments?per_page=100"))

      assert {:no_cache, {:unclassified, :comment_stream}} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/issues/comments?per_page=100"))
    end

    test "classifies the ten REST families and gives rows 1, 4 and 5 a real TTL" do
      # #2352 acceptance: the 5,208 reads/hr of unclassified REST resolve into
      # the named rows. Only rows 1 (timeline), 4 (single issue) and 5 (single
      # PR) earn a body cache; every conditional row stays refused but named.
      assert {:cache, :issue_timeline, _ttl} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/issues/2073/timeline?per_page=100"))

      assert {:cache, :issue, _ttl} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/issues/2073"))

      assert {:cache, :pull, _ttl} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/pulls/2073"))

      # Repository configuration is cacheable only in its anchored forms —
      # `.github/workflows` contents, branch protection, rulesets — never a
      # bare `/contents/{path}` or `/branches` list. The tail row was narrowed
      # to the forms anyone actually reads (review #2360), so an arbitrary
      # `/contents/{path}` read stays unclassified.
      assert {:cache, :repo_config, _ttl} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/contents/.github/workflows"))

      assert {:cache, :repo_config, _ttl} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/branches/main"))

      assert {:cache, :repo_config, _ttl} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/rulesets"))

      refute match?({:cache, _class, _ttl}, Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/contents/foo/bar")))

      assert {:no_cache, {:unclassified, "rest:GET /repos/aiur-team/aiur/contents/foo/bar"}} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/contents/foo/bar"))

      refute match?({:cache, _class, _ttl}, Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/branches")))

      assert {:no_cache, {:unclassified, "rest:GET /repos/aiur-team/aiur/branches"}} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/branches"))

      for {url, shape} <- [
            {"/issues?labels=build-order&state=open", :issue_list},
            {"/pulls?state=open&per_page=100", :pull_list},
            {"/issues?state=open&per_page=100", :issue_list},
            {"/events", :repo_events},
            {"/issues/comments?since=2026-01-01", :comment_stream},
            {"/pulls/comments?since=2026-01-01", :comment_stream},
            {"/pulls/2073/files?per_page=100", :pull_files}
          ] do
        assert {:no_cache, {:unclassified, ^shape}} =
                 Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur#{url}"))
      end
    end

    test "the conditional rows are not body-cached" do
      # #2352 acceptance: rows 2, 3, 6, 7, 8, 9 and 10 are already
      # ETag-conditional at their call sites and answer 304 for free. Holding
      # their bodies here would trade a free revalidation for staleness, so a
      # later change must not be able to silently convert one. Each read runs
      # its fetch twice — the cache never answers it.
      for url <- [
            "/issues?labels=build-order&state=open",
            "/pulls?state=open&per_page=100",
            "/issues?state=open&per_page=100",
            "/events",
            "/issues/comments?since=2026-01-01",
            "/pulls/comments?since=2026-01-01",
            "/pulls/2073/files?per_page=100"
          ] do
        request = rest("https://api.github.com/repos/aiur-team/aiur#{url}")
        assert match?({:no_cache, {:unclassified, _shape}}, Policy.classify(request))
        assert 2 = counted_fetches(request)
      end
    end

    # #2326: a commit's timestamp is immutable per sha, so the bare commit read
    # is cacheable without ever serving a verdict that has moved. The sha is
    # matched exactly — a commit read by branch ref is highly mutable, and a
    # PR's changed paths carry no sha in their URL, so neither is cached (review
    # #2332).
    test "caches a commit read keyed by a real sha, and nothing keyed by ref or by PR" do
      commit = rest("https://api.github.com/repos/aiur-team/aiur/commits/abc1234")
      assert {:cache, :comments, _ttl} = Policy.classify(commit)

      # The verdict refusal is not weakened: a commit *status* read — CI — is
      # still refused even though the bare commit read is now cacheable.
      assert {:no_cache, :unsafe_kind} = Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/commits/abc1234/status"))

      # A branch ref is not a sha: `/commits/main` returns the mutable head
      # commit, so it must not be cached under a key that never changes.
      assert {:no_cache, {:unclassified, "rest:GET /repos/aiur-team/aiur/commits/main"}} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/commits/main"))

      # `/pulls/:n/files` carries no head sha, so a push changes the response
      # under a fixed cache key; it is deliberately left uncached, named so the
      # refusal report says which call family it was.
      assert {:no_cache, {:unclassified, :pull_files}} = Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/pulls/2073/files?per_page=100"))
    end

    # Acceptance #2326: no verdict field becomes cacheable. Every selection the
    # policy refuses on content is asserted to stay refused, whichever call site
    # sends it.
    test "no verdict field becomes cacheable" do
      for selection <- [
            "statusCheckRollup { state }",
            "checkSuites(first: 1) { nodes { status } }",
            "CheckRun(id: 1) { status }",
            "StatusContext { state }",
            "reviewDecision",
            "mergeStateStatus",
            "mergeable",
            "reviewThreads(first: 10) { nodes { id } }",
            "latestReviews(first: 1) { nodes { state } }",
            "reviews(first: 1) { nodes { state } }"
          ] do
        request = graphql("issue_relationships", "query Q { repository(owner: $o, name: $r) { t0: issueOrPullRequest(number: 2073) { ... on PullRequest { #{selection} } } } }")

        assert {:no_cache, :unsafe_kind} = Policy.classify(request),
               "#{selection} must not become cacheable"
      end
    end
  end

  defp graphql(caller, document, variables \\ %{"owner" => "aiur-team", "repo" => "aiur"}) do
    %{method: :post, url: "https://api.github.com/graphql", token: "t", body: %{"query" => document, "variables" => variables}, caller: caller}
  end

  defp rest(url), do: %{method: :get, url: url, token: "t"}

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
end
