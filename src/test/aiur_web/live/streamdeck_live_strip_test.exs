defmodule AiurWeb.StreamdeckLiveStripTest do
  alias Aiur.TestSupport.BuildHome.UsageInputs
  use AiurWeb.StreamdeckLiveCase

  setup do
    previous = Application.get_env(:aiur, :build_conversation_source)
    Application.put_env(:aiur, :build_conversation_source, :unavailable)
    on_exit(fn -> if previous, do: Application.put_env(:aiur, :build_conversation_source, previous), else: Application.delete_env(:aiur, :build_conversation_source) end)
  end

  alias Aiur.TestSupport.EndpointStubs

  setup %{meter_agent: meter_agent} do
    EndpointStubs.put(
      streamdeck_usage_load_fun: fn _, _ ->
        meters =
          Map.new(Agent.get(meter_agent, & &1), fn {family, meter} ->
            windows =
              Map.new(meter["windows"], fn {slot, window} ->
                {slot,
                 %{
                   kind: :rate_limit,
                   used_percent: window["used_percent"],
                   duration_minutes: if(slot == "session", do: 300, else: 10_080),
                   resets_at: DateTime.add(DateTime.utc_now(), 3600)
                 }}
              end)

            snapshot =
              UsageInputs.snapshot(String.to_existing_atom(family), windows, %{
                observed_at: meter["observed_at"] || DateTime.utc_now(),
                health: %{
                  state: if(meter["observed_at"], do: :stale, else: :healthy),
                  failure: nil
                }
              })

            {String.to_existing_atom(family), snapshot}
          end)

        UsageInputs.inputs(%{families: Aiur.CodingAgent.provider_families(), meters: meters})
      end
    )

    :ok
  end

  test "pages the complete fleet and clamps the page at both ends" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    assert html =~ ~s(data-grid-page-count="3")
    assert html =~ ~s(data-streamdeck-identifier="1352")
    refute html =~ ~s(data-streamdeck-identifier="1367")

    html = render_hook(view, "grid-page", %{"page" => "1"})
    assert html =~ ~s(data-grid-page="1")
    assert strip(html) =~ "2 / 3"
    assert html =~ ~s(data-streamdeck-identifier="1367")

    html = render_hook(view, "grid-page", %{"page" => "99"})
    assert html =~ ~s(data-grid-page="2")
    assert html =~ ~s(data-streamdeck-identifier="1377")
  end

  test "refreshes shared usage without putting provider meters into the count strip", %{
    meter_agent: meter_agent
  } do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    initial_strip = strip(html)
    assert initial_strip =~ "Queued"
    refute initial_strip =~ "70% left"
    refute initial_strip =~ "50% left"

    Agent.update(meter_agent, fn meters ->
      put_in(meters["claude"]["windows"]["session"]["used_percent"], 60)
    end)

    send(view.pid, {:provider_meter_changed, %{}})
    assert strip(render(view)) == initial_strip
    assert :sys.get_state(view.pid).socket.assigns.usage["claude"]["windows"]["session"]["used_percent"] == 60
  end

  test "a provider meter change refreshes meters without re-reading the shared Build window", %{
    snapshot_agent: snapshot_agent,
    meter_agent: meter_agent
  } do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    counting_window_fun = fn _, _, _ ->
      Agent.update(counter, &(&1 + 1))
      snapshot_agent |> Agent.get(& &1) |> Aiur.TestSupport.StreamdeckBuildFixture.window()
    end

    EndpointStubs.put(streamdeck_build_window_fun: counting_window_fun)

    try do
      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      reads_before = Agent.get(counter, & &1)
      assert reads_before > 0

      Agent.update(meter_agent, fn meters ->
        put_in(meters["claude"]["windows"]["session"]["used_percent"], 60)
      end)

      send(view.pid, {:provider_meter_changed, %{}})
      html = render(view)

      assert :sys.get_state(view.pid).socket.assigns.usage["claude"]["windows"]["session"]["used_percent"] == 60
      refute strip(html) =~ "40% left"
      # A usage-only refresh must leave the shared ticket population retained.
      assert Agent.get(counter, & &1) == reads_before
    after
      Agent.stop(counter)
    end
  end

  test "unobserved providers do not replace category bands", %{meter_agent: meter_agent} do
    Agent.update(meter_agent, &Map.delete(&1, "claude"))
    {:ok, view, html} = live(build_conn(), "/streamdeck")
    refute has_element?(view, "#sd-screen [data-provider]")
    assert strip(html) =~ "Queued"
    assert has_element?(view, "[data-streamdeck-region='200'] [data-state]")
  end

  test "renders unavailable summary and no ticket pages when the Build window is unavailable" do
    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:error, :offline} end)
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    assert strip(html) =~ "AIUR"
    assert strip(html) =~ "Counts unavailable"
    assert strip(html) =~ "Queued unknown"
    assert strip(html) =~ "Build"
    refute strip(html) =~ "Queued 0"
    refute html =~ ~s(data-grid-total="0")
    assert html =~ ~s(data-tickets-status="unavailable")
    assert has_element?(view, "#sd-keys button[disabled][aria-label*='Tickets unavailable']")
  end

  test "the backlog and pager band yields to full-width chat when focused" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    assert has_element?(view, "[data-streamdeck-region='600']", "Queued")
    assert has_element?(view, "[data-streamdeck-region='0']", "AIUR")
    render_hook(view, "key-press", %{"identifier" => "1352"})
    assert has_element?(view, "[data-streamdeck-region='0']", "Conversation unavailable")
    refute has_element?(view, "[data-streamdeck-region='600']")
    assert streamdeck_assigns(view).deck_chat.ref.id == "1352"
    assert length(Floki.find(Floki.parse_fragment!(render(view)), "#sd-screen svg")) == 1
  end

  test "full-width chat replaces the backlog band while a ticket is focused" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "Queued"
    refute html =~ "CONTROLLING"

    html = render_hook(view, "key-press", %{"identifier" => "1352"})

    assert html =~ "Conversation unavailable"
    assert streamdeck_assigns(view).deck_chat.ref.id == "1352"
    refute html =~ "MORE AGENTS"
    refute html =~ "data-pager-page="

    # Backing all the way out restores the segment row and its pager dots.
    html = render_click(view, "dial-press", %{"action" => "back"})

    assert html =~ "Queued"
    refute html =~ "CONTROLLING"
    assert strip(html) =~ "1 / 3"
  end

  test "the shared conversation follows a focus change" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    render_hook(view, "key-press", %{"identifier" => "1352"})
    html = render_hook(view, "key-press", %{"identifier" => "1345"})

    assert html =~ "Conversation unavailable"
    assert streamdeck_assigns(view).deck_chat.ref.id == "1345"
  end

  test "renders priority and shared strip images" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "★"
    assert Floki.find(Floki.parse_fragment!(html), "#sd-screen svg") != []
  end

  # The design's six-key glyph (a bezel around two rows of three keys) is what
  # tells this icon apart from the Units four-square at nav size.
  test "the nav icon is the design's six-key deck inside a bezel" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    [svg] =
      Regex.run(~r{<svg[^>]*>(?:(?!</svg>).)*?x="2" y="4" width="20" height="16".*?</svg>}s, html) ||
        flunk("the Stream Deck nav icon svg was not rendered")

    assert length(Regex.scan(~r/<rect /, svg)) == 1,
           "the Stream Deck nav icon must keep one bezel"

    assert length(Regex.scan(~r/<circle /, svg)) == 6,
           "the Stream Deck nav icon must show six keys"
  end

  test "mounts even when Aiur.Config raises, exercising the kind/2 rescue" do
    # There is no config.yaml in the test environment, so tracker_kind/0 and
    # agent_kind/0 both raise. The rescue clause in kind/2 swallows that and
    # returns the fallback string; without it, mount/3 would raise and live/2
    # would hand back an error tuple instead of {:ok, view, html}.
    assert {:ok, _view, _html} = live(build_conn(), "/streamdeck")
  end

  test "toggle-nav collapses the sidebar and restore-nav restores it" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    assert render_click(view, "toggle-nav", %{}) =~ ~s(data-nav-collapsed="true")

    assert render_hook(view, "restore-nav", %{"collapsed" => false}) =~
             ~s(data-nav-collapsed="false")
  end

  @tag awaiting_commands: %{
         total: 3,
         open: 2,
         blocking: 1,
         deferred: 0,
         needs_you: 2,
         needs_you_blocking: 1
       }
  test "carries the awaiting-Commands banner into Stream Deck" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "2 Commands need you"
    assert html =~ ~s(href="/commands?route=needs_you")
  end

  @tag awaiting_commands: %{
         total: 4,
         open: 0,
         blocking: 0,
         deferred: 0,
         needs_you: 0,
         needs_you_blocking: 0
       }
  test "omits the awaiting-Commands banner from Stream Deck when nothing is waiting" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    refute html =~ "Commands need you"
  end

  @tag awaiting_commands: %{
         total: 3,
         open: 2,
         blocking: 1,
         deferred: 0,
         needs_you: 2,
         needs_you_blocking: 1
       }
  test "survives every message the Command topic carries" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")
    assert html =~ "2 Commands need you"

    # Stream Deck is a control surface the operator runs the fleet from. An
    # unrelated Command action anywhere must not take it down.
    assert AwaitingCommands.render_after_command_topic(view) =~ "2 Commands need you"
  end
end
