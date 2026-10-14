defmodule AiurWeb.StreamdeckLiveStripTest do
  use AiurWeb.StreamdeckLiveCase

  test "pages the complete fleet and clamps the page at both ends" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    assert html =~ ~s(data-grid-page-count="3")
    assert html =~ ~s(data-streamdeck-identifier="1352")
    refute html =~ ~s(data-streamdeck-identifier="1367")

    html = render_hook(view, "grid-page", %{"page" => "1"})
    assert html =~ ~s(data-grid-page="1")
    assert html =~ ~s(data-pager-page="1" aria-current="page")
    assert html =~ ~s(data-streamdeck-identifier="1367")

    html = render_hook(view, "grid-page", %{"page" => "99"})
    assert html =~ ~s(data-grid-page="2")
    assert html =~ ~s(data-streamdeck-identifier="1377")
  end

  test "renders distinct session and weekly provider meters and refreshes them from the live meter event", %{meter_agent: meter_agent} do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "Session"
    assert html =~ "Weekly"
    assert html =~ "30% · 22m"
    assert html =~ "47% · Thu 6PM"
    assert html =~ "50% · 1h"
    assert html =~ "75% · Fri 8PM"

    Agent.update(meter_agent, fn meters ->
      put_in(meters["claude"]["windows"]["session"]["used_percent"], 60)
    end)

    send(view.pid, {:provider_meter_changed, %{}})
    assert render(view) =~ "60% · 22m"
  end

  test "a provider meter change refreshes meters without re-reading the fleet snapshot", %{snapshot_agent: snapshot_agent, meter_agent: meter_agent} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    counting_snapshot_fun = fn ->
      Agent.update(counter, &(&1 + 1))
      Agent.get(snapshot_agent, & &1)
    end

    endpoint_config = Application.get_env(:aiur, Endpoint)
    Endpoint.config_change(%{Endpoint => Keyword.put(endpoint_config, :streamdeck_snapshot_fun, counting_snapshot_fun)}, [])

    try do
      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      reads_before = Agent.get(counter, & &1)
      assert reads_before > 0

      Agent.update(meter_agent, fn meters ->
        put_in(meters["claude"]["windows"]["session"]["used_percent"], 60)
      end)

      send(view.pid, {:provider_meter_changed, %{}})
      html = render(view)

      assert html =~ "60% · 22m"
      # Meter observations must not re-project the fleet: the grid snapshot was
      # read once at mount and not again for the meter refresh.
      assert Agent.get(counter, & &1) == reads_before
    after
      Agent.stop(counter)
      Endpoint.config_change(%{Endpoint => endpoint_config}, [])
    end
  end

  test "renders an unobserved provider without treating it as zero percent", %{meter_agent: meter_agent} do
    Agent.update(meter_agent, &Map.delete(&1, "claude"))

    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ ~s(data-provider="claude")
    assert html =~ ~s(data-observed="false")
    refute html =~ "Claude 0%"
    refute html =~ ~s(data-provider="claude" data-meter="session" data-percent="0")
  end

  test "renders a segment for a configured provider that was never observed at all" do
    # The meter fixture only carries claude and codex, so this configured
    # provider has no reading of any kind. It must still get its own segment,
    # and both of its meters must say so rather than showing an invented value.
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ ~s(data-provider="kimi" data-meter="session" data-observed="false" data-freshness="unknown")
    assert html =~ ~s(data-provider="kimi" data-meter="weekly" data-observed="false" data-freshness="unknown")
    refute html =~ ~s(data-provider="kimi" data-meter="session" data-percent=)
  end

  test "renders retained readings without staleness text", %{meter_agent: meter_agent} do
    Agent.update(meter_agent, fn meters ->
      stale_at = DateTime.add(DateTime.utc_now(), -601, :second)

      meters
      |> put_in(["claude", "observed_at"], stale_at)
      |> put_in(["claude", "windows", "weekly", "observed_at"], stale_at)
    end)

    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ ~s(data-meter="weekly" data-percent="47" data-observed="true" data-freshness="stale")
    refute html =~ "stale ·"
    refute html =~ "10m ago"
  end

  test "renders summary build space and pager dots inside touch-strip segments" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ ~s(src="/aiur-logo.png")
    assert html =~ ~r/<b>1<\/b> live · <b>16<\/b> left/
    assert html =~ "Build"
    assert html =~ "MORE AGENTS"
    assert length(Regex.scan(~r/data-pager-page=/, html)) == 3
    assert html =~ ~s(data-pager-page="0" aria-current="page")
  end

  test "the pager renders as the design's dial segment rather than a logo-headed info segment" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    assert has_element?(view, ~s([data-segment="pager"].sd-seg-d .sd-seg-dlabel), "MORE AGENTS")
    refute has_element?(view, ~s([data-segment="pager"].sd-seg-info))
    refute has_element?(view, ~s([data-segment="pager"] .sd-info-hd))
    refute has_element?(view, ~s([data-segment="pager"] .sd-hd-logo))

    # The information segments keep their logo headers.
    assert has_element?(view, ~s([data-segment="summary"].sd-seg-info .sd-info-hd .sd-hd-logo))
    assert has_element?(view, ~s([data-segment="provider"].sd-seg-info .sd-info-hd .sd-hd-logo))

    # Focusing a command hands the strip to the cmd page. The information
    # segments step aside for it, but the dial-D pager segment stays and takes
    # the focused agent as its label (#1607), so the operator can read which
    # agent they are controlling from either surface.
    render_hook(view, "key-press", %{"identifier" => "1352"})

    refute has_element?(view, ~s([data-segment="summary"]))
    refute has_element?(view, ~s([data-segment="provider"]))
    assert has_element?(view, ~s([data-segment="pager"] .sd-pager-label), "#1352")
    assert has_element?(view, ".sd-strip-cmd-pager", "CONTROLLING #1352")
  end

  test "the CONTROLLING relabel replaces MORE AGENTS while a command is focused" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "MORE AGENTS"
    refute html =~ "CONTROLLING"

    html = render_hook(view, "key-press", %{"identifier" => "1352"})

    assert html =~ "CONTROLLING #1352"
    refute html =~ "MORE AGENTS"
    refute html =~ "data-pager-page="

    # Descending into logs swaps the strip to this ticket's three-shape
    # transcript window, but #1662/#1707 keep the pager segment so dial D stays
    # labelled with the agent being read. Both hold at once.
    html = render_click(view, "command-press", %{"command" => "logs"})
    assert html =~ ~s(class="sd-strip-logs")
    refute html =~ "MORE AGENTS"
    assert html =~ ~s(data-pager-focus="#1352")
    assert html =~ ~s(data-segment="pager")

    # Backing out of logs restores the cmd page and its CONTROLLING relabel.
    html = render_click(view, "dial-press", %{"action" => "back"})
    assert html =~ "CONTROLLING"

    # Backing all the way out restores the segment row and its pager dots.
    html = render_click(view, "dial-press", %{"action" => "back"})

    assert html =~ "MORE AGENTS"
    refute html =~ "CONTROLLING"
    assert html =~ ~s(data-pager-page="0" aria-current="page")
  end

  test "the CONTROLLING label follows a focus change without leaving the previous agent behind" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    render_hook(view, "key-press", %{"identifier" => "1352"})
    html = render_hook(view, "key-press", %{"identifier" => "1345"})

    assert html =~ "CONTROLLING #1345"
    refute html =~ "CONTROLLING #1352"
  end

  test "renders the priority icon, the mic indicator, and the live segment" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    # Slots 1 and 4 carry priority?: true.
    assert html =~ ~s(class="sd-ag-prio")
    # The Claude segment always shows the mic dot.
    assert html =~ ~s(class="sd-mic")
    # The Codex segment is live?: true.
    assert html =~ "is-live"
  end

  # The design's six-key glyph (a bezel around two rows of three keys) is what
  # tells this icon apart from the Units four-square at nav size.
  test "the nav icon is the design's six-key deck inside a bezel" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    [svg] =
      Regex.run(~r{<svg[^>]*>(?:(?!</svg>).)*?x="2" y="4" width="20" height="16".*?</svg>}s, html) ||
        flunk("the Stream Deck nav icon svg was not rendered")

    assert length(Regex.scan(~r/<rect /, svg)) == 1, "the Stream Deck nav icon must keep one bezel"
    assert length(Regex.scan(~r/<circle /, svg)) == 6, "the Stream Deck nav icon must show six keys"
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
    assert render_hook(view, "restore-nav", %{"collapsed" => false}) =~ ~s(data-nav-collapsed="false")
  end

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "carries the awaiting-Commands banner into Stream Deck" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "2 units awaiting commands"
    assert html =~ ~s(href="/commands")
  end

  @tag awaiting_commands: %{total: 4, open: 0, blocking: 0, deferred: 0, awaiting: 0, awaiting_blocking: 0}
  test "omits the awaiting-Commands banner from Stream Deck when nothing is waiting" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    refute html =~ "units awaiting commands"
  end

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "survives every message the Command topic carries" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")
    assert html =~ "2 units awaiting commands"

    # Stream Deck is a control surface the operator runs the fleet from. An
    # unrelated Command action anywhere must not take it down.
    assert AwaitingCommands.render_after_command_topic(view) =~ "2 units awaiting commands"
  end
end
