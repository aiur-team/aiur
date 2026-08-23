defmodule Aiur.GitHub.ReadCacheTest do
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

  alias Aiur.Events.GithubWebhook.Deposit
  alias Aiur.GitHub.ReadCache
  alias Aiur.GitHub.ReadCache.{Identity, Metrics, Policy}
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Webhooks.{DeliveryMode, ModeRegistry, ModeTable}

  @repo "aiur-team/aiur"
  @ttl_repo "aiur-team/ttl-test-repo"

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
  end

  describe "invalidation" do
    test "a number retires every held read that named it" do
      request = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      ReadCache.invalidate_number(@repo, 2073)

      assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a number retires a batch document that named it among many" do
      # The reason identity is extracted from the document: the batch builders
      # interpolate numbers into the query text, so a writer that only knew
      # `variables` could retire nothing.
      batch = graphql("issue_relationships", batch_document([2070, 2073, 2099]))
      assert {:ok, _response} = ReadCache.through(batch, fn -> {:ok, %{status: 200, body: "first"}} end)

      ReadCache.invalidate_number(@repo, 2073)

      assert {:ok, %{body: "second"}} = ReadCache.through(batch, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a number does not retire a read about a different number" do
      other = graphql("issue_relationships", safe_document(2070))
      assert {:ok, _response} = ReadCache.through(other, fn -> {:ok, %{status: 200, body: "first"}} end)

      ReadCache.invalidate_number(@repo, 2073)

      assert {:ok, %{body: "first"}} = ReadCache.through(other, fn -> flunk("an unrelated number must not retire this") end)
    end

    test "issues and pull requests share one number namespace" do
      assert [{:number, "aiur-team", "aiur", 2073}] =
               Enum.filter(Identity.extract(graphql("c", safe_document(2073))), &match?({:number, _o, _r, _n}, &1))

      assert [{:number, "aiur-team", "aiur", 2073}] =
               Enum.filter(
                 Identity.extract(rest("https://api.github.com/repos/aiur-team/aiur/issues/2073/comments")),
                 &match?({:number, _o, _r, _n}, &1)
               )
    end

    test "a repository mark retires every read of that repository" do
      request = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      ReadCache.invalidate_repo(@repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a collections mark retires enumerating reads and leaves numbered ones" do
      # A document asking `pullRequests(headRefName: ...)` carries both scopes:
      # its answer changes when a pull request is created, which touches none of
      # the numbers it already names.
      enumerating = graphql("issue_relationships", safe_document(2073) <> "\n branch_0: pullRequests(headRefName: \"x\") { nodes { number } }")
      numbered = graphql("issue_relationships", safe_document(2073))

      assert {:ok, _one} = ReadCache.through(enumerating, fn -> {:ok, %{status: 200, body: "first"}} end)
      assert {:ok, _two} = ReadCache.through(numbered, fn -> {:ok, %{status: 200, body: "first"}} end)

      ReadCache.invalidate([{:collections, "aiur-team", "aiur"}])

      assert {:ok, %{body: "second"}} = ReadCache.through(enumerating, fn -> {:ok, %{status: 200, body: "second"}} end)
      assert {:ok, %{body: "first"}} = ReadCache.through(numbered, fn -> flunk("a numbered read is not a collection") end)
    end

    test "the marker sweep keeps every marker that could still retire a fresh entry" do
      # The sweep drops markers older than `@max_ttl_ms` (four hours) on the
      # theory that once nothing deposited before them can still be fresh, they
      # can retire nothing. The theory is load-bearing: a marker written beside
      # a deposit must survive until that deposit's TTL has passed, and with
      # webhook-backed repos issuing an hour the bound has to sit above it.
      # This pins the boundary from both sides.
      request = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)
      ReadCache.invalidate_number(@repo, 2073)

      # Four hours minus a minute is still inside the bound, so the sweep keeps
      # both markers (the number and the collections).
      age_markers_by(4 * 60 * 60_000 - 60_000)
      sweep()
      assert wait_until(fn -> marker_count() == 2 end)

      # A minute later they are past the bound, where nothing they cover can be
      # fresh any more, and the sweep drops them.
      age_markers_by(60_001)
      sweep()
      assert wait_until(fn -> marker_count() == 0 end)
    end

    test "a mutation retires what it changed" do
      read = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "first"}} end)

      mutation = graphql("review_thread_reply", "mutation M { addComment(input: {subjectId: \"x\"}) { clientMutationId } }", %{"owner" => "aiur-team", "repo" => "aiur", "number" => 2073})

      assert {:ok, _written} = ReadCache.through(mutation, fn -> {:ok, %{status: 200, body: "written"}} end)
      assert {:ok, %{body: "second"}} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a failed mutation retires nothing" do
      read = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "first"}} end)

      mutation = graphql("review_thread_reply", "mutation M { x }", %{"owner" => "aiur-team", "repo" => "aiur", "number" => 2073})
      assert {:error, :boom} = ReadCache.through(mutation, fn -> {:error, :boom} end)

      assert {:ok, %{body: "first"}} = ReadCache.through(read, fn -> flunk("a failed write changed nothing") end)
    end

    test "a node-id mutation retires everything rather than guessing a repository" do
      # `resolveReviewThread(threadId:)` names no repository, so taken literally
      # it would retire nothing and leave its own stale read behind it.
      #
      # Retiring the *configured* repository instead would be wrong, not merely
      # coarse: a node id belongs to whichever repository it belongs to, so the
      # guess flushes one the write never touched while leaving the one it did
      # touch stale. Two repositories are held here and both must be retired.
      mine = graphql("issue_relationships", safe_document(2073))
      other = graphql("issue_relationships", safe_document(2073), %{"owner" => "someone-else", "repo" => "elsewhere"})

      assert {:ok, _one} = ReadCache.through(mine, fn -> {:ok, %{status: 200, body: "first"}} end)
      assert {:ok, _two} = ReadCache.through(other, fn -> {:ok, %{status: 200, body: "first"}} end)

      mutation = %{
        method: :post,
        url: "https://api.github.com/graphql",
        body: %{"query" => "mutation R { resolveReviewThread(input: {threadId: \"x\"}) { clientMutationId } }", "variables" => %{"threadId" => "x"}},
        caller: "review_thread_resolve"
      }

      assert {:ok, _written} = ReadCache.through(mutation, fn -> {:ok, %{status: 200, body: %{"data" => %{}}}} end)

      assert {:ok, %{body: "second"}} = ReadCache.through(mine, fn -> {:ok, %{status: 200, body: "second"}} end)
      assert {:ok, %{body: "second"}} = ReadCache.through(other, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a REST write retires the number it names" do
      read = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "first"}} end)

      write = %{method: :post, url: "https://api.github.com/repos/aiur-team/aiur/issues/2073/comments", body: %{}}
      assert {:ok, _written} = ReadCache.through(write, fn -> {:ok, %{status: 201, body: %{}}} end)

      assert {:ok, %{body: "second"}} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a numbered write retires a numbers-free enumerating read" do
      # The `build_order_catalog` document names no numbers, so its identity set
      # is only [:root, {:repo, ...}, {:collections, ...}] — the collections
      # marker is the one identity a numbered write can write that retires it.
      # Before #2372 the catalog was retired *structurally*, by the `{:repo, ...}`
      # marker every numbered write then wrote; precise retirement must still
      # retire it, or a comment added to a ticket would serve pre-write bytes for
      # the whole webhook TTL.
      catalog = graphql("build_order_catalog", catalog_document())
      assert {:ok, _response} = ReadCache.through(catalog, fn -> {:ok, %{status: 200, body: "first"}} end)

      write = %{method: :post, url: "https://api.github.com/repos/aiur-team/aiur/issues/2073/comments", body: %{}}
      assert {:ok, _written} = ReadCache.through(write, fn -> {:ok, %{status: 201, body: %{}}} end)

      assert {:ok, %{body: "second"}} = ReadCache.through(catalog, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a repo-named write with no number still retires a numbered read" do
      # The `numbers == [] -> [repo]` branch: a write that names a repository
      # but no number (a git-ref write, a repo-config write) still retires
      # repository-wide. A numbered read carries `{:repo, ...}` but not
      # `{:collections, ...}`, so the repo marker is the only identity that
      # holds this; weakening the branch to the collections marker would let a
      # repo-wide write leave every numbered read of the repository cached.
      read = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "first"}} end)

      write = %{method: :post, url: "https://api.github.com/repos/aiur-team/aiur/labels", body: %{}}
      assert {:ok, _written} = ReadCache.through(write, fn -> {:ok, %{status: 201, body: %{}}} end)

      assert {:ok, %{body: "second"}} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    # Regression for #2372: the read cache reported 0.0% hits with a full,
    # freshly-deposited table because invalidation was repository-wide. A write
    # or a CI delivery that changed *one* numbered resource marked `{:repo, ...}`,
    # which every read of the repository carries, so on a repo the daemon writes
    # to continuously nothing ever survived to be served. These pin the
    # precision: a change to one number must not retire a read of a different
    # number, and a deposit followed by an identical cacheable read within the
    # TTL must produce a hit.
    test "a write to one issue does not retire a cached read of a different issue" do
      read = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "first"}} end)

      write = %{method: :post, url: "https://api.github.com/repos/aiur-team/aiur/issues/2070/comments", body: %{}}
      assert {:ok, _written} = ReadCache.through(write, fn -> {:ok, %{status: 201, body: %{}}} end)

      assert {:ok, %{body: "first"}} = ReadCache.through(read, fn -> flunk("a write to issue 2070 must not retire a read of issue 2073") end)
      assert %{totals: %{hit: 1, miss: 1, deposit: 1}} = Metrics.snapshot()
    end

    test "a check_run delivery retires only the pull requests it names, not the whole repository" do
      # A check_run delivery names the pull requests it belongs to, but
      # `Deposit.invalidate_read_cache` used to fall through to
      # `invalidate_repo`, retiring *every* read of the repository. CI
      # check-run deliveries are effectively continuous on an active repo, so
      # that wiped the cache faster than anything could be served from it.
      read = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("check_run", check_run_delivery(2070), @repo)

      assert {:ok, %{body: "first"}} = ReadCache.through(read, fn -> flunk("a check_run for PR 2070 must not retire a read of issue 2073") end)
      assert %{totals: %{hit: 1, miss: 1, deposit: 1}} = Metrics.snapshot()
    end

    test "a check_run delivery with a malformed pull_requests element still retires the valid ones" do
      # `delivery_numbers` reads the numbers from `check_run.pull_requests`, and
      # a malformed element (not a map) must not abort the whole read: the old
      # `Enum.map` raised, `deposit/3`'s rescue swallowed the entire
      # `invalidate_read_cache/3` call, and the delivery retired *nothing* —
      # silently leaving the cache stale. The valid elements must still be
      # retired.
      read = graphql("issue_relationships", safe_document(2070))
      assert {:ok, _response} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "first"}} end)

      malformed = %{
        "check_run" => %{
          "id" => 55_03,
          "name" => "test",
          "status" => "completed",
          "conclusion" => "success",
          "head_sha" => "deadbeef",
          "output" => %{},
          "pull_requests" => ["not-a-map", %{"number" => 2070, "head" => %{"ref" => "aiur/42-a-ticket"}}]
        }
      }

      Deposit.deposit("check_run", malformed, @repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a check_suite delivery retires only the pull requests it names, not the whole repository" do
      read = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("check_suite", check_suite_delivery(2070), @repo)

      assert {:ok, %{body: "first"}} = ReadCache.through(read, fn -> flunk("a check_suite for PR 2070 must not retire a read of issue 2073") end)
      assert %{totals: %{hit: 1, miss: 1, deposit: 1}} = Metrics.snapshot()
    end

    test "a pull_request_review_thread delivery retires the pull request it names" do
      # A `pull_request_review_thread` delivery names its pull request in
      # `pull_request.number`, and `Deposit.delivery_numbers` must retire that
      # number. Before #2372 this event type fell through to "no nameable
      # number" and retired the *whole repository* on every thread delivery.
      read = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("pull_request_review_thread", review_thread_delivery(2073), @repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a pull_request_review_thread delivery does not retire a read of a different number" do
      # The other half of the pin: a thread delivery for one pull request must
      # not retire a read of a different number. If `delivery_numbers` fell back
      # to `[]` for this event type, `invalidate_read_cache` would call
      # `invalidate_repo` and a read of issue 2073 would be retired by a thread
      # delivery about PR 2070.
      read = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("pull_request_review_thread", review_thread_delivery(2070), @repo)

      assert {:ok, %{body: "first"}} = ReadCache.through(read, fn -> flunk("a review-thread delivery for PR 2070 must not retire a read of issue 2073") end)
      assert %{totals: %{hit: 1, miss: 1, deposit: 1}} = Metrics.snapshot()
    end

    test "a deposited read survives unrelated writes and deliveries, so the hit rate stays above zero" do
      # The hit-rate guard for #2372: the cache used to serve 0.0% of cacheable
      # reads on this repository because both the daemon's own writes and CI
      # deliveries retired the whole repository. A deposit followed by unrelated
      # activity followed by an identical read within the TTL must still hit.
      read = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _one} = ReadCache.through(read, fn -> {:ok, %{status: 200, body: "first"}} end)

      write = %{method: :post, url: "https://api.github.com/repos/aiur-team/aiur/issues/2070/comments", body: %{}}
      assert {:ok, _written} = ReadCache.through(write, fn -> {:ok, %{status: 201, body: %{}}} end)
      Deposit.deposit("check_run", check_run_delivery(2070), @repo)

      assert {:ok, %{body: "first"}} = ReadCache.through(read, fn -> flunk("hit") end)
      assert ReadCache.snapshot().hit_rate > 0
    end

    test "an invalidation written during a slow fetch retires the entry that fetch deposits" do
      # The write-after-invalidate race, and the delay is the whole test.
      #
      # An earlier version of this invalidated inside a fetch that returned
      # instantly, so the marker and the deposit landed in the same millisecond
      # and `marked_at >= deposited_at` passed for the wrong reason. It went
      # green against code that stamped entries at fetch *return*, where the
      # property does not hold at all: a real GitHub read takes hundreds of
      # milliseconds, so every mutation landing mid-cycle would have been
      # overwritten by the response that was already in flight.
      #
      # The sleep is what separates the marker from the deposit. Without the
      # fix in `read_through/5` — stamping at fetch start — this serves
      # "raced".
      request = graphql("issue_relationships", safe_document(2073))

      assert {:ok, _response} =
               ReadCache.through(request, fn ->
                 ReadCache.invalidate_number(@repo, 2073)
                 Process.sleep(25)
                 {:ok, %{status: 200, body: "raced"}}
               end)

      assert {:ok, %{body: "fresh"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "fresh"}} end)
    end

    test "a slow fetch that races nothing is still deposited and served" do
      # The guard above must not be bought by refusing to cache slow reads. A
      # read with no marker against it is a hit however long it took.
      request = graphql("issue_relationships", safe_document(2088))

      assert {:ok, _response} =
               ReadCache.through(request, fn ->
                 Process.sleep(25)
                 {:ok, %{status: 200, body: "slow"}}
               end)

      assert {:ok, %{body: "slow"}} = ReadCache.through(request, fn -> flunk("an unraced read must still be cached") end)
    end

    test "an entry is dated from when its fetch started, not when it returned" do
      # The TTL measures the age of the data, and the data is as old as the
      # request that asked for it. A 40ms fetch under a 30s TTL must expire
      # 40ms sooner than one that answered instantly, not later.
      request = graphql("issue_relationships", safe_document(2099))

      assert {:ok, _response} =
               ReadCache.through(request, fn ->
                 Process.sleep(40)
                 {:ok, %{status: 200, body: "slow"}}
               end)

      [{_key, _response, deposited_at}] = :ets.tab2list(:aiur_github_read_cache_entries)

      assert System.monotonic_time(:millisecond) - deposited_at >= 40
    end
  end

  describe "webhook deliveries retire what they deposit" do
    setup do
      on_exit(&ResourceStore.reset/0)
      :ok
    end

    test "a delivered issue comment retires a cached GraphQL read of that issue" do
      request = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("issue_comment", issue_comment_delivery(2073), @repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a delivered comment retires the numbered REST comments read" do
      # The `:comments` class is `/issues/{n}/comments`, and a comment added to
      # issue n changes exactly what that read answers. A delivery must retire
      # it the same way it retires the GraphQL read of the issue.
      comments = rest("https://api.github.com/repos/aiur-team/aiur/issues/2073/comments?per_page=100")
      assert {:ok, _response} = ReadCache.through(comments, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("issue_comment", issue_comment_delivery(2073), @repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(comments, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a delivery for one issue leaves a read of a different issue cached" do
      request = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("issue_comment", issue_comment_delivery(2070), @repo)

      assert {:ok, %{body: "first"}} = ReadCache.through(request, fn -> flunk("an unrelated delivery must not retire this") end)
    end

    test "a delivered pull request change retires a read of that pull request" do
      request = graphql("issue_relationships", safe_document(2073))
      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("pull_request", %{"action" => "synchronize", "pull_request" => %{"number" => 2073, "head" => %{"ref" => "aiur/42-x", "sha" => "new"}}}, @repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "an issue creation retires the repository's enumerating reads too" do
      enumerating =
        graphql(
          "issue_relationships",
          safe_document(2073) <> "\n branch_0: pullRequests(headRefName: \"x\") { nodes { number } }"
        )

      assert {:ok, _response} = ReadCache.through(enumerating, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit("issues", %{"action" => "opened", "issue" => %{"number" => 9999, "labels" => []}}, @repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(enumerating, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a labeled delivery retires a numbers-free enumerating read" do
      # The `build_order_catalog` document names no numbers, so its identity
      # set is only [:root, {:repo, ...}, {:collections, ...}] — the collections
      # marker is the one identity a delivery can write that retires it. A
      # `labeled` delivery changes what a `labels: ["build-order"]` enumeration
      # answers (set membership) without creating or destroying a resource,
      # which is exactly the action a conditional collections marker would have
      # skipped — and a delivery that skips it serves pre-delivery bytes for
      # the whole webhook TTL.
      catalog = graphql("build_order_catalog", catalog_document())
      assert {:ok, _response} = ReadCache.through(catalog, fn -> {:ok, %{status: 200, body: "first"}} end)

      Deposit.deposit(
        "issues",
        %{"action" => "labeled", "issue" => %{"number" => 2073, "labels" => [%{"name" => "build-order"}]}},
        @repo
      )

      assert {:ok, %{body: "second"}} = ReadCache.through(catalog, fn -> {:ok, %{status: 200, body: "second"}} end)
    end
  end

  describe "metrics" do
    test "counts hits, misses and deposits by class and by caller" do
      request = graphql("issue_relationships", safe_document(2073))

      assert {:ok, _one} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)
      assert {:ok, _two} = ReadCache.through(request, fn -> flunk("hit") end)

      snapshot = Metrics.snapshot()

      assert %{hit: 1, miss: 1, deposit: 1} = snapshot.classes[:issue_graph]
      assert %{hit: 1, miss: 1, deposit: 1} = snapshot.callers["issue_relationships"]
    end

    test "counts a refusal against its caller with a reason, not as a miss" do
      assert {:ok, _response} = ReadCache.through(graphql("ci_poll_batch", ci_document()), fn -> {:ok, %{status: 200, body: "x"}} end)

      snapshot = Metrics.snapshot()

      assert %{refused: 1, miss: 0} = snapshot.callers["ci_poll_batch"]
      assert %{unsafe_kind: 1} = snapshot.refused
    end

    test "a REST read with no declared caller is named by route shape, not unattributed" do
      # `Quota` bills the same request `rest:GET /repos/...` via
      # `GraphQLCost.derive/1`; the cache used to fall back to a single
      # `unattributed` bucket that hid every REST call site. The two must use
      # the same derivation, so the cache metric names the shape the way the
      # spend ranking does (#2357).
      request = rest("https://api.github.com/repos/aiur-team/aiur/issues/2073/comments?per_page=100")

      assert {:ok, _one} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      snapshot = Metrics.snapshot()
      assert %{miss: 1, deposit: 1} = snapshot.callers["rest:GET /repos/aiur-team/aiur/issues/:n/comments"]
      refute Map.has_key?(snapshot.callers, "unattributed")
    end

    test "keys a REST refusal on its path template, not one unclassified total" do
      # An unclassified REST GET is refused with its route shape, so
      # `github-cost` can name the call family instead of folding every
      # unrecognised read into a single `unclassified` total (#2357). Same
      # derivation `Quota` bills spend by.
      request = rest("https://api.github.com/repos/aiur-team/aiur/labels?per_page=100")

      assert {:no_cache, {:unclassified, "rest:GET /repos/aiur-team/aiur/labels"}} = Policy.classify(request)

      assert {:ok, _one} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)
      assert {:ok, _two} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)

      snapshot = Metrics.snapshot()
      assert %{"rest:GET /repos/aiur-team/aiur/labels" => 2} = snapshot.refused_shapes
      refute Map.has_key?(snapshot.refused, :unclassified)
      assert snapshot.totals.refused == 2
    end

    test "a GraphQL read the policy cannot name stays a bare :unclassified refusal" do
      # There is no REST URL to shape a GraphQL read by, so the unknown-caller
      # fallback keeps its plain reason rather than being forced into the shape
      # map.
      request = graphql("an_unheard_of_caller", safe_document(2073))

      assert {:no_cache, :unclassified} = Policy.classify(request)
      assert {:ok, _one} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      snapshot = Metrics.snapshot()
      assert %{unclassified: 1} = snapshot.refused
      assert snapshot.refused_shapes == %{}
    end

    test "folds a refusal beyond the 200-shape cap into :overflow" do
      # The refusal map is only bounded if the key set is: 200 distinct shapes
      # fill the map, the 201st distinct shape must not add a key, and a repeat
      # of an existing shape keeps accumulating under its own key.
      Metrics.init()

      Enum.each(1..200, fn i -> Metrics.refused_shape("rest:GET /path/#{i}", "x") end)
      assert map_size(Metrics.snapshot().refused_shapes) == 200

      Metrics.refused_shape("rest:GET /path/201", "x")
      snapshot = Metrics.snapshot()
      assert snapshot.refused_shapes.overflow == 1

      Metrics.refused_shape("rest:GET /path/1", "x")
      snapshot = Metrics.snapshot()
      assert snapshot.refused_shapes["rest:GET /path/1"] == 2
      assert snapshot.refused_shapes.overflow == 1
    end

    test "reports nothing observed as nothing observed, never as zero" do
      assert Metrics.hit_rate(%{hit: 0, miss: 0}) == nil
      assert Metrics.hit_rate(%{hit: 1, miss: 1}) == 0.5
    end

    test "reports an unavailable cache rather than an empty one" do
      # Deleting the tables is how a CLI run outside the daemon sees this
      # module. It must answer "no measurement", not "zero hits" — the two read
      # identically in a report and only one of them is bad news.
      owner = Process.whereis(ReadCache)
      for table <- [:aiur_github_read_cache_entries, :aiur_github_read_cache_markers, Metrics.table()], do: :ets.delete(table)

      assert %{available?: false, entries: nil, hit_rate: nil, totals: %{hit: 0}} = ReadCache.snapshot()

      # Stop the owner so its supervisor rebuilds the tables for whatever runs
      # next; the setup block resets whatever it finds.
      ref = Process.monitor(owner)
      GenServer.stop(owner)
      assert_receive {:DOWN, ^ref, :process, ^owner, _reason}
    end

    test "counts every invalidation event and every mark it wrote" do
      ReadCache.invalidate_number(@repo, 2073)

      assert %{invalidations: %{events: 1, marks: 2}} = Metrics.snapshot()
    end
  end

  describe "policy coverage" do
    test "every declared class and refusal reason is nameable, so a report has no gaps" do
      assert :comments in Policy.classes()
      assert :unsafe_kind in Policy.no_cache_reasons()
      assert :unclassified in Policy.no_cache_reasons()
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

    test "the bare repository read and the candidate issue list stay unclassified" do
      # The bare `/repos/{owner}/{repo}` is the auth-preflight probe, which must
      # exercise the current credential rather than be answered from a cache;
      # the open-issue candidate list is dispatch authority and must not be
      # served stale. Both are correctly left uncached, and both are refused
      # with their route shape so the refusal metric names the call family.
      assert {:no_cache, {:unclassified, "rest:GET /repos/aiur-team/aiur"}} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur"))

      assert {:no_cache, {:unclassified, "rest:GET /repos/aiur-team/aiur/issues"}} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/issues?state=open&per_page=100"))
    end

    test "caches a numbered comment read but not the repo-wide comment stream" do
      # The stream already revalidates with an ETag, so holding its body would
      # trade a free 304 for staleness.
      assert {:cache, :comments, _ttl} = Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/issues/2073/comments?per_page=100"))

      assert {:no_cache, {:unclassified, "rest:GET /repos/aiur-team/aiur/issues/comments"}} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/issues/comments?per_page=100"))
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
      # under a fixed cache key; it is deliberately left uncached.
      assert {:no_cache, {:unclassified, "rest:GET /repos/aiur-team/aiur/pulls/:n/files"}} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/aiur/pulls/2073/files?per_page=100"))
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

    test "a declared cacheable caller is still refused on unsafe content" do
      assert {:cache, :issue_graph, _ttl} = Policy.classify(graphql("issue_relationships", safe_document(2073)))
      assert {:no_cache, :unsafe_kind} = Policy.classify(graphql("issue_relationships", ci_document()))
    end

    test "no default TTL outruns the tightest cadence a caller can be polling on" do
      # The polling bucket — the value in force for any repo that is not proven
      # webhook-backed — stays a freshness bound. A cache at the chokepoint
      # overrides freshness the call site thought it controlled, so the *short*
      # bucket must never outrun the tightest cadence a caller can be on. The
      # long bucket is a different thing: see the mode test below.
      #
      # The poll-cadence classes (Build Order detail, comments) stay at or below
      # the Build Order detail freshness derived from the default poll interval.
      # `:repo_config` rides the CIReadiness assessment cadence instead (its
      # assessment is cached for an hour), so it is bounded by that, not by the
      # 30-second Build Order window — which is why the classes are asserted by
      # name rather than in one loop.
      assert Policy.ttl_ms(:issue_graph) <= 30_000
      assert Policy.ttl_ms(:comments) <= 30_000
      assert Policy.ttl_ms(:repo_config) <= 3_600_000

      # No class may be left without a bound when one is added.
      assert Enum.sort(Policy.classes()) == [:comments, :issue_graph, :repo_config]
    end

    test "the TTL widens for a webhook-backed repo and collapses when it degrades" do
      # The acceptance for #2316: a repo that has proven its webhook earns the
      # long TTL, because a delivery retires what it changes and the TTL is
      # only a backstop against a missed delivery. A repo that degrades back to
      # polling loses the long TTL, because nothing but the clock retires its
      # entries any more. The collapse is the safety net, so it is the half
      # that is asserted directly.
      on_exit(fn -> ModeTable.delete(@ttl_repo) end)

      ModeTable.put(@ttl_repo, webhook_backed_mode())

      assert {:cache, :issue_graph, 3_600_000} =
               Policy.classify(graphql("issue_relationships", safe_document(2073), %{"owner" => "aiur-team", "repo" => "ttl-test-repo"}))

      assert {:cache, :comments, 3_600_000} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/ttl-test-repo/issues/2073/comments?per_page=100"))

      assert {:cache, :repo_config, 3_600_000} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/ttl-test-repo/actions/workflows?per_page=100"))

      ModeTable.put(@ttl_repo, degraded_mode())

      assert {:cache, :issue_graph, 30_000} =
               Policy.classify(graphql("issue_relationships", safe_document(2073), %{"owner" => "aiur-team", "repo" => "ttl-test-repo"}))

      assert {:cache, :comments, 30_000} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/ttl-test-repo/issues/2073/comments?per_page=100"))

      assert {:cache, :repo_config, 300_000} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/ttl-test-repo/actions/workflows?per_page=100"))
    end

    test "a webhook-backed entry is still a hit past the old 30-second TTL" do
      # The raise has to be proven by a served hit, not only by a constant: a
      # webhook-backed entry aged past the polling bucket is still fresh,
      # because the delivery (not the clock) is what retires it. The constant
      # assertion above would stay green if `@webhook_backed_ttls` were reverted
      # to 30 s; this one goes red.
      on_exit(fn -> ModeTable.delete(@ttl_repo) end)
      ModeTable.put(@ttl_repo, webhook_backed_mode())

      request = graphql("issue_relationships", safe_document(2073), %{"owner" => "aiur-team", "repo" => "ttl-test-repo"})

      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)
      age_entries_by(31_000)

      assert {:ok, %{body: "first"}} = ReadCache.through(request, fn -> flunk("a webhook-backed hit must not refetch at 31 s") end)
      assert %{totals: %{hit: 1}} = Metrics.snapshot()
    end

    test "a registry-recorded delivery reaches the TTL policy through the mode table" do
      # The mode pipe is the part of this feature CI could not see: if
      # `ModeRegistry.persist/3` stopped publishing to `ModeTable`, every repo
      # would sit on the 30-second bucket and the suite would stay green,
      # because the TTL tests seed the table directly. Driving the registry
      # (not `ModeTable.put`) is what makes this fail when the publish is
      # dropped.
      on_exit(fn -> ModeTable.delete(@ttl_repo) end)

      name = :"ttl_pipe_registry_#{System.unique_integer([:positive])}"

      start_supervised!({ModeRegistry, name: name, configured_repos: [@ttl_repo], silence_threshold_ms: 900_000, sweep_interval_ms: 3_600_000, alert_fun: fn _name, _message, _opts -> :ok end})

      request = graphql("issue_relationships", safe_document(2073), %{"owner" => "aiur-team", "repo" => "ttl-test-repo"})

      assert ModeTable.transport(@ttl_repo) == :polling
      assert {:cache, :issue_graph, 30_000} = Policy.classify(request)

      {:ok, _mode} = ModeRegistry.record_delivery(@ttl_repo, server: name, at: ~U[2026-01-01 00:00:00Z])

      assert ModeTable.transport(@ttl_repo) == :webhook
      assert {:cache, :issue_graph, 3_600_000} = Policy.classify(request)
    end

    test "an unproven repo keeps the short TTL even when configured" do
      # Configuration is a hint, never proof: a configured-but-unproven repo
      # polls at full rate and must not earn the long TTL. The mode-aware TTL
      # reads the transport, not the configured flag.
      on_exit(fn -> ModeTable.delete(@ttl_repo) end)

      {mode, :configured} = DeliveryMode.configure(DeliveryMode.new(@ttl_repo), true)

      ModeTable.put(@ttl_repo, mode)

      assert {:cache, :issue_graph, 30_000} =
               Policy.classify(graphql("issue_relationships", safe_document(2073), %{"owner" => "aiur-team", "repo" => "ttl-test-repo"}))
    end

    test "a verdict-bearing document is still refused while a long TTL is in force" do
      # The long TTL is not an argument for caching verdict state. A 30-second
      # stale merge verdict is bad, an hour-long one is worse, so the content
      # refusal must hold exactly when the long TTL would otherwise be tempting.
      on_exit(fn -> ModeTable.delete(@ttl_repo) end)

      ModeTable.put(@ttl_repo, webhook_backed_mode())

      request = graphql("issue_relationships", ci_document(), %{"owner" => "aiur-team", "repo" => "ttl-test-repo"})

      assert {:no_cache, :unsafe_kind} = Policy.classify(request)
      assert 2 = counted_fetches(request)
    end

    test "an operator override wins over the mode bucket in both directions" do
      previous = Application.get_env(:aiur, :github_read_cache_ttls)
      on_exit(fn -> if previous, do: Application.put_env(:aiur, :github_read_cache_ttls, previous), else: Application.delete_env(:aiur, :github_read_cache_ttls) end)
      on_exit(fn -> ModeTable.delete(@ttl_repo) end)

      ModeTable.put(@ttl_repo, webhook_backed_mode())

      Application.put_env(:aiur, :github_read_cache_ttls, %{issue_graph: 0})
      request = graphql("issue_relationships", safe_document(2073), %{"owner" => "aiur-team", "repo" => "ttl-test-repo"})

      assert {:no_cache, :disabled} = Policy.classify(request)
      assert 2 = counted_fetches(request)
    end

    test "an operator can tighten or disable a class without a code change" do
      previous = Application.get_env(:aiur, :github_read_cache_ttls)
      on_exit(fn -> if previous, do: Application.put_env(:aiur, :github_read_cache_ttls, previous), else: Application.delete_env(:aiur, :github_read_cache_ttls) end)

      Application.put_env(:aiur, :github_read_cache_ttls, %{issue_graph: 0})
      request = graphql("issue_relationships", safe_document(2073))

      assert {:no_cache, :disabled} = Policy.classify(request)
      assert 2 = counted_fetches(request)
    end
  end

  defp graphql(caller, document, variables \\ %{"owner" => "aiur-team", "repo" => "aiur"}) do
    %{method: :post, url: "https://api.github.com/graphql", token: "t", body: %{"query" => document, "variables" => variables}, caller: caller}
  end

  defp rest(url), do: %{method: :get, url: url, token: "t"}

  defp safe_document(number) do
    "query Q($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { t0: issueOrPullRequest(number: #{number}) { ... on Issue { title } } } }"
  end

  defp batch_document(numbers) do
    aliases = Enum.map_join(numbers, "\n", fn n -> "t#{n}: issueOrPullRequest(number: #{n}) { ... on Issue { title } }" end)
    "query B($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { #{aliases} } }"
  end

  # The `build_order_catalog` shape: an enumerating read that names no numbers,
  # so its identity set is only [:root, {:repo, ...}, {:collections, ...}].
  defp catalog_document do
    "query B($owner: String!, $repo: String!, $pageSize: Int!, $cursor: String) { repository(owner: $owner, name: $repo) { issues(first: $pageSize, after: $cursor, labels: [\"build-order\"]) { pageInfo { hasNextPage endCursor } nodes { number title } } } }"
  end

  defp ci_document do
    "query C($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { t0: issueOrPullRequest(number: 2073) { ... on PullRequest { commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } } }"
  end

  defp issue_comment_delivery(number) do
    %{
      "action" => "created",
      "issue" => %{"number" => number, "labels" => []},
      "comment" => %{
        "id" => 55_001,
        "body" => "please rework",
        "created_at" => "2026-06-24T12:00:00Z",
        "updated_at" => "2026-06-24T12:00:00Z",
        "user" => %{"login" => "its-everdred"}
      }
    }
  end

  # A `check_run` delivery carrying the pull request it belongs to. GitHub's
  # real payload puts the PR `number` on each entry of `check_run.pull_requests`;
  # that is what lets a delivery retire exactly the PR it changed rather than
  # the whole repository.
  defp check_run_delivery(number) do
    %{
      "check_run" => %{
        "id" => 55_01,
        "name" => "test",
        "status" => "completed",
        "conclusion" => "success",
        "head_sha" => "deadbeef",
        "started_at" => "2026-06-24T12:00:00Z",
        "completed_at" => "2026-06-24T12:01:00Z",
        "output" => %{},
        "pull_requests" => [%{"number" => number, "head" => %{"ref" => "aiur/42-a-ticket"}}]
      }
    }
  end

  defp check_suite_delivery(number) do
    %{
      "check_suite" => %{
        "id" => 55_02,
        "status" => "completed",
        "conclusion" => "success",
        "head_sha" => "deadbeef",
        "pull_requests" => [%{"number" => number, "head" => %{"ref" => "aiur/42-a-ticket"}}]
      }
    }
  end

  # A `pull_request_review_thread` delivery carrying the pull request it names.
  # `Deposit.delivery_numbers/2` reads the PR number from
  # `pull_request.number`, which is what lets a thread delivery retire exactly
  # the PR it changed rather than the whole repository.
  defp review_thread_delivery(number) do
    %{
      "action" => "unresolved",
      "pull_request" => %{"number" => number, "head" => %{"ref" => "aiur/42-a-ticket"}}
    }
  end

  # A proven, webhook-backed mode: configured, then proven by a delivery.
  defp webhook_backed_mode do
    {mode, :proven} = DeliveryMode.new(@ttl_repo, configured?: true) |> DeliveryMode.record_delivery(~U[2026-01-01 00:00:00Z])
    mode
  end

  # The same repo after corroborated silence past the threshold has degraded it
  # back to full polling.
  defp degraded_mode do
    {proven, _} = DeliveryMode.new(@ttl_repo, configured?: true) |> DeliveryMode.record_delivery(~U[2026-01-01 00:00:00Z])
    {active, _} = DeliveryMode.record_activity(proven, ~U[2026-01-01 00:16:00Z])
    {degraded, :degraded} = DeliveryMode.sweep(active, ~U[2026-01-01 00:16:00Z], 900_000)
    degraded
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

  # Same trick for markers, which the sweep ages against `@max_ttl_ms`.
  defp age_markers_by(ms) do
    table = :aiur_github_read_cache_markers

    for {identity, marked_at} <- :ets.tab2list(table) do
      :ets.insert(table, {identity, marked_at - ms})
    end
  end

  defp marker_count, do: :ets.info(:aiur_github_read_cache_markers, :size)

  # The sweep runs in the cache's process, so a test that triggers it must wait
  # for the message to be handled before asserting on the tables.
  defp sweep, do: Process.send(Process.whereis(ReadCache), :sweep, [])

  defp wait_until(fun, attempts \\ 200)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.(), do: true, else: Process.sleep(5) && wait_until(fun, attempts - 1)
  end

  defp wait_until(_fun, 0), do: flunk("condition never became true")
end
