defmodule AiurWeb.GithubCacheLiveTest do
  @moduledoc """
  U9's acceptance criteria, asserted rather than described.

  The page's central claim is that looking at the cache costs nothing. Every
  test that could be written as "the page renders X" is instead written as
  "and the rate-limit reading did not move", because a debug page that quietly
  fetched would still render correctly and would still be wrong.
  """

  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.GitHub.AgentCacheMetrics
  alias Aiur.GitHub.Quota
  alias Aiur.GitHub.ResourceStore
  alias Aiur.GithubCacheSourceSupport, as: Source
  alias Aiur.TestSupport.AwaitingCommands
  alias AiurWeb.Endpoint

  # A deterministic history double. The page reads whichever provider is
  # configured (`:github_cache_history_provider`), so a test can hand it exact
  # samples without depending on the shared app-started sampler's ring.
  defmodule HistoryProvider do
    @table __MODULE__.Table

    @spec install([map()]) :: :ok
    def install(samples) do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set])
      end

      :ets.insert(@table, {:samples, samples})
      Application.put_env(:aiur, :github_cache_history_provider, __MODULE__)
      :ok
    end

    def samples do
      case :ets.lookup(@table, :samples) do
        [{:samples, samples}] -> samples
        _none -> []
      end
    rescue
      ArgumentError -> []
    end
  end

  # The read cache has no per-test process to own, so this double keeps the
  # snapshot deterministic while exercising the LiveView's real join and
  # refresh path.
  defmodule ReadCacheProvider do
    @table __MODULE__.Table

    @spec install(map()) :: :ok
    def install(snapshot) do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set])
      end

      :ets.insert(@table, {:snapshot, snapshot})
      Application.put_env(:aiur, :github_read_cache_provider, __MODULE__)
      :ok
    end

    def snapshot do
      case :ets.lookup(@table, :snapshot) do
        [{:snapshot, snapshot}] -> snapshot
        _none -> %{available?: false, callers: %{}}
      end
    rescue
      ArgumentError -> %{available?: false, callers: %{}}
    end
  end

  defmodule RaisingReadCacheProvider do
    def snapshot, do: raise("read cache unavailable")
  end

  defmodule ExitingReadCacheProvider do
    def snapshot, do: exit(:read_cache_unavailable)
  end

  defmodule AgentMetricsProvider do
    @table __MODULE__.Table

    @spec install(map()) :: :ok
    def install(snapshot) do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set])
      end

      :ets.insert(@table, {:snapshot, snapshot})
      Application.put_env(:aiur, :github_agent_cache_metrics_provider, __MODULE__)
      :ok
    end

    def snapshot do
      case :ets.lookup(@table, :snapshot) do
        [{:snapshot, snapshot}] -> snapshot
        _none -> %{available?: false, measured?: false}
      end
    rescue
      ArgumentError -> %{available?: false, measured?: false}
    end
  end

  # The page's reader→LiveView seam, wired to a real `AgentCacheMetrics`
  # sampler instead of a deterministic double. `snapshot/0` delegates to the
  # sampler's cached snapshot, so the GenServer, its file read, and its
  # `:snapshot` call all run; the only thing faked is the registered name.
  defmodule RealAgentMetricsProvider do
    def snapshot do
      sampler = Application.get_env(:aiur, :github_agent_cache_metrics_sampler, AgentCacheMetrics)
      AgentCacheMetrics.cached_snapshot(sampler)
    end
  end

  @endpoint Endpoint
  @reset ~U[2030-01-01 12:00:00Z]

  setup context do
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    previous_quota = Application.get_env(:aiur, :github_quota_server)
    previous_agent_metrics = Application.get_env(:aiur, :github_agent_cache_metrics_provider)
    previous_read_cache = Application.get_env(:aiur, :github_read_cache_provider)

    endpoint_config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false
      )
      |> Keyword.merge(awaiting_commands_config(context))

    Application.put_env(:aiur, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Source.uninstall()
      Application.delete_env(:aiur, :github_cache_history_provider)
      Application.delete_env(:aiur, :github_quota_history_provider)
      restore_application_env(Endpoint, previous_endpoint)
      restore_application_env(:github_quota_server, previous_quota)
      restore_application_env(:github_agent_cache_metrics_provider, previous_agent_metrics)
      restore_application_env(:github_read_cache_provider, previous_read_cache)
    end)

    :ok
  end

  describe "agent cache effectiveness" do
    test "renders the rolling ratio and raw sample without moving the quota meter" do
      Source.install(entries(2))
      quota = install_quota()
      before = reading(quota)
      AgentMetricsProvider.install(agent_metrics(hits: 1, misses: 3))

      {:ok, _view, html} = live(build_conn(), "/github-cache")
      tile = html |> Floki.parse_document!() |> Floki.find(~s([data-role="agent-cache-hit-rate"]))

      assert Floki.attribute(tile, "data-value") == ["25.0"]
      assert Floki.text(tile) =~ "25.0%"
      assert Floki.text(tile) =~ "1 hit · 3 misses"
      assert Floki.text(tile) =~ "previous 24 hours"
      assert Floki.text(tile) =~ "agent workspaces on this host"
      assert reading(quota) == before
    end

    test "renders unavailable and zero-denominator sources as not measured" do
      Source.install(entries(2))
      install_quota()

      AgentMetricsProvider.install(agent_metrics(available?: false, measured?: false, hits: 0, misses: 0))
      {:ok, _view, unavailable} = live(build_conn(), "/github-cache")
      unavailable_tile = unavailable |> Floki.parse_document!() |> Floki.find(~s([data-role="agent-cache-hit-rate"])) |> Floki.text()
      assert unavailable_tile =~ "Not measured"
      refute unavailable_tile =~ "0.0%"

      AgentMetricsProvider.install(agent_metrics(available?: true, measured?: false, hits: 0, misses: 0, stores: 4))
      {:ok, _view, zero_denominator} = live(build_conn(), "/github-cache")
      zero_denominator_tile = zero_denominator |> Floki.parse_document!() |> Floki.find(~s([data-role="agent-cache-hit-rate"])) |> Floki.text()
      assert zero_denominator_tile =~ "Not measured"
      refute zero_denominator_tile =~ "0.0%"
    end

    test "refreshes the durable ratio on the quota history cadence and labels partial coverage" do
      Source.install(entries(2))
      install_quota()
      AgentMetricsProvider.install(agent_metrics(available?: false, measured?: false, hits: 0, misses: 0))

      {:ok, view, initial} = live(build_conn(), "/github-cache")
      assert initial =~ "Not measured"

      AgentMetricsProvider.install(agent_metrics(hits: 4, misses: 1, partial?: true, malformed_rows: 2))
      send(view.pid, {:quota_history_sampled, 2})
      refreshed = render(view)

      assert refreshed =~ "80.0%"
      assert refreshed =~ "Partial coverage"
      assert refreshed =~ "2 malformed rows"
    end

    test "a real running sampler feeds the page through the reader→LiveView path" do
      # Every other test in this block injects a provider double, so a sampler
      # that never starts — a supervision-wiring break — would render "Not
      # measured" forever and the suite would stay green. This one runs a real
      # AgentCacheMetrics sampler against a real counter file and drives the page
      # through it, so the wiring itself is what is under test.
      Source.install(entries(2))
      install_quota()

      events = Path.join(tmp_root(), "agent-cache.tsv")
      File.mkdir_p!(Path.dirname(events))

      File.write!(
        events,
        Enum.join(
          [
            "#{DateTime.to_unix(@reset) - 10}\tticket:2207\thit\tpr\t2207",
            "#{DateTime.to_unix(@reset) - 9}\tticket:2207\tmiss\tpr\t2207\tabsent"
          ],
          "\n"
        ) <> "\n"
      )

      # The reader skips sources whose final write predates the window; the
      # file must look as fresh as its rows.
      File.touch!(events, DateTime.to_unix(@reset))

      sampler =
        start_supervised!(
          {AgentCacheMetrics, name: :github_agent_cache_metrics_real_sampler, paths: [events], clock: fn -> @reset end, interval_ms: 0},
          id: :github_agent_cache_metrics_real_sampler
        )

      Application.put_env(:aiur, :github_agent_cache_metrics_sampler, sampler)
      Application.put_env(:aiur, :github_agent_cache_metrics_provider, RealAgentMetricsProvider)

      on_exit(fn ->
        Application.delete_env(:aiur, :github_agent_cache_metrics_sampler)
      end)

      {:ok, _view, html} = live(build_conn(), "/github-cache")
      tile = html |> Floki.parse_document!() |> Floki.find(~s([data-role="agent-cache-hit-rate]))

      assert Floki.attribute(tile, "data-value") == ["50.0"]
      assert Floki.text(tile) =~ "50.0%"
      assert Floki.text(tile) =~ "1 hit · 1 miss"
    end
  end

  describe "viewing costs nothing" do
    test "opening, patching and holding the page leaves the rate-limit reading untouched" do
      Source.install(entries(12))
      quota = install_quota()

      before = reading(quota)

      {:ok, view, _html} = live(build_conn(), "/github-cache")

      # Every interaction the page offers, in one sitting: enter a group, search,
      # filter both ways, re-sort, open an entry, come back.
      render_patch(view, "/github-cache/issue_comment")
      render_change(view, "search", %{"q" => "1999"})
      view |> element(~s([data-role="freshness-filter"][phx-value-freshness="stale"])) |> render_click()
      view |> element(~s([data-role="writer-filter"][phx-value-writer="webhook"])) |> render_click()
      view |> element(~s([data-role="sort-control"][phx-value-sort="identity"])) |> render_click()
      view |> element(~s([data-role="body-filter"][phx-value-body="bodyless"])) |> render_click()
      render_patch(view, "/github-cache/issue_comment/issue_comment:owner:repo:1")
      render_patch(view, "/github-cache")

      # Holding it open: a store change arrives and the page re-renders.
      send(view.pid, {:github_resource_changed, %{key: {:issue_comment, "owner", "repo", "1"}}})
      _held = render(view)

      assert reading(quota) == before
    end

    test "the headline tile reads zero fetches caused by viewing" do
      Source.install(entries(3))
      install_quota()

      {:ok, _view, html} = live(build_conn(), "/github-cache")

      tile = html |> Floki.parse_document!() |> Floki.find(~s([data-role="view-fetches"]))

      assert Floki.attribute(tile, "data-value") == ["0"]
      assert Floki.text(tile) =~ "Fetches caused by viewing"
    end

    test "filtering and sorting never read the store" do
      Source.install(entries(40))

      {:ok, view, _html} = live(build_conn(), "/github-cache/issue_comment")
      settled = Source.reads()

      render_change(view, "search", %{"q" => "owner"})
      view |> element(~s([data-role="writer-filter"][phx-value-writer="webhook"])) |> render_click()
      view |> element(~s([data-role="sort-control"][phx-value-sort="identity"])) |> render_click()

      # Client-side over loaded state. A filter that re-read would make typing in
      # a search box cost budget by a longer route.
      assert Source.reads() == settled
    end

    test "the page offers no control that could cause a fetch" do
      Source.install(entries(5))

      # Loaded with a filter applied so the clear control is on the page too —
      # every control the page can ever show is present at once.
      {:ok, _view, html} = live(build_conn(), "/github-cache/issue_comment?writer=webhook")
      document = Floki.parse_document!(html)

      # Interactive elements only. The prose says "no invalidate, no refresh",
      # and asserting over raw text would match the sentence promising their
      # absence, which is not the same as their absence.
      handlers =
        document
        |> Floki.find("#github-cache-page [phx-click]")
        |> Floki.attribute("phx-click")
        |> Enum.uniq()
        |> Enum.sort()

      assert handlers == ["clear-filters", "filter-body", "filter-freshness", "filter-writer", "sort"]

      forms = document |> Floki.find("#github-cache-page form") |> Floki.attribute("phx-change")
      assert Enum.uniq(forms) == ["search"]
    end

    test "the read path cannot reach a GitHub client at all" do
      code =
        "../../../lib/aiur_web/live/github_cache_live.ex"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> strip_prose()

      # Structural, not behavioural. "We are careful not to fetch" decays; "there
      # is nothing here that could" does not. Prose is stripped first so a
      # comment explaining why the transport is absent does not read as its
      # presence.
      for forbidden <- ["GitHub.Client", "GitHub.Transport", "GitHub.Comments", "GitHub.Issues", "System.cmd", "Req."] do
        refute code =~ forbidden
      end
    end

    test "no module on the read path can reach a GitHub client" do
      # Scanning only the LiveView would miss a transport introduced one module
      # down, in the projection or the source — which is where a "just fetch it
      # on a miss" would actually be written. The history sampler is on the same
      # path (it feeds the charts), so it is scanned with the rest.
      root = Path.expand("../../../lib/aiur/github", __DIR__)

      files =
        ["agent_cache_metrics.ex", "cache_inspector.ex", "cache_history.ex" | Enum.map(File.ls!(Path.join(root, "cache_inspector")), &Path.join("cache_inspector", &1))]

      for relative <- files do
        code = root |> Path.join(relative) |> File.read!() |> strip_prose()

        for forbidden <- ["GitHub.Client", "GitHub.Transport", "GitHub.Comments", "GitHub.Issues", "System.cmd", "Req."] do
          refute code =~ forbidden, "#{relative} can reach #{forbidden}"
        end
      end
    end
  end

  describe "writes are visible arriving" do
    test "a webhook delivery appears and its row is highlighted, with no API call" do
      Source.install(entries(3))
      quota = install_quota()
      before = reading(quota)

      {:ok, view, html} = live(build_conn(), "/github-cache/issue_comment")
      assert changed_rows(html) == []

      Source.install(entries(4, source: :webhook))
      send(view.pid, {:github_resource_changed, %{key: {:issue_comment, "owner", "repo", "4"}, source: :webhook}})

      assert changed_rows(render(view)) == ["issue_comment:owner:repo:4"]
      assert reading(quota) == before
    end

    test "an agent mutation write-through appears the same way" do
      Source.install(entries(2))
      quota = install_quota()
      before = reading(quota)

      {:ok, view, _html} = live(build_conn(), "/github-cache/issue_comment")

      Source.install(entries(3, source: :mutation))
      send(view.pid, {:github_resource_changed, %{key: {:issue_comment, "owner", "repo", "3"}, source: :mutation}})

      html = render(view)

      assert html =~ "issue_comment:owner:repo:3"
      assert changed_rows(html) == ["issue_comment:owner:repo:3"]
      assert reading(quota) == before
    end

    test "a real store deposit reaches the page through the store's own channel" do
      # The three tests above drive the page's mailbox directly, which proves the
      # rendering but not the wiring. This one writes to the actual store and
      # asserts the page hears about it, because a subscription to a topic
      # nothing publishes on looks exactly like a cache where nothing happened.
      Source.uninstall()
      key = ResourceStore.key(:issue_comment, "owner", "repo", 55_501)
      quota = install_quota()
      before = reading(quota)

      {:ok, view, _html} = live(build_conn(), "/github-cache/issue_comment")

      :ok = ResourceStore.put_resource(key, %{"body" => "arrived by webhook"}, source: :webhook, version: "v1")

      html = render(view)

      assert html =~ "issue_comment:owner:repo:55501"
      assert changed_rows(html) == ["issue_comment:owner:repo:55501"]

      # The write cost somebody a round trip. Watching it arrive cost nothing.
      assert reading(quota) == before
    end

    test "an unreadable change event still refreshes rather than freezing the page" do
      Source.install(entries(1))

      {:ok, view, _html} = live(build_conn(), "/github-cache/issue_comment")

      Source.install(entries(2))
      send(view.pid, {:github_resource_changed, :not_a_key_shape})

      # "No events" and "nothing changed" look identical on screen, so an event
      # this page cannot parse must still cause a re-read rather than a silence.
      assert render(view) =~ "issue_comment:owner:repo:2"
    end
  end

  describe "three layers" do
    test "the map groups by type and shows freshness without reading text" do
      Source.install(entries(3) ++ entries(2, resource_type: :pull_request))

      {:ok, _view, html} = live(build_conn(), "/github-cache")

      cells = html |> Floki.parse_document!() |> Floki.find(~s([data-role="map-cell"]))

      assert length(cells) == 2
      assert "issue_comment" in Floki.attribute(cells, "data-resource-type")
      assert "pull_request" in Floki.attribute(cells, "data-resource-type")

      # Colour and size come from data attributes and inline custom properties,
      # so a stale region is visible before any label is read.
      assert cells |> Floki.attribute("data-worst") |> Enum.all?(&(&1 != ""))
      assert cells |> Floki.attribute("style") |> Enum.all?(&(&1 =~ "--ghc-weight"))
    end

    test "every layer transition works in both directions" do
      Source.install(entries(3))

      {:ok, view, html} = live(build_conn(), "/github-cache")
      assert html =~ ~s(data-role="map-layer")

      html = view |> element(~s(a[data-role="map-cell"])) |> render_click()
      assert html =~ ~s(data-role="group-layer")

      html = view |> element(~s(tr[data-role="entry-row"] a), "issue_comment:owner:repo:1") |> render_click()
      assert html =~ ~s(data-role="entry-layer")

      assert render_patch(view, "/github-cache/issue_comment") =~ ~s(data-role="group-layer")
      assert render_patch(view, "/github-cache") =~ ~s(data-role="map-layer")
    end

    test "a deep-linked entry URL resolves on its own" do
      Source.install(entries(3))

      {:ok, _view, html} = live(build_conn(), "/github-cache/issue_comment/issue_comment:owner:repo:2")

      document = Floki.parse_document!(html)

      assert document |> Floki.find(~s([data-role="field-key"])) |> Floki.text() == "issue_comment:owner:repo:2"
      assert document |> Floki.find(~s([data-role="field-etag"])) |> Floki.text() =~ "etag-2"
      assert document |> Floki.find(~s([data-role="payload"])) |> Floki.text() =~ "body-2"
    end

    test "a deep link to something the cache does not hold says so without fetching" do
      Source.install(entries(1))
      quota = install_quota()
      before = reading(quota)

      {:ok, _view, html} = live(build_conn(), "/github-cache/issue_comment/issue_comment:owner:repo:9999")

      assert html =~ "Nothing is cached under"
      assert reading(quota) == before
    end

    test "filters are URL-addressable so a filtered view can be pasted as evidence" do
      Source.install(entries(6, source: :webhook))

      {:ok, _view, html} = live(build_conn(), "/github-cache/issue_comment?writer=webhook&sort=identity")

      document = Floki.parse_document!(html)

      assert document
             |> Floki.find(~s([data-role="writer-filter"][phx-value-writer="webhook"]))
             |> Floki.attribute("data-active") == ["true"]

      assert document |> Floki.find(~s([data-role="active-filters"])) |> Floki.text() =~ "writer: webhook"
    end

    test "the active filter set is visible and clears in one click" do
      Source.install(entries(6))

      {:ok, view, _html} = live(build_conn(), "/github-cache/issue_comment?writer=webhook&q=1")

      assert render(view) =~ ~s(data-role="active-filters")

      html = view |> element(~s([data-role="clear-filters"])) |> render_click()

      refute html =~ ~s(data-role="active-filters")
    end
  end

  describe "history charts" do
    test "render on the overview page once the ring has enough samples" do
      Source.install(entries(3))
      HistoryProvider.install(history_samples())

      {:ok, _view, html} = live(build_conn(), "/github-cache")
      document = Floki.parse_document!(html)

      assert document |> Floki.find(~s([data-role="trends"])) != []
      assert document |> Floki.find(~s([data-role="entries-chart"] svg)) != []
      assert document |> Floki.find(~s([data-role="freshness-chart"] svg)) != []

      # The note says what the charts cover, so a screenshot does not imply the
      # sampler saw more than it did.
      assert document |> Floki.find(~s([data-role="history-window"])) |> Floki.text() =~ "since this daemon boot"
    end

    test "say they are collecting when the ring is too new to draw" do
      Source.install(entries(3))
      HistoryProvider.install([hd(history_samples())])

      {:ok, _view, html} = live(build_conn(), "/github-cache")

      assert html =~ ~s(data-role="history-collecting")
      refute html =~ ~s(data-role="entries-chart")
      refute html =~ ~s(data-role="freshness-chart")
    end

    test "charts live on the overview only, not on a group page" do
      Source.install(entries(3))
      HistoryProvider.install(history_samples())

      {:ok, _view, html} = live(build_conn(), "/github-cache/issue_comment")

      refute html =~ ~s(data-role="trends")
    end

    test "a sampled notification redraws the charts without costing a fetch" do
      Source.install(entries(3))
      quota = install_quota()
      before = reading(quota)
      HistoryProvider.install(history_samples(6))

      {:ok, view, _html} = live(build_conn(), "/github-cache")

      # The note spans the retained ring: six 30s samples = "Last 2m".
      assert render(view) =~ "Last 2m"

      # A new sample lands and the sampler notifies the page. The page must
      # re-read the ring (now four samples = "Last 1m"), not keep the stale six
      # it mounted with — otherwise the note would still say 2m.
      HistoryProvider.install(history_samples(4))
      send(view.pid, {:cache_history_sampled, 4})

      html = render(view)
      assert html =~ "Last 1m"
      assert html =~ ~s(data-role="entries-chart")
      assert reading(quota) == before
    end
  end

  describe "honesty about what is shown" do
    test "with more than a thousand entries it states how many were elided" do
      Source.install(entries(1_200))

      {:ok, _view, html} = live(build_conn(), "/github-cache/issue_comment")

      elided = html |> Floki.parse_document!() |> Floki.find(~s([data-role="elided"])) |> Floki.text()

      # Never silently a subset: an operator who scrolls to the bottom of a
      # truncated list would otherwise conclude the cache does not hold
      # something it does hold.
      assert elided =~ "700 matching entries were not drawn"
      assert elided =~ "at most\n      500 rows per resource type"
    end

    test "a deep link to an entry past the row cap resolves instead of denying it" do
      # The row cap is a rendering budget, not a claim about what the cache
      # holds. `find/2` searching only the drawn rows made the entry page print
      # "the cache simply does not hold this resource" about a resource the
      # cache definitely held — an affirmative false statement on the one page
      # whose premise is honesty about what it shows.
      Source.install(entries(1_200))

      {:ok, _view, html} = live(build_conn(), "/github-cache/issue_comment/issue_comment:owner:repo:1200")

      refute html =~ "Nothing is cached under"
      assert html =~ ~s(data-role="field-key")
    end

    test "a group whose rows are all past the cap never claims nothing matches" do
      Source.install(entries(1_200))

      {:ok, _view, html} = live(build_conn(), "/github-cache/issue_comment")

      refute html =~ ~s(data-role="no-matches")
      assert html =~ ~s(data-role="entry-row")
    end

    test "no store at all says so rather than rendering a zero" do
      # A daemon whose store failed to start, or a CLI process that never
      # started one. The page must say there is nothing to read, because "no
      # store" and "an empty store" are different facts and only one of them is
      # a problem — rendering the second as the first would tell an operator
      # their cache is empty when it is really their inspector that is blind.
      defmodule NoStoreSource do
        @behaviour Aiur.GitHub.CacheInspector.Source
        @impl true
        def available?, do: false
        @impl true
        def entries, do: []
      end

      Application.put_env(:aiur, :github_cache_inspector_source, NoStoreSource)
      on_exit(fn -> Application.delete_env(:aiur, :github_cache_inspector_source) end)

      {:ok, _view, html} = live(build_conn(), "/github-cache")

      assert html =~ "No cache store is running yet"
      assert html =~ "not the same as nothing having happened"
    end

    test "a running but empty store says the cache is empty, not that it is missing" do
      Source.install([])

      {:ok, _view, html} = live(build_conn(), "/github-cache")

      assert html =~ "The cache holds no entries yet"
      refute html =~ "No cache store is running yet"
    end

    test "an entry holding a validator and no body is not shown as cached" do
      # `drop_data/1` keeps the ETag on purpose. A reader that reads this as a
      # hit sends the validator, is answered `304`, and receives no data — it has
      # paid for a call and learned nothing. That was a P1 in the store
      # foundation, so the page must never render it the way it renders a hit.
      Source.install([
        Map.merge(hd(entries(1)), %{data?: false, data: nil, fetched_at_ms: nil}),
        Enum.at(entries(2), 1)
      ])

      {:ok, _view, html} = live(build_conn(), "/github-cache/issue_comment")
      document = Floki.parse_document!(html)

      bodyless = Floki.find(document, ~s(tr[data-role="entry-row"][data-bodyless="true"]))

      assert Floki.attribute(bodyless, "data-identity") == ["issue_comment:owner:repo:1"]

      # Not colour alone: the cell says what the state is, so it survives a
      # screenshot, a colour-blind reader and a copied-out table.
      assert bodyless |> Floki.find(~s(td[data-role="body"])) |> Floki.text() =~ "validator only"
      assert Floki.attribute(bodyless, "class") == ["ghc-row ghc-row-bodyless"]

      # And it is counted where an operator asking "why did that read cost
      # money" is looking, rather than folded into the entry total.
      tile = Floki.find(document, ~s([data-role="bodyless-count"]))
      assert Floki.attribute(tile, "data-value") == ["1"]
      assert Floki.text(tile) =~ "Validator only, no body"
    end

    test "opening a bodyless entry explains the 304 rather than showing an empty payload" do
      Source.install([Map.merge(hd(entries(1)), %{data?: false, data: nil, fetched_at_ms: nil})])

      {:ok, _view, html} = live(build_conn(), "/github-cache/issue_comment/issue_comment:owner:repo:1")
      document = Floki.parse_document!(html)

      assert document |> Floki.find(~s([data-role="bodyless-warning"])) |> Floki.text() =~ "304 with no data"
      assert document |> Floki.find(~s([data-role="field-body"])) |> Floki.text() =~ "validator only"

      # The validator really is held, and the page says so. Reporting "nothing
      # cached" would be the opposite error.
      assert document |> Floki.find(~s([data-role="field-etag"])) |> Floki.text() =~ "etag-1"
      assert document |> Floki.find(~s([data-role="payload"])) |> Floki.text() =~ "must fetch unconditionally"
    end

    test "the bodyless filter narrows to exactly those entries" do
      Source.install([
        Map.merge(hd(entries(1)), %{data?: false, data: nil, fetched_at_ms: nil}),
        Enum.at(entries(2), 1)
      ])

      {:ok, _view, html} = live(build_conn(), "/github-cache/issue_comment?body=bodyless")

      rows =
        html
        |> Floki.parse_document!()
        |> Floki.find(~s(tr[data-role="entry-row"]))
        |> Floki.attribute("data-identity")

      assert rows == ["issue_comment:owner:repo:1"]
    end

    test "no secret material renders, even when the cache holds some" do
      token = "ghp_" <> String.duplicate("A", 36)

      Source.install([
        %{
          key: {:issue_comment, "owner", "repo", "1"},
          etag: "etag-1",
          version: "2026-08-17T00:00:00Z",
          source: :webhook,
          fetched_at_ms: System.system_time(:millisecond),
          data?: true,
          data: %{
            "body" => "here is my token #{token} please do not print it",
            "authorization" => "Bearer #{token}",
            "installation" => %{"token" => token},
            "nested" => [%{"client_secret" => token}]
          }
        }
      ])

      {:ok, _view, html} = live(build_conn(), "/github-cache/issue_comment/issue_comment:owner:repo:1")

      refute html =~ token
      refute html =~ "ghp_AAAA"
      assert html =~ "REDACTED"
    end
  end

  describe "authentication" do
    test "the page sits behind dashboard auth like every other page" do
      Source.install(entries(1))

      response = get(Phoenix.ConnTest.build_conn(), "/github-cache")

      assert response.status == 401
    end

    test "unconfigured dashboard credentials refuse the route with their cause" do
      Source.install(entries(1))
      username = System.get_env("AIUR_DASHBOARD_USERNAME")
      password = System.get_env("AIUR_DASHBOARD_PASSWORD")
      System.delete_env("AIUR_DASHBOARD_USERNAME")
      System.delete_env("AIUR_DASHBOARD_PASSWORD")

      on_exit(fn ->
        restore_env("AIUR_DASHBOARD_USERNAME", username)
        restore_env("AIUR_DASHBOARD_PASSWORD", password)
      end)

      response = get(Phoenix.ConnTest.build_conn(), "/github-cache")

      assert response.status == 503
      assert response.resp_body =~ "Dashboard authentication is not configured"
    end
  end

  defp entries(count, opts \\ []) do
    resource_type = Keyword.get(opts, :resource_type, :issue_comment)
    source = Keyword.get(opts, :source, :webhook)
    now = DateTime.utc_now()

    for index <- 1..count do
      %{
        key: {resource_type, "owner", "repo", Integer.to_string(index)},
        etag: "etag-#{index}",
        version: "v#{index}",
        data_version: "v#{index}",
        source: source,
        fetched_at_ms: DateTime.to_unix(DateTime.add(now, -index, :second), :millisecond),
        recorded_at_ms: DateTime.to_unix(now, :millisecond),
        data?: true,
        data: %{"id" => index, "body" => "body-#{index}"}
      }
    end
  end

  # `count` samples so the trends section has enough to draw two charts. Each is
  # a plausible cache state; the totals rise so the lines are not flat. 30s
  # spacing means `count` samples span `(count - 1) * 30s`, which the page's note
  # rounds to minutes — that rounding is what the redraw test asserts on.
  defp history_samples(count \\ 6) do
    now = DateTime.utc_now()
    t0 = DateTime.to_unix(now, :millisecond)

    for i <- 0..(count - 1) do
      %{
        t_ms: t0 + i * 30_000,
        total: 10 + i,
        with_body: 8 + i,
        bodyless: 2,
        fresh: 6 + i,
        stale: 2,
        expired: 1,
        unknown: 1
      }
    end
  end

  # A private meter, installed on the same seam `Transport` uses, seeded with
  # one observation so the window has a real `used` figure to compare against.
  describe "what is spending the budget" do
    test "shows served-free reads without changing the spend ranking or totals" do
      Source.install(entries(2))
      quota = install_graphql_quota()
      Quota.observe(quota, graphql_request(:issue_relationships), graphql_response(2))
      _settle = Quota.snapshot(quota)

      ReadCacheProvider.install(%{
        available?: true,
        callers: %{
          "comment_poll_batch" => %{hit: 0, refused: 55},
          "issue_relationships" => %{hit: 12, miss: 1}
        }
      })

      before = reading(quota)
      {:ok, _view, html} = live(build_conn(), "/github-cache")
      graphql = budget_block(html)

      assert callers(graphql) == [
               {"comment_poll_batch", "93"},
               {"review_threads_unaddressed", "50"},
               {"issue_relationships", "2"},
               {"ci_poll_batch", "1"}
             ]

      assert served_free(graphql, "comment_poll_batch") == "55 policy refusals"
      assert served_free(graphql, "review_threads_unaddressed") == "not observed by ReadCache"
      assert served_free(graphql, "issue_relationships") == "12 reads"
      assert served_free(graphql, "ci_poll_batch") == "not observed by ReadCache"

      outside = Floki.find(graphql, ~s([data-role="usage-outside"]))
      assert Floki.attribute(outside, "data-value") == ["854"]
      assert graphql |> Floki.find(~s([data-role="usage-served-free-outside"])) |> Floki.text() =~ "not applicable"
      assert reading(quota) == before
    end

    test "distinguishes an unavailable cache from an available cache with no hits" do
      Source.install(entries(2))
      quota = install_graphql_quota()
      Quota.observe(quota, graphql_request(:issue_relationships), graphql_response(2))
      _settle = Quota.snapshot(quota)

      ReadCacheProvider.install(%{
        available?: true,
        callers: %{"issue_relationships" => %{hit: 0, miss: 1}}
      })

      {:ok, view, html} = live(build_conn(), "/github-cache")
      assert html |> budget_block() |> served_free("issue_relationships") == "none this boot"

      ReadCacheProvider.install(%{available?: false, callers: %{}})
      send(view.pid, {:quota_history_sampled, 1})

      assert view |> render() |> budget_block() |> served_free("issue_relationships") == "cache unavailable"
    end

    test "keeps the ranking available when the cache provider raises or exits" do
      Source.install(entries(2))
      install_graphql_quota()
      Application.put_env(:aiur, :github_read_cache_provider, RaisingReadCacheProvider)

      {:ok, view, html} = live(build_conn(), "/github-cache")
      assert html |> budget_block() |> served_free("comment_poll_batch") == "cache unavailable"

      Application.put_env(:aiur, :github_read_cache_provider, ExitingReadCacheProvider)
      send(view.pid, {:quota_history_sampled, 1})

      assert view |> render() |> budget_block() |> served_free("comment_poll_batch") == "cache unavailable"
      assert Process.alive?(view.pid)
    end

    test "refreshes served-free reads on the quota sampler cadence without spending quota" do
      Source.install(entries(2))
      quota = install_graphql_quota()
      Quota.observe(quota, graphql_request(:issue_relationships), graphql_response(2))
      _settle = Quota.snapshot(quota)
      ReadCacheProvider.install(%{available?: true, callers: %{"issue_relationships" => %{hit: 1}}})

      before = reading(quota)
      {:ok, view, _html} = live(build_conn(), "/github-cache")
      assert view |> render() |> budget_block() |> served_free("issue_relationships") == "1 read"

      ReadCacheProvider.install(%{available?: true, callers: %{"issue_relationships" => %{hit: 5}}})
      send(view.pid, {:quota_history_sampled, 1})

      assert view |> render() |> budget_block() |> served_free("issue_relationships") == "5 reads"
      assert reading(quota) == before
    end

    test "keeps the widened ranking keyboard-reachable on narrow viewports" do
      Source.install(entries(2))
      install_graphql_quota()
      ReadCacheProvider.install(%{available?: true, callers: %{}})

      {:ok, _view, html} = live(build_conn(), "/github-cache")

      region = html |> budget_block() |> Floki.find(~s([data-role="usage-table-scroll"]))
      assert Floki.attribute(region, "role") == ["region"]
      assert Floki.attribute(region, "tabindex") == ["0"]
      assert Floki.attribute(region, "aria-label") == ["graphql spend ranking"]
    end

    test "ranks callers by points and renders the unissued remainder as its own row" do
      Source.install(entries(2))
      install_graphql_quota()

      {:ok, _view, html} = live(build_conn(), "/github-cache")
      graphql = budget_block(html)

      # Points, not calls: review_threads_unaddressed made more calls and cost
      # less, and a request-count ranking would invert them.
      assert callers(graphql) == [
               {"comment_poll_batch", "93"},
               {"review_threads_unaddressed", "50"},
               {"ci_poll_batch", "1"}
             ]

      # The row that makes the ranking honest. 1,000 spent, 144 explained.
      outside = Floki.find(graphql, ~s([data-role="usage-outside"]))
      assert Floki.attribute(outside, "data-value") == ["856"]
      assert graphql |> Floki.find(~s([data-role="usage-outside-row"])) |> Floki.text() =~ "856"
      # This meter booted mid-window, so the label says what it can support.
      # Whose spend the remainder is has its own tests below.
      assert Floki.text(outside) =~ "Spend this daemon did not observe"
    end

    test "the two budgets are rendered apart and never summed" do
      Source.install(entries(2))
      install_graphql_quota()

      {:ok, _view, html} = live(build_conn(), "/github-cache")

      budgets =
        html
        |> Floki.parse_document!()
        |> Floki.find(~s([data-role="usage-budget"]))
        |> Floki.attribute("data-budget")

      assert budgets == ["graphql", "core"]
    end

    test "a meter that has observed nothing says so rather than drawing a zero" do
      Source.install(entries(2))
      install_quota(seed?: false)

      {:ok, _view, html} = live(build_conn(), "/github-cache")
      document = Floki.parse_document!(html)

      assert document |> Floki.find(~s([data-role="usage-unobserved"])) |> Floki.text() =~
               "has not observed a rate-limit window"

      assert Floki.find(document, ~s([data-role="usage-budget"])) == []
    end

    test "the chart waits for two observed samples and says it is collecting until then" do
      Source.install(entries(2))
      install_graphql_quota()

      {:ok, _view, collecting} = live(build_conn(), "/github-cache")
      assert collecting |> budget_block() |> Floki.find(~s([data-role="usage-collecting"])) != []
      assert collecting |> budget_block() |> Floki.find(~s([data-role="usage-chart"])) == []

      __MODULE__.QuotaHistoryProvider.install(quota_samples())
      {:ok, _view, drawn} = live(build_conn(), "/github-cache")
      chart = drawn |> budget_block() |> Floki.find(~s([data-role="usage-chart"]))

      assert chart != []
      # Identity is never colour alone: every band is named in the legend.
      legend = chart |> Floki.find(~s([data-band])) |> Floki.attribute("data-band")
      assert "__outside__" in legend
      assert "comment_poll_batch" in legend
    end

    test "a meter that booted mid-window does not blame the remainder on another consumer" do
      # The deploy case, and the moment this page is most likely to be opened.
      # `install_graphql_quota/0` starts the meter half an hour into the window,
      # so it cannot account for the first half — including anything the daemon
      # itself spent before the restart.
      Source.install(entries(2))
      install_graphql_quota()

      {:ok, _view, html} = live(build_conn(), "/github-cache")
      graphql = budget_block(html)

      outside = Floki.find(graphql, ~s([data-role="usage-outside"]))
      assert Floki.attribute(outside, "data-observed-whole-window") == ["false"]
      assert Floki.text(outside) =~ "Spend this daemon did not observe"
      row = graphql |> Floki.find(~s([data-role="usage-outside-row"])) |> Floki.text()
      assert row =~ "not observed by this daemon"
      # "shared credential" names a cause and needs the same evidence.
      refute row =~ "shared credential"
      assert row =~ "outside the meter's reach"

      explainer = graphql |> Floki.find(~s([data-role="usage-outside-explainer"])) |> Floki.text()
      refute explainer =~ "other consumers"
      assert explainer =~ "does not survive a restart"
    end

    test "it says how far back it can see and when the claim becomes safe again" do
      # Not a hedge: an operator four minutes after a deploy needs to know the
      # number is temporarily unattributable and roughly when to look again.
      Source.install(entries(2))
      install_graphql_quota()

      {:ok, _view, html} = live(build_conn(), "/github-cache")
      reach = html |> budget_block() |> Floki.find(~s([data-role="usage-reach"])) |> Floki.text()

      assert reach =~ "not attributable yet"
      assert reach =~ "observing since"
      assert reach =~ "this window opened at"
      # The reset is when the meter's reach covers the whole window again.
      assert reach =~ DateTime.to_iso8601(@reset)
    end

    test "a meter that covered the whole window keeps the other-consumers claim" do
      Source.install(entries(2))
      install_graphql_quota(observing_since: DateTime.add(@reset, -7_200, :second))

      {:ok, _view, html} = live(build_conn(), "/github-cache")
      graphql = budget_block(html)

      outside = Floki.find(graphql, ~s([data-role="usage-outside"]))
      assert Floki.attribute(outside, "data-observed-whole-window") == ["true"]
      assert Floki.text(outside) =~ "Not issued by this daemon"
      row = graphql |> Floki.find(~s([data-role="usage-outside-row"])) |> Floki.text()
      assert row =~ "not issued by this daemon"
      assert row =~ "shared credential"
      assert graphql |> Floki.find(~s([data-role="usage-outside-explainer"])) |> Floki.text() =~ "other consumers"
      assert Floki.find(graphql, ~s([data-role="usage-reach"])) == []
    end

    test "the ranking separates served-free reads from calls that reached GitHub" do
      # A cache hit never reaches `Quota`, so the page must keep it outside the
      # spend figures while making it visible beside the caller.
      Source.install(entries(2))
      install_graphql_quota()

      {:ok, _view, html} = live(build_conn(), "/github-cache")
      # Normalised, because the assertion is about the sentence and not about
      # where the template happens to wrap it.
      caveat =
        html
        |> budget_block()
        |> Floki.find(~s([data-role="usage-cache-caveat"]))
        |> Floki.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      assert caveat =~ "ranks what reached GitHub"
      assert caveat =~ "contributes no points, calls, share or totals"
      assert caveat =~ "reports those reads separately"
    end

    test "an assumed cost is never presented as a measurement" do
      Source.install(entries(2))
      install_graphql_quota()

      {:ok, _view, html} = live(build_conn(), "/github-cache")
      graphql = budget_block(html)

      sources =
        graphql
        |> Floki.find(~s([data-role="usage-caller"]))
        |> Enum.map(fn row -> {row |> Floki.find("td") |> hd() |> Floki.text(), row |> Floki.find("td") |> List.last() |> Floki.text()} end)

      assert {"comment_poll_batch", "reported"} in sources
      assert {"ci_poll_batch", "assumed"} in sources
      assert graphql |> Floki.find(~s([data-role="usage-estimated"])) |> Floki.text() =~ "assumed"
    end

    test "the usage layer renders even when no cache store is running" do
      # The meter is a different process from the store: a budget can be burning
      # while nothing at all is cached, and hiding the ranking behind an
      # unavailable store would hide it at the worst moment.
      install_graphql_quota()

      {:ok, _view, html} = live(build_conn(), "/github-cache")

      assert html |> Floki.parse_document!() |> Floki.find(~s([data-role="usage-budget"])) != []
    end
  end

  # A deterministic quota-history double, the sibling of `HistoryProvider`.
  defmodule QuotaHistoryProvider do
    @table __MODULE__.Table

    @spec install([map()]) :: :ok
    def install(samples) do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set])
      end

      :ets.insert(@table, {:samples, samples})
      Application.put_env(:aiur, :github_quota_history_provider, __MODULE__)
      :ok
    end

    def samples do
      case :ets.lookup(@table, :samples) do
        [{:samples, samples}] -> samples
        _none -> []
      end
    rescue
      ArgumentError -> []
    end
  end

  defp budget_block(html) do
    html |> Floki.parse_document!() |> Floki.find(~s([data-role="usage-budget"][data-budget="graphql"]))
  end

  defp callers(graphql) do
    graphql
    |> Floki.find(~s([data-role="usage-caller"]))
    |> Enum.map(fn row ->
      cells = Floki.find(row, "td")
      {row |> Floki.attribute("data-caller") |> hd(), cells |> Enum.at(1) |> Floki.text()}
    end)
  end

  defp served_free(graphql, caller) do
    graphql
    |> Floki.find(~s([data-role="usage-caller"][data-caller="#{caller}"] [data-role="usage-served-free"]))
    |> Floki.text()
    |> String.trim()
  end

  defp quota_samples do
    for index <- 0..1 do
      %{
        t_ms: DateTime.to_unix(DateTime.add(@reset, -1800 + index * 30, :second), :millisecond),
        budgets: %{
          "graphql" => %{
            resource: "graphql",
            callers: [
              %{caller: "comment_poll_batch", points: 93, calls: 9, points_per_hour: 1.0, estimated?: false}
            ],
            attributed: 93,
            spend: 1_000,
            outside: 907,
            direction: :shortfall,
            estimated?: false,
            window: %{limit: 5_000, remaining: 4_000, used: 1_000, reset_at: @reset}
          }
        }
      }
    end
  end

  # A meter that has seen the budget that actually exhausts. Two priced calls
  # and one the response never priced, so the page has both a reported and an
  # assumed row to tell apart.
  defp install_graphql_quota(opts \\ []) do
    quota = install_quota(opts)

    for {caller, cost} <- [{:comment_poll_batch, 93}, {:review_threads_unaddressed, 50}] do
      Quota.observe(quota, graphql_request(caller), graphql_response(cost))
    end

    Quota.observe(quota, graphql_request(:ci_poll_batch), graphql_response(nil))
    _settle = Quota.snapshot(quota)
    quota
  end

  defp graphql_request(caller) do
    %{method: :post, url: "https://api.github.com/graphql", token: "t", caller: caller, body: %{"query" => "query { viewer { login } }"}}
  end

  defp graphql_response(cost) do
    data = if is_integer(cost), do: %{"rateLimit" => %{"cost" => cost}}, else: %{}

    {:ok,
     %{
       status: 200,
       headers: [
         {"x-ratelimit-resource", "graphql"},
         {"x-ratelimit-limit", "5000"},
         {"x-ratelimit-remaining", "4000"},
         {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(@reset))}
       ],
       body: %{"data" => data}
     }}
  end

  defp install_quota(opts \\ []) do
    # The clock sits half an hour into the window, so by default the meter
    # booted mid-window and cannot account for the whole of it. Tests that need
    # full coverage pass an earlier `observing_since`.
    settings =
      [name: nil, clock: fn -> DateTime.add(@reset, -1800, :second) end, hold_dir: nil] ++
        case Keyword.fetch(opts, :observing_since) do
          {:ok, started_at} -> [started_at: started_at]
          :error -> []
        end

    quota =
      start_supervised!({Quota, settings}, id: {:quota, System.unique_integer([:positive])})

    if Keyword.get(opts, :seed?, true) do
      Quota.observe(quota, %{method: :get, url: "https://api.github.com/repos/o/r", token: "t"}, window_response())
    end

    _settle = Quota.snapshot(quota)

    Application.put_env(:aiur, :github_quota_server, quota)
    quota
  end

  defp reading(quota) do
    snapshot = Quota.snapshot(quota)

    Map.new(snapshot.windows, fn {resource, window} -> {resource, window.used} end)
  end

  defp window_response do
    {:ok,
     %{
       status: 200,
       headers: [
         {"x-ratelimit-resource", "core"},
         {"x-ratelimit-limit", "5000"},
         {"x-ratelimit-remaining", "4999"},
         {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(@reset))}
       ],
       body: %{}
     }}
  end

  defp agent_metrics(opts) do
    values = Enum.into(opts, %{})
    hits = Map.get(values, :hits, 2)
    misses = Map.get(values, :misses, 2)
    sample_size = hits + misses

    Map.merge(
      %{
        available?: true,
        measured?: sample_size > 0,
        partial?: false,
        hits: hits,
        misses: misses,
        stores: 1,
        coalesced: 0,
        sample_size: sample_size,
        hit_ratio: if(sample_size > 0, do: hits / sample_size, else: nil),
        miss_reasons: %{},
        sources_read: 3,
        skipped_sources: 0,
        malformed_rows: 0,
        window_started_at: DateTime.add(@reset, -86_400, :second),
        window_ended_at: @reset
      },
      values
    )
  end

  defp awaiting_commands_config(context) do
    [decision_store: AwaitingCommands.start(Map.get(context, :awaiting_counts, %{}))]
  end

  defp changed_rows(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(tr[data-role="entry-row"].ghc-row-changed))
    |> Floki.attribute("data-identity")
  end

  # Drops `#` comments and `@moduledoc`/`@doc` heredocs so a structural check
  # reads the code and not the prose about the code.
  defp strip_prose(source) do
    source
    |> String.replace(~r/@(?:module)?doc\s+"""(?:.|\n)*?"""/, "")
    |> String.split("\n")
    |> Enum.map_join("\n", &Regex.replace(~r/#.*$/, &1, ""))
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  defp build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end

  defp tmp_root do
    path = Aiur.TestSupport.tmp_root!("github-cache-live")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
