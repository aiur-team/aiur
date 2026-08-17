defmodule AiurWeb.ZeroFetchPageOpenTest do
  @moduledoc """
  A1, asserted by call count and run on every CI build: opening a dashboard page
  against a cold store reaches GitHub **zero** times.

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

  alias Aiur.GitHub.Issues
  alias AiurWeb.ControlCenterCache

  @endpoint AiurWeb.Endpoint

  # Every dashboard route an operator can open directly.
  @pages ["/", "/commands", "/analytics", "/streamdeck"]

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
    test "reaches GitHub zero times on every route", %{counter: counter} do
      Enum.each(@pages, fn path ->
        assert {:ok, view, html} = live(build_conn(), path)

        # A page that failed to render is also a page that made no requests, so
        # the zero below would be meaningless without this. Assert each route
        # actually produced its shell before trusting its call count.
        assert html =~ "dashboard-shell",
               "#{path} did not render the dashboard shell, so its zero-fetch result proves nothing"

        # One extra render round trip, so any work deferred past mount has also
        # happened before the counter is read.
        assert render(view) =~ "dashboard-shell"
      end)

      requests = Agent.get(counter, & &1)

      assert requests == [],
             "opening #{length(@pages)} dashboard pages made #{length(requests)} GitHub requests: #{inspect(requests)}"
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
