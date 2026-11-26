defmodule Aiur.GitHub.ReadCache.PolicyTtlsTest do
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
  alias Aiur.Webhooks.DeliveryMode
  alias Aiur.Webhooks.ModeRegistry
  alias Aiur.Webhooks.ModeTable

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

  describe "policy coverage" do
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
      # The poll-cadence classes (Build Order detail, comments) stay at or below
      # the Build Order detail freshness derived from the default poll interval.
      # `:repo_config` rides the CIReadiness assessment cadence instead (its
      # assessment is cached for an hour), so it is bounded by that, not by the
      # 30-second Build Order window — which is why the classes are asserted by
      # name rather than in one loop.
      assert Policy.ttl_ms(:issue_graph) <= 30_000
      assert Policy.ttl_ms(:comments) <= 30_000
      assert Policy.ttl_ms(:issue_timeline) <= 30_000
      assert Policy.ttl_ms(:issue) <= 30_000
      assert Policy.ttl_ms(:pull) <= 30_000
      assert Policy.ttl_ms(:repo_config) <= 3_600_000

      # No class may be left without a bound when one is added.
      assert Enum.sort(Policy.classes()) == [:comments, :issue, :issue_graph, :issue_timeline, :pull, :repo_config]
    end

    test "every unsafe selection is refused however high the TTL is set" do
      # #2327 raised the TTLs a webhook-backed repo can earn to an hour. The
      # safety half of that change is that the refusal is decided by content,
      # never by a number that happens to be small — so each term in
      # `@unsafe_selections` is asserted against a TTL far above anything
      # shipped, and above the sweep bound, to prove the refusal cannot be
      # bought off by raising one.
      previous = Application.get_env(:aiur, :github_read_cache_ttls)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:aiur, :github_read_cache_ttls, previous),
          else: Application.delete_env(:aiur, :github_read_cache_ttls)
      end)

      Application.put_env(:aiur, :github_read_cache_ttls, %{comments: 3_600_000, issue_graph: 3_600_000})

      # The override is live, so a safe read IS cacheable at the raised TTL —
      # the loop below is only meaningful if the raised value actually applies.
      assert {:cache, :issue_graph, 3_600_000} = Policy.classify(graphql("issue_relationships", safe_document(2073)))

      selections = [
        "statusCheckRollup { state }",
        "checkSuites(first: 1) { nodes { status } }",
        # The `CheckRun` and `StatusContext` terms are GraphQL *type* names,
        # so they appear in documents as inline-fragment guards, exactly as the
        # CI poll batch writes them.
        "... on CheckRun { name status conclusion }",
        "... on StatusContext { state }",
        "reviewDecision",
        "mergeStateStatus",
        "mergeable",
        "reviewThreads(first: 1) { nodes { id } }",
        "latestReviews(first: 1) { nodes { id } }",
        "reviews(first: 1) { nodes { id } }"
      ]

      for selection <- selections do
        request = graphql("issue_relationships", unsafe_document(2073, selection))

        assert {:no_cache, :unsafe_kind} = Policy.classify(request),
               "a high TTL must not make a cacheable-looking read of #{selection} servable"
      end
    end

    test "no class TTL, in either bucket, reaches the sweep bound" do
      # `@max_ttl_ms` is the retention bound the sweep deletes past. A TTL at
      # or above it would mean the sweep deletes entries still inside their own
      # validity window and turns the backstop into a silent miss generator —
      # so both the polling bucket and the webhook-backed bucket must stay
      # below it.
      for class <- Policy.classes() do
        assert Policy.ttl_ms(class) < ReadCache.max_ttl_ms()
        assert Policy.ttl_ms(class, :webhook) < ReadCache.max_ttl_ms()
      end
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

      assert {:cache, :issue_timeline, 3_600_000} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/ttl-test-repo/issues/2073/timeline?per_page=100"))

      assert {:cache, :issue, 3_600_000} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/ttl-test-repo/issues/2073"))

      assert {:cache, :pull, 3_600_000} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/ttl-test-repo/pulls/2073"))

      ModeTable.put(@ttl_repo, degraded_mode())

      assert {:cache, :issue_graph, 30_000} =
               Policy.classify(graphql("issue_relationships", safe_document(2073), %{"owner" => "aiur-team", "repo" => "ttl-test-repo"}))

      assert {:cache, :comments, 30_000} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/ttl-test-repo/issues/2073/comments?per_page=100"))

      assert {:cache, :repo_config, 300_000} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/ttl-test-repo/actions/workflows?per_page=100"))

      assert {:cache, :issue_timeline, 30_000} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/ttl-test-repo/issues/2073/timeline?per_page=100"))

      assert {:cache, :issue, 30_000} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/ttl-test-repo/issues/2073"))

      assert {:cache, :pull, 30_000} =
               Policy.classify(rest("https://api.github.com/repos/aiur-team/ttl-test-repo/pulls/2073"))
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

  defp ci_document do
    "query C($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { t0: issueOrPullRequest(number: 2073) { ... on PullRequest { commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } } }"
  end

  defp unsafe_document(number, selection) do
    "query Q($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { t0: issueOrPullRequest(number: #{number}) { ... on PullRequest { #{selection} } } } }"
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

  # The sweep runs in the cache's process, so a test that triggers it must wait
  # for the message to be handled before asserting on the tables.
end
