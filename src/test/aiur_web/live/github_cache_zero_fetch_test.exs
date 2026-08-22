defmodule AiurWeb.GithubCacheZeroFetchTest do
  @moduledoc """
  A1 applied to the cache inspector itself, asserted by **call count** and run on
  every CI build: opening the GitHub cache page, exercising every control it
  offers, and holding it open across store writes reaches GitHub **zero** times.

  ## Why a page about the cache has to prove this harder than any other page

  The store's central rule is that viewing never causes a fetch. A debug page
  that fetched in order to render the cache would be self-refuting: it would
  show a cache that saves calls while spending them, and the "fetches caused by
  viewing" tile it prints would be measuring the wrong process. So the same
  guard U3 put on the dashboard routes is put on this page, and on the deeper
  paths only this page has — the group layer, the entry layer, the filters, and
  a live store write landing while somebody is watching.

  ## Why this file is hermetic rather than tagged `:external`

  There is a companion way to measure this: read real `x-ratelimit-used` deltas
  from GitHub before and after. That is the operator-facing corroboration, but
  it needs a token and a network, so it can only be an `:external` test — and an
  `:external` test does not run in CI, which makes it useless as a regression
  guard. A guard that never executes protects nothing.

  This file therefore installs a counting plug at Aiur's own transport boundary
  and needs no token, no network and no tags. Every HTTP request Aiur would send
  to GitHub — REST or GraphQL, from any module, on any code path — is counted
  instead of sent, because `Aiur.GitHub.Transport` funnels both through
  `request_options/2` and `Transport.github_graphql/*` shares that path. Zero
  requests is zero rate limit by construction: no window, no shard, no
  propagation delay to argue about.

  This is deliberately the same instrument as
  `AiurWeb.ZeroFetchPageOpenTest` rather than a second, weaker one. Two
  instruments would eventually disagree, and the one that disagreed downward
  would be believed.

  ## The positive control is not optional

  A zero from an instrument that was never wired up looks exactly like a zero
  from a page that does not fetch. `the counter observes a real fetch` drives a
  genuine application call through the same seam and asserts the counter fires,
  so the zeros above it mean something. If that control ever fails, treat every
  other assertion in this file as unproven rather than passing.
  """

  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.GitHub.CacheInspector.ResourceStoreSource
  alias Aiur.GitHub.Issues
  alias Aiur.GitHub.ResourceStore
  alias Aiur.TestSupport.AwaitingCommands
  alias AiurWeb.Endpoint

  @endpoint Endpoint

  setup do
    previous_endpoint = Application.get_env(:aiur, Endpoint)

    endpoint_config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false,
        decision_store: AwaitingCommands.start(%{})
      )

    Application.put_env(:aiur, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})

    {:ok, counter} = Agent.start_link(fn -> [] end)
    previous_options = Application.get_env(:aiur, :github_transport_test_options)

    Application.put_env(:aiur, :github_transport_test_options,
      plug: fn conn ->
        Agent.update(counter, &[{conn.method, conn.request_path} | &1])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "{}")
      end
    )

    # The budget-map layer reads the broker ledger; on a live host the default
    # path points at the operator's real budget.sqlite3. Pointing it at a
    # nonexistent file keeps this zero-fetch measurement from silently reading
    # production state (the ledger read is not a GitHub request, but a hermetic
    # suite should not depend on a host's broker database existing).
    Application.put_env(:aiur, :github_budget_ledger_path, "/nonexistent/aiur-ghc-zero-fetch.sqlite3")

    on_exit(fn ->
      case previous_options do
        nil -> Application.delete_env(:aiur, :github_transport_test_options)
        kept -> Application.put_env(:aiur, :github_transport_test_options, kept)
      end

      Application.delete_env(:aiur, :github_budget_ledger_path)

      case previous_endpoint do
        nil -> Application.delete_env(:aiur, Endpoint)
        kept -> Application.put_env(:aiur, Endpoint, kept)
      end
    end)

    {:ok, counter: counter}
  end

  describe "the cache inspector" do
    test "reaches GitHub zero times against a cold store", %{counter: counter} do
      # Cold on purpose. A cold cache is the state in which a page that reads
      # through to GitHub on a miss would actually fetch, so it is the state
      # worth measuring — a warm store could hide the fault behind its own hits.
      #
      # `size/0` answers 0 for "no store running" as well as "running and
      # empty", so the source is asked separately. Otherwise a suite that had
      # somehow lost the store would report this test as proving something about
      # a cold cache when it proved nothing at all.
      assert ResourceStoreSource.available?(), "no store is running, so this is not a cold-store measurement"
      assert ResourceStore.size() == 0

      assert {:ok, _view, html} = live(build_conn(), "/github-cache")

      assert html =~ "github-cache-page",
             "the page did not render, so its zero-fetch result proves nothing"

      assert requests(counter) == [],
             "opening the cache page on a cold store made #{length(requests(counter))} GitHub requests"
    end

    test "reaches GitHub zero times across every layer and control", %{counter: counter} do
      seed()

      assert {:ok, view, _html} = live(build_conn(), "/github-cache")

      # Every layer and every control the page offers, in one sitting.
      assert render_patch(view, "/github-cache/issue_comment") =~ "group-layer"
      render_change(view, "search", %{"q" => "9001"})
      view |> element(~s([data-role="freshness-filter"][phx-value-freshness="fresh"])) |> render_click()
      view |> element(~s([data-role="writer-filter"][phx-value-writer="webhook"])) |> render_click()
      view |> element(~s([data-role="body-filter"][phx-value-body="bodyless"])) |> render_click()
      view |> element(~s([data-role="sort-control"][phx-value-sort="identity"])) |> render_click()
      view |> element(~s([data-role="clear-filters"])) |> render_click()

      assert render_patch(view, "/github-cache/issue_comment/issue_comment:owner:repo:9001") =~ "entry-layer"

      # The bodyless entry seeded through the real `drop_data/1`, so the state
      # this page exists to surface is inside the measured window rather than
      # only asserted about elsewhere.
      bodyless = render_patch(view, "/github-cache/issue_comment/issue_comment:owner:repo:9003")
      assert bodyless =~ "bodyless-warning"
      assert bodyless =~ "304 with no data"

      # A deep link to something the cache does not hold. This is the exact
      # place a "just fetch it on a miss" would be tempting, so it is the exact
      # place the count must stay at zero.
      assert render_patch(view, "/github-cache/issue_comment/issue_comment:owner:repo:404404") =~ "Nothing is cached"

      assert render_patch(view, "/github-cache") =~ "map-layer"

      assert requests(counter) == [],
             "exercising the cache page made #{length(requests(counter))} GitHub requests: #{inspect(requests(counter))}"
    end

    test "reaches GitHub zero times while a write lands under it", %{counter: counter} do
      seed()

      assert {:ok, view, _html} = live(build_conn(), "/github-cache/issue_comment")

      # A writer deposits while somebody is watching. The page re-reads ETS and
      # re-renders; the change event carries no body precisely so that re-read
      # stays free.
      key = ResourceStore.key(:issue_comment, "owner", "repo", 9002)
      :ok = ResourceStore.put_resource(key, %{"body" => "landed"}, source: :webhook, version: "v2")

      assert render(view) =~ "issue_comment:owner:repo:9002"

      assert requests(counter) == [],
             "watching a write land made #{length(requests(counter))} GitHub requests"
    end
  end

  describe "the instrument itself" do
    test "the counter observes a real fetch", %{counter: counter} do
      # The REST half of the ticket-detail read, driven through the same seam.
      # Proving the counter still catches it is what makes the zeros above
      # meaningful rather than vacuous.
      _ignored =
        Issues.fetch_issue_raw(2073,
          repository: {"aiur-team", "aiur"},
          token: "test-token-not-used-the-plug-intercepts"
        )

      assert requests(counter) != [],
             "the counting plug never fired, so every zero in this file is unproven"
    end
  end

  defp seed do
    for id <- [9001, 9002] do
      key = ResourceStore.key(:issue_comment, "owner", "repo", id)
      :ok = ResourceStore.put_resource(key, %{"id" => id}, source: :webhook, version: "v#{id}", etag: "W/\"#{id}\"")
    end

    # One entry deliberately left holding a validator and no body, so the
    # bodyless rendering path is inside the measured window too.
    dropped = ResourceStore.key(:issue_comment, "owner", "repo", 9003)
    :ok = ResourceStore.put_resource(dropped, %{"id" => 9003}, source: :poll, version: "v3", etag: "W/\"9003\"")
    :ok = ResourceStore.drop_data(dropped)

    :ok
  end

  defp requests(counter), do: Agent.get(counter, & &1)

  # `test_helper.exs` sets these globally because dashboard routes fail closed
  # without credentials.
  defp build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header(
      "authorization",
      "Basic " <>
        Base.encode64("#{System.get_env("AIUR_DASHBOARD_USERNAME")}:#{System.get_env("AIUR_DASHBOARD_PASSWORD")}")
    )
  end
end
