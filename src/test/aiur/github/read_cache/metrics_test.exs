defmodule Aiur.GitHub.ReadCache.MetricsTest do
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

  describe "metrics" do
    test "counts hits, misses and deposits by class and by caller" do
      request = graphql("issue_relationships", safe_document(2073))

      assert {:ok, _one} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)
      assert {:ok, _two} = ReadCache.through(request, fn -> flunk("hit") end)

      snapshot = Metrics.snapshot()

      assert %{hit: 1, miss: 1, deposit: 1} = snapshot.classes[:issue_graph]
      assert %{hit: 1, miss: 1, deposit: 1} = snapshot.callers["issue_relationships"]
    end

    test "counts a response refused at deposit as unsuccessful, not as a silent gap" do
      request = graphql("issue_relationships", safe_document(2073))

      partial = {:ok, %{status: 200, body: %{"data" => %{}, "errors" => [%{"type" => "RATE_LIMITED"}]}}}

      assert ^partial = ReadCache.through(request, fn -> partial end)

      snapshot = Metrics.snapshot()

      assert %{unsuccessful: 1} = snapshot.not_deposited
      assert %{not_deposited: 1, deposit: 0, miss: 1} = snapshot.classes[:issue_graph]
      assert %{not_deposited: 1} = snapshot.callers["issue_relationships"]
      # The accounting remainder closes: this miss deposited nothing and said why.
      assert %{not_deposited: 1, miss: 1, deposit: 0} = snapshot.totals
    end

    test "counts a good response refused at the entry ceiling as no_room" do
      request = graphql("issue_relationships", safe_document(2073))

      # Fill the table to the ceiling; the deposit refusal is the backstop
      # answering "the cache could not hold it", and it must be counted as
      # `no_room` rather than folded into the unsuccessful bucket.
      ceiling = ReadCache.max_entries()
      now = System.monotonic_time(:millisecond)
      rows = for n <- 1..ceiling, do: {{:filler, n}, "x", now}
      :ets.insert(:aiur_github_read_cache_entries, rows)
      assert :ets.info(:aiur_github_read_cache_entries, :size) == ceiling

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "good"}} end)
      end)

      snapshot = Metrics.snapshot()

      assert %{no_room: 1} = snapshot.not_deposited
      assert %{not_deposited: 1, deposit: 0} = snapshot.classes[:issue_graph]
      assert %{not_deposited: 1} = snapshot.totals
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

    test "keys a REST refusal on its shape, not one unclassified total" do
      # #2352 acceptance: the refusal metric resolves the 5,208 reads/hr into
      # the named rows instead of one `unclassified` bucket, so `github-cost`
      # can say *which* call family a refusal belongs to.
      for url <- [
            "/issues?labels=build-order&state=open",
            "/pulls?state=open&per_page=100",
            "/events",
            "/pulls/2073/files?per_page=100"
          ] do
        request = rest("https://api.github.com/repos/aiur-team/aiur#{url}")
        assert {:ok, _} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: []}} end)
      end

      assert %{issue_list: 1, pull_list: 1, repo_events: 1, pull_files: 1} = Metrics.snapshot().refused
    end

    test "folds an unknown shape back to a bounded :unclassified bucket" do
      # The refusal keys are bounded by `Policy.shapes/0`; a shape the
      # classifier cannot name (which would mean a future classifier grew a
      # dynamic shape) must not grow the metric map without bound.
      Metrics.refused({:unclassified, :some_pathological_shape}, "x")

      assert %{unclassified: 1} = Metrics.snapshot().refused
      refute Map.has_key?(Metrics.snapshot().refused, :some_pathological_shape)
    end

    test "reports nothing observed as nothing observed, never as zero" do
      assert Metrics.hit_rate(%{hit: 0, miss: 0}) == nil
      assert Metrics.hit_rate(%{hit: 1, miss: 1}) == 0.5
    end

    test "counts every invalidation event and every mark it wrote" do
      ReadCache.invalidate_number(@repo, 2073)

      assert %{invalidations: %{events: 1, marks: 2}} = Metrics.snapshot()
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
end
