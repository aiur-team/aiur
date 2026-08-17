defmodule AiurWeb.ZeroFetchMeasurementTest do
  @moduledoc """
  A1, measured rather than argued: opening every dashboard page against a cold
  store consumes **zero** primary rate limit.

  `:external` — needs a real `GITHUB_TOKEN` and talks to `api.github.com`, so it
  is excluded from the default run and from CI. Run it explicitly:

      mix test test/aiur_web/live/zero_fetch_measurement_test.exs --only external

  ## Two instruments, because one of them can lie

  **The counter** is exact. A counting plug is installed at
  `Aiur.GitHub.Transport`'s own request options, so every HTTP request Aiur
  would make to GitHub — REST or GraphQL, from any module, on any path — is
  counted instead of sent. Zero requests is zero rate limit by construction,
  with no window, shard, or propagation delay to argue about. A positive
  control asserts the counter actually fires, because a zero from a broken
  instrument is worse than no measurement at all.

  **The live meter** is the operator-facing corroboration: real consumption
  read from GitHub itself, straddling a real page open.

  ### Why the live meter does not use `GET /rate_limit`

  It should, and the acceptance criterion asks for it. On this token it does not
  work: `/rate_limit` reports `core.used = 1` and holds that value in both its
  body and its own `x-ratelimit-*` headers while real requests on the same token
  demonstrably increment `x-ratelimit-used` past it — measured here going 12,
  13, 14 across three consecutive reads inside one stable window. The two are
  being served different counters.

  So the live meter reads `x-ratelimit-used` from the headers of a real request
  instead, which is exact and monotonic.

  Each probe's own cost is known and subtracted:

    * The REST probe is an ordinary repository read and costs **1**, so the
      expected delta across `probe → open pages → probe` is 1 — the closing
      probe itself.
    * The GraphQL probe costs **0**. A query selecting only `rateLimit` is not
      charged; measured here, two consecutive probes both reported `used: 57`
      while a query that also touched `repository` moved it to 58. So the
      expected GraphQL delta is 0.

  Anything above those is what the pages spent.

  ## What this harness cannot show, stated rather than glossed

  It cannot produce a live "before" number. Reverting the view-path changes and
  re-running this file still measures zero, because the fetches U3 removed —
  `GraphProjection.demand/2` and `TicketDetailCache.request/2` — are gated
  behind an authorised root and a configured tracker that a test application
  never reaches. The gate fails first, so no request is attempted either way.

  The before/after is therefore asserted where it is observable: as call counts
  against a stubbed source, in `build_order_live_test.exs` (`demand` is never
  called on the selected route), `analytics_live_test.exs` (the stub defines no
  `demand/2` at all) and `data_source_test.exs` (the spy defines no
  `request/1`). Those are exact and environment-independent. This file's job is
  the complementary one: proving that the whole assembled page, in a real
  supervision tree, reaches GitHub zero times.
  """

  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.GitHub.{Issues, ResourceStore}
  alias AiurWeb.ControlCenterCache

  @endpoint AiurWeb.Endpoint

  @moduletag :external
  @moduletag timeout: 300_000

  # Every dashboard route, plus the two parameterised routes that used to fetch:
  # the selected Build Order graph and the Build-Order-scoped Analytics view.
  # Both resolved their scope by asking the projection to fetch, and both are
  # the reason a page open used to cost GraphQL points.
  @pages [
    "/",
    "/commands",
    "/build-orders",
    "/build-orders/2073",
    "/analytics",
    "/analytics?build_order=2073",
    "/streamdeck"
  ]

  setup do
    token = System.get_env("GITHUB_TOKEN")
    if token in [nil, ""], do: raise("GITHUB_TOKEN must be set to measure real consumption")

    if Process.whereis(ResourceStore) == nil do
      Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    end

    # A cold store is the hard case: nothing can serve a reader, and the
    # pre-change code fetched to fill it.
    ResourceStore.reset()

    previous = Application.get_env(:aiur, AiurWeb.Endpoint)
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
    on_exit(fn -> Application.put_env(:aiur, AiurWeb.Endpoint, previous) end)
    start_supervised!({AiurWeb.Endpoint, []})

    {:ok, token: token}
  end

  describe "the exact counter at Aiur's own transport boundary" do
    setup do
      {:ok, counter} = Agent.start_link(fn -> [] end)
      previous = Application.get_env(:aiur, :github_transport_test_options)

      Application.put_env(:aiur, :github_transport_test_options,
        plug: fn conn ->
          Agent.update(counter, &[{conn.method, conn.request_path} | &1])

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, "{}")
        end
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:aiur, :github_transport_test_options, previous)
        else
          Application.delete_env(:aiur, :github_transport_test_options)
        end
      end)

      {:ok, counter: counter}
    end

    test "opening every dashboard page makes zero GitHub requests", %{counter: counter} do
      Enum.each(@pages, fn path ->
        assert {:ok, view, _html} = live(build_conn(), path)
        # One render round trip, so any assign work deferred past mount has also
        # happened before the counter is read.
        _rendered = render(view)
      end)

      requests = Agent.get(counter, & &1)

      assert requests == [],
             "opening the dashboard made #{length(requests)} GitHub requests: #{inspect(requests)}"
    end

    # Without this, the zero above is indistinguishable from a counter that was
    # never wired up. `fetch_issue_raw/2` is the REST half of the ticket-detail
    # read the dashboard used to reach on every inspected unit, so proving the
    # counter still catches it is also proof the page no longer calls it.
    test "the counter fires for a real application fetch", %{counter: counter, token: token} do
      _ignored =
        Issues.fetch_issue_raw(2073,
          repository: {"aiur-team", "aiur"},
          token: token
        )

      assert Agent.get(counter, &length(&1)) > 0
    end
  end

  describe "the live meter against GitHub" do
    test "a real page open moves the counter only by the closing probe", %{token: token} do
      core_before = core_used(token)
      graphql_before = graphql_used(token)

      Enum.each(@pages, fn path ->
        assert {:ok, view, _html} = live(build_conn(), path)
        _rendered = render(view)
      end)

      core_after = core_used(token)
      graphql_after = graphql_used(token)

      core_spent = core_after - core_before - 1
      graphql_spent = graphql_after - graphql_before

      IO.puts("""

      real GitHub consumption across one open of every dashboard page
        core    x-ratelimit-used  #{core_before} -> #{core_after}   (probe 1, pages #{core_spent})
        graphql rateLimit.used    #{graphql_before} -> #{graphql_after}   (probe 0, pages #{graphql_spent})
      """)

      assert core_spent == 0, "opening the dashboard spent #{core_spent} core REST calls"
      assert graphql_spent == 0, "opening the dashboard spent #{graphql_spent} GraphQL points"
    end
  end

  # `test_helper.exs` sets these globally, because dashboard routes fail closed
  # without credentials.
  defp build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header(
      "authorization",
      "Basic " <>
        Base.encode64("#{System.get_env("AIUR_DASHBOARD_USERNAME")}:#{System.get_env("AIUR_DASHBOARD_PASSWORD")}")
    )
  end

  # Costs exactly one core unit and reports the resulting total, so a pair of
  # probes brackets a window with a known, constant overhead of one.
  defp core_used(token) do
    response =
      Req.get!("https://api.github.com/repos/aiur-team/aiur",
        headers: [{"authorization", "Bearer #{token}"}, {"accept", "application/vnd.github+json"}],
        retry: false
      )

    response
    |> header("x-ratelimit-used")
    |> String.to_integer()
  end

  # `rateLimit` is the GraphQL API's own accounting field and the query costs
  # one point, mirroring the REST probe exactly.
  defp graphql_used(token) do
    %{status: 200, body: body} =
      Req.post!("https://api.github.com/graphql",
        headers: [{"authorization", "Bearer #{token}"}],
        json: %{query: "query { rateLimit { used } }"},
        retry: false
      )

    get_in(body, ["data", "rateLimit", "used"])
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _rest] -> value
      [] -> raise "GitHub did not return #{name}; the live meter cannot measure"
    end
  end
end
