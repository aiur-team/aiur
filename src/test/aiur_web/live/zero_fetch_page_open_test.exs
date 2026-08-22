defmodule AiurWeb.ZeroFetchPageOpenTest do
  @moduledoc """
  A1, asserted by call count and run on every CI build: opening a dashboard page
  against a cold store reaches GitHub **zero** times.

  One deliberate exception: opening the Build Order page registers the first
  demander on the Ad Hoc overlay source, which buys a single view-originated
  refresh (held state renders first, then one listing). That one request is
  asserted explicitly below; every other route stays at zero.

  ## Why this file is hermetic and the `:external` one is not

  There is a companion measurement that reads real `x-ratelimit-used` deltas from
  GitHub. It is the operator-facing corroboration, but it is tagged `:external`,
  so it does **not run in CI** — which makes it useless as a regression guard. A
  guard that never executes protects nothing.

  This file therefore installs a counting plug at Aiur's own transport boundary
  and needs no token, no network, and no tags. Every HTTP request Aiur would send
  to GitHub — REST or GraphQL, from any module, on any code path — is counted
  instead of sent, because `Aiur.GitHub.Transport` funnels both through
  `request_options/2` (`transport.ex:453`) and `Transport.github_graphql/*` shares
  that path.

  Zero requests is zero rate limit by construction: no window, no shard, no
  propagation delay to argue about.

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

  alias Aiur.BuildOrder.TicketDetail
  alias Aiur.GitHub.{Issues, ResourceStore}
  alias Aiur.TrackerIdentity
  alias AiurWeb.ControlCenterCache

  @endpoint AiurWeb.Endpoint

  # The dashboard routes that must never fetch when opened, paired with a marker
  # only that route renders. Each of these reads local GenServer state and could
  # never have fetched. `/build-orders` and `/build-orders/:root_number` are
  # deliberately NOT here: opening them now performs one view-originated refresh
  # of the Ad Hoc overlay (see "the Build Order page" describe below), so their
  # open does not cost zero and they assert the exact shape of that one request
  # instead.
  @zero_fetch_pages [
    {"/", "usage-watch"},
    {"/commands", "control-panel"},
    {"/analytics", "analytics-page"},
    {"/streamdeck", "streamdeck-page"}
  ]

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @repository {"owner", "repo"}

  setup do
    previous_endpoint = Application.get_env(:aiur, AiurWeb.Endpoint)
    cache = start_supervised!({ControlCenterCache, name: nil})

    config =
      :aiur
      |> Application.get_env(AiurWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false,
        control_center_cache: cache
      )

    Application.put_env(:aiur, AiurWeb.Endpoint, config)

    on_exit(fn ->
      case previous_endpoint do
        nil -> Application.delete_env(:aiur, AiurWeb.Endpoint)
        kept -> Application.put_env(:aiur, AiurWeb.Endpoint, kept)
      end
    end)

    start_supervised!({AiurWeb.Endpoint, []})

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

    on_exit(fn ->
      case previous_options do
        nil -> Application.delete_env(:aiur, :github_transport_test_options)
        kept -> Application.put_env(:aiur, :github_transport_test_options, kept)
      end
    end)

    {:ok, counter: counter}
  end

  describe "opening a dashboard page" do
    setup do
      # The Build Order page's one view-originated refresh must be deterministic,
      # so the transport has to be open for it: `require_token/0` answers from
      # GITHUB_TOKEN, which CI does not set. Without this, "opening /build-orders
      # makes one request" would silently become "zero" on a tokenless runner and
      # the assertion would mean nothing.
      previous_token = System.get_env("GITHUB_TOKEN")
      previous_cached = :persistent_term.get(@token_cache_key, :unset)
      :persistent_term.erase(@token_cache_key)
      System.put_env("GITHUB_TOKEN", "test-gh-token")

      on_exit(fn ->
        case previous_token do
          nil -> System.delete_env("GITHUB_TOKEN")
          value -> System.put_env("GITHUB_TOKEN", value)
        end

        case previous_cached do
          :unset -> :persistent_term.erase(@token_cache_key)
          token -> :persistent_term.put(@token_cache_key, token)
        end
      end)

      :ok
    end

    test "reaches GitHub zero times on every route", %{counter: counter} do
      Enum.each(@zero_fetch_pages, fn {path, marker} ->
        assert {:ok, view, html} = live(build_conn(), path)

        # A page that failed to render is also a page that made no requests, so
        # the zero below would be meaningless without this. The marker is
        # route-specific rather than the shared shell, so a route that silently
        # fell back to another page cannot borrow its zero.
        assert html =~ "dashboard-shell",
               "#{path} did not render the dashboard shell, so its zero-fetch result proves nothing"

        assert html =~ marker,
               "#{path} rendered a shell but not its own content (#{marker}), so its zero proves nothing"

        # One extra render round trip, so any work deferred past mount has also
        # happened before the counter is read.
        assert render(view) =~ marker
      end)

      requests = Agent.get(counter, & &1)

      assert requests == [],
             "opening #{length(@zero_fetch_pages)} dashboard pages made #{length(requests)} GitHub requests: #{inspect(requests)}"

      # The zero above and a zero caused by an exhausted budget look identical:
      # `Transport` short-circuits a quota hold before the plug is ever reached.
      # Driving one real request now proves the egress path was open for the
      # whole of this test, so the zero means "did not fetch" and not "could
      # not".
      assert_egress_open!(counter)
    end

    # The one deliberate exception to "viewing never fetches": opening the Build
    # Order page registers the first demander on the Ad Hoc source, which buys a
    # single view-originated refresh of the labelled overlay. Held state renders
    # first; the listing is the one request this page is allowed. A second Build
    # Order page coalesces on the in-flight guard, so the total stays one.
    test "opening /build-orders performs exactly one view-originated refresh", %{counter: counter} do
      for path <- ["/build-orders", "/build-orders/2073"] do
        assert {:ok, view, html} = live(build_conn(), path)
        assert html =~ "dashboard-shell", "#{path} did not render the dashboard shell"
        assert html =~ "build-order-page", "#{path} rendered a shell but not its own page"
        assert render(view) =~ "build-order-page"
      end

      # The refresh is async — a cast from the LiveView to the Ad Hoc source,
      # then a Task — so the listing can land after the render round trip above.
      # Poll until it does, so the assertion is about the request's shape, not
      # about winning a race.
      assert eventually(fn -> Agent.get(counter, & &1) != [] end),
             "opening /build-orders never performed its view-originated refresh"

      requests = Agent.get(counter, & &1)

      assert [{method, path}] = requests,
             "opening the Build Order pages made #{length(requests)} GitHub requests: #{inspect(requests)}"

      assert method == "GET"
      assert path == "/repos/aiur-team/aiur/issues"

      # A view-originated refresh that quietly stopped firing would show up as
      # this request disappearing, so a positive control belongs here too.
      assert_egress_open!(counter)
    end

    test "holding a page open past its refresh ticks reaches GitHub zero times", %{counter: counter} do
      assert {:ok, view, html} = live(build_conn(), "/")
      assert html =~ "dashboard-shell"

      # The dashboard's own periodic ticks: a 1s clock, a 15s GitHub-quota read
      # and a 60s ElevenLabs read. Driving them directly is deterministic where
      # sleeping for 60s would be slow and still racy. If any of them ever
      # starts fetching rather than reading local GenServer state, this fails.
      Enum.each([:runtime_tick, :github_quota_tick, :elevenlabs_quota_tick], fn tick ->
        send(view.pid, tick)
        _rendered = render(view)
      end)

      requests = Agent.get(counter, & &1)

      assert requests == [],
             "holding the dashboard open made #{length(requests)} GitHub requests: #{inspect(requests)}"

      assert_egress_open!(counter)
    end
  end

  # The four original routes read local GenServer state and could never have
  # fetched, so every assertion above evaluated identically before this change.
  # `/build-orders` is the route whose data path moved, and the read it moved is
  # the ticket-detail issue read: it now answers from the shared store instead of
  # asking GitHub. Opening the route does not itself request a ticket context
  # (that needs a click), so the read is driven here directly through the same
  # `Aiur.BuildOrder.TicketDetail` entry point the page uses.
  #
  # Smallest mutation this catches: `ticket_detail_repository.ex` calling
  # `Issues.fetch_issue_raw/2` instead of `Issues.fetch_issue_raw_conditional/2`.
  # Every ticket open then pays full price, and nothing else in this file moves.
  describe "the Build Order ticket-detail read" do
    setup do
      previous_token = System.get_env("GITHUB_TOKEN")
      previous_cached = :persistent_term.get(@token_cache_key, :unset)
      :persistent_term.erase(@token_cache_key)
      System.put_env("GITHUB_TOKEN", "test-gh-token")

      on_exit(fn ->
        case previous_token do
          nil -> System.delete_env("GITHUB_TOKEN")
          value -> System.put_env("GITHUB_TOKEN", value)
        end

        case previous_cached do
          :unset -> :persistent_term.erase(@token_cache_key)
          token -> :persistent_term.put(@token_cache_key, token)
        end

        ResourceStore.reset()
      end)

      :ok
    end

    test "an issue already held costs no request at all", %{counter: counter} do
      {owner, repo} = @repository
      ResourceStore.put_resource(ResourceStore.key(:issue, owner, repo, "2073"), held_issue(2073), source: :webhook, version: "2026-08-17T10:00:00Z")

      assert {:ok, detail} =
               TicketDetail.fetch(identity(2073),
                 configured_repo: @repository,
                 freshness_ms: 30_000,
                 relationship_reader: fn _identity, _repository -> {:ok, %{nodes: [], truncated?: false}} end
               )

      assert detail.identity.identifier == "2073"

      # Filtered to REST reads on purpose: the linked-pull-request half of a
      # ticket detail is a GraphQL POST with no store behind it, and it is
      # stubbed above. What this asserts is that the issue body itself — the read
      # this change rewrote — cost nothing.
      rest = counter |> Agent.get(& &1) |> Enum.filter(fn {method, _path} -> method == "GET" end)

      assert rest == [],
             "a held issue body still cost #{length(rest)} REST request(s): #{inspect(rest)}"

      assert_egress_open!(counter)
    end
  end

  describe "the instrument itself" do
    test "the counter observes a real fetch", %{counter: counter} do
      # The REST half of the ticket-detail read. Proving the counter still catches
      # it is also what makes the zeros above meaningful rather than vacuous.
      _ignored =
        Issues.fetch_issue_raw(2073,
          repository: {"aiur-team", "aiur"},
          token: "test-token-not-used-the-plug-intercepts"
        )

      observed = Agent.get(counter, & &1)

      assert observed != [], "the counting plug never fired, so every zero in this file is unproven"
    end
  end

  # A zero from a page that did not fetch and a zero from a transport that
  # refused to send are the same zero. `Aiur.GitHub.Transport` answers a quota
  # hold with a synthesized response and never reaches the plug, so an exhausted
  # budget would make every assertion in this file pass for the wrong reason.
  # Driving one real request through the same seam is the only way to tell them
  # apart, and it must be done inside the test whose zero it underwrites.
  defp assert_egress_open!(counter) do
    before = length(Agent.get(counter, & &1))

    _ignored =
      Issues.fetch_issue_raw(4242,
        repository: @repository,
        token: "test-token-not-used-the-plug-intercepts"
      )

    assert length(Agent.get(counter, & &1)) > before,
           "the transport sent nothing for a request that must always send, so the zero above " <>
             "may be an exhausted budget rather than a page that did not fetch"
  end

  defp identity(number) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => "I#{number}", "number" => number},
        @repository,
        @repository
      )

    identity
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  defp held_issue(number) do
    %{
      "number" => number,
      "node_id" => "I#{number}",
      "title" => "Ticket #{number}",
      "body" => "description",
      "html_url" => "https://github.com/owner/repo/issues/#{number}",
      "repository_url" => "https://api.github.com/repos/owner/repo",
      "state" => "open",
      "state_reason" => nil,
      "labels" => [],
      "assignee" => nil,
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-08-17T10:00:00Z"
    }
  end

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
