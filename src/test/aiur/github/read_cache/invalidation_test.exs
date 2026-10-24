defmodule Aiur.GitHub.ReadCache.InvalidationTest do
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
  alias Aiur.GitHub.ReadCache.Identity
  alias Aiur.GitHub.ReadCache.Metrics
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
