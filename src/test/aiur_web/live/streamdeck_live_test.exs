defmodule AiurWeb.StreamdeckLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.{AgentEvents, AgentPubSub, CodingAgent, IssueLog}
  alias AiurWeb.Endpoint

  @endpoint Endpoint

  setup do
    test_pid = self()
    {:ok, snapshot_agent} = Agent.start_link(fn -> fixture_snapshot() end)
    {:ok, meter_agent} = Agent.start_link(fn -> fixture_provider_meters() end)
    previous_endpoint = Application.get_env(:aiur, Endpoint)

    endpoint_config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: true,
        dashboard_auth_required: false,
        streamdeck_transcript_flush_ms: 1,
        streamdeck_snapshot_fun: fn -> Agent.get(snapshot_agent, & &1) end,
        streamdeck_provider_meters_fun: fn -> Agent.get(meter_agent, & &1) end,
        streamdeck_logs_fun: &fixture_logs/1,
        agent_chat_pause_fun: fn identifier ->
          send(test_pid, {:streamdeck_pause, identifier})
          {:ok, 1}
        end,
        agent_chat_resume_fun: fn identifier ->
          send(test_pid, {:streamdeck_resume, identifier})
          {:ok, :resumed}
        end
      )

    Application.put_env(:aiur, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, previous_endpoint)
      if Process.alive?(snapshot_agent), do: Agent.stop(snapshot_agent)
      if Process.alive?(meter_agent), do: Agent.stop(meter_agent)
    end)

    {:ok, snapshot_agent: snapshot_agent, meter_agent: meter_agent}
  end

  test "renders the Stream Deck chassis, eight keys, strip, and knobs" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")
    segment_count = length(CodingAgent.provider_descriptors()) + 2

    assert html =~ "Streamdeck+"
    assert html =~ "Stream Deck + control surface"
    assert html =~ ~s(id="sd-keys")
    assert html =~ ~s(id="sd-screen")
    assert html =~ ~s(style="--sd-screen-segments: #{segment_count}")
    assert html =~ ~s(id="sd-knobs")
    assert length(Regex.scan(~r/data-streamdeck-key=/, html)) == 8
    assert html =~ "SUMMARY"
    assert html =~ "Claude"
    assert html =~ "Codex"
    assert html =~ "MORE AGENTS"
  end

  test "opens and closes the Stream Deck installation modal without rendering credentials" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    assert html =~ ~s(id="streamdeck-install-control")
    assert html =~ ~s(id="streamdeck-download-control")
    assert html =~ "aiur-streamdeck-0.0.0-dev.0098e3ac86a2-linux-x64-c6d1f373b30d8f038538becd746acb43ea2d4364501dc7ced4e65819e9bc76c3.tar.gz"
    refute html =~ ~s(id="streamdeck-install-modal")

    html = render_click(view, "open-streamdeck-install")

    assert html =~ ~s(id="streamdeck-install-modal")
    assert html =~ "Install on your Stream Deck +"
    assert html =~ "Linux with udev"
    assert html =~ "Pair it with your daemon"
    assert html =~ "Download the Stream Deck + package"
    assert html =~ "Create the sidecar directory"
    assert html =~ "--strip-components=1"
    assert html =~ "Create the pairing directory"
    assert html =~ "Create the pairing file"
    assert html =~ "Restrict the pairing file"
    assert html =~ "AIUR_PHOENIX_URL"
    assert html =~ "Install the udev rule"
    assert html =~ "Install the user unit"
    assert html =~ "Reload user systemd"
    assert html =~ "Enable the sidecar"
    assert html =~ "Plug in the deck"
    assert html =~ "What success looks like"
    assert html =~ "0.0.0-dev.0098e3ac86a2"
    assert html =~ "0098e3ac86a2e49e685e8e6ff67248373de43f1d"
    refute html =~ "AIUR_DASHBOARD_PASSWORD="
    refute html =~ "streamdeck-password"
    refute html =~ "browser_fixture_password"

    html = render_click(view, "close-streamdeck-install")
    refute html =~ ~s(id="streamdeck-install-modal")
  end

  test "renders the queued dependency chip and the active status dot footer" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    # Slot 5 is the only queued key and carries dependency: "Blocked".
    assert html =~ "Blocked"
    # Every non-queued, non-empty key renders the status dot + progress footer.
    assert html =~ ~s(class="sd-status-dot")
    assert html =~ ~s(class="sd-progress")
  end

  test "renders the live grid projection instead of preview descriptors" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "Live running"
    assert html =~ "Live paused"
    assert html =~ ~s(data-streamdeck-identifier="1352")
    refute html =~ "Build emulator"
  end

  test "models grid, command, and logs modes with the focused agent" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    assert %{sd_mode: :grid, sd_active: nil} = streamdeck_assigns(view)

    html = render_hook(view, "key-press", %{"identifier" => "1352"})

    assert %{sd_mode: :cmd, sd_active: %{identifier: "1352"} = active} = streamdeck_assigns(view)
    assert html =~ ~s(data-mode="cmd")
    assert html =~ ~s(id="sd-cmd-view")
    refute html =~ ~s(id="sd-keys")
    refute html =~ ~s(id="sd-logs-view")

    html = render_click(view, "command-press", %{"command" => "logs"})

    assert %{sd_mode: :logs, sd_active: ^active} = streamdeck_assigns(view)
    assert html =~ ~s(data-mode="logs")
    assert html =~ ~s(id="sd-logs-view")
    refute html =~ ~s(id="sd-cmd-view")

    html = render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})

    assert %{sd_mode: :cmd, sd_active: ^active} = streamdeck_assigns(view)
    assert html =~ ~s(data-mode="cmd")

    html = render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})

    assert %{sd_mode: :grid, sd_active: nil} = streamdeck_assigns(view)
    assert html =~ ~s(data-mode="grid")
    assert html =~ ~s(id="sd-keys")
  end

  test "renders the focused command strip and its fixed-width BACK hint" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})

    assert html =~ ~s(class="sd-screen sd-screen-cmd")
    assert html =~ ~s(class="sd-strip-cmd")
    assert html =~ "CONTROLLING #1352"
    assert html =~ ~s(class="sd-strip-cmd-agent-icon")
    assert html =~ ~s(src="/provider-assets/codex-color.svg")
    assert html =~ ~s(aria-valuenow="50")
    assert html =~ "background: hsl(62.5, 72%, 50%)"

    assert html =~
             ~r/<span class="sd-dial-hint">\s*<span style="visibility: hidden">‹<\/span>BACK<span style="visibility: hidden">›<\/span>/
  end

  test "renders bounded BACK and EVENTS hint arrows in logs mode" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    html = enter_logs(view)

    assert html =~ ~s(class="sd-screen sd-screen-logs")
    assert html =~ ~s(class="sd-strip-logs")
    assert html =~ ~s(data-log-kind="evhdr")
    assert html =~ ~s(data-log-kind="message")

    assert html =~
             ~r/<span class="sd-dial-hint">\s*<span style="visibility: hidden">‹<\/span>BACK<span style="visibility: visible">›<\/span>/

    assert html =~
             ~r/<span class="sd-dial-hint">\s*<span style="visibility: hidden">‹<\/span>EVENTS<span style="visibility: visible">›<\/span>/

    html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "99"})

    assert html =~
             ~r/<span class="sd-dial-hint">\s*<span style="visibility: visible">‹<\/span>BACK<span style="visibility: hidden">›<\/span>/

    html = render_hook(view, "logs-scroll", %{"axis" => "events", "delta" => "99"})

    assert html =~
             ~r/<span class="sd-dial-hint">\s*<span style="visibility: visible">‹<\/span>EVENTS<span style="visibility: hidden">›<\/span>/
  end

  test "cycle-window enters logs only from command mode" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    render_hook(view, "dial-press", %{"index" => "3", "action" => "cycle-window"})
    assert %{sd_mode: :grid, sd_active: nil} = streamdeck_assigns(view)

    render_hook(view, "key-press", %{"identifier" => "1345"})
    %{sd_active: active} = streamdeck_assigns(view)

    html = render_hook(view, "dial-press", %{"index" => "3", "action" => "cycle-window"})

    assert %{sd_mode: :logs, sd_active: ^active} = streamdeck_assigns(view)
    assert html =~ ~s(data-mode="logs")
  end

  test "retains active mode focus across a fleet refresh", %{snapshot_agent: snapshot_agent} do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    enter_logs(view, "1352")

    Agent.update(snapshot_agent, fn _ ->
      %{running: [], retrying: [], idle: [fixture_agent("1400", "Live replacement", "codex")]}
    end)

    send(view.pid, {:running_changed, []})
    html = render(view)

    assert %{sd_mode: :logs, selected_identifier: "1352", sd_active: %{identifier: "1352"}} =
             streamdeck_assigns(view)

    assert html =~ ~s(data-focused-identifier="1352")

    render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})
    html = render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})

    assert %{sd_mode: :grid, selected_identifier: "1400", sd_active: nil} = streamdeck_assigns(view)
    assert html =~ ~s(data-grid-selected-identifier="1400")
  end

  test "renders grid keys in authoritative column-major order at zero and nonzero offsets" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    assert slot_identifiers(html) |> Enum.take(8) ==
             ["1352", "1350", "1361", "1363", "1345", "1360", "1362", "1366"]

    html = render_hook(view, "grid-page", %{"value" => "50"})

    assert html =~ ~s(data-grid-column-offset="3")

    assert slot_identifiers(html) |> Enum.take(8) ==
             ["1363", "1367", "1371", "1373", "1366", "1370", "1372", "1374"]
  end

  test "preserves raw dial value while deriving offset across fleet shrink and grow", %{snapshot_agent: snapshot_agent} do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "grid-page", %{"value" => "50"})
    assert html =~ ~s(data-grid-dial-value="50")
    assert html =~ ~s(data-grid-column-offset="3")

    Agent.update(snapshot_agent, fn _ -> fleet_snapshot(9) end)
    send(view.pid, {:running_changed, []})
    html = render(view)
    assert html =~ ~s(data-grid-dial-value="50")
    assert html =~ ~s(data-grid-column-offset="1")

    Agent.update(snapshot_agent, fn _ -> fleet_snapshot(25) end)
    send(view.pid, {:running_changed, []})
    html = render(view)
    assert html =~ ~s(data-grid-dial-value="50")
    assert html =~ ~s(data-grid-column-offset="5")
  end

  test "refreshes the grid when the fleet topic changes", %{snapshot_agent: snapshot_agent} do
    {:ok, view, html} = live(build_conn(), "/streamdeck")
    assert html =~ "Live running"

    Agent.update(snapshot_agent, fn _ -> %{running: [], retrying: [], idle: [fixture_agent("1400", "Live replacement", "codex")]} end)
    send(view.pid, {:running_changed, []})

    html = render(view)
    assert html =~ "Live replacement"
    refute html =~ "Live running"
  end

  test "keeps same-rank key order stable when snapshot order changes", %{snapshot_agent: snapshot_agent} do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    snapshot = %{
      running: [fixture_agent("10", "First raw", "codex"), fixture_agent("2", "Second raw", "codex")],
      retrying: [],
      idle: []
    }

    Agent.update(snapshot_agent, fn _ -> snapshot end)
    send(view.pid, {:running_changed, []})
    first_refresh = render(view) |> slot_identifiers()

    Agent.update(snapshot_agent, fn _ -> %{snapshot | running: Enum.reverse(snapshot.running)} end)
    send(view.pid, {:running_changed, []})
    second_refresh = render(view) |> slot_identifiers()

    assert first_refresh == ["2", "10"]
    assert second_refresh == ["2", "10"]
  end

  test "key presses request pause for running and resume for paused agents" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})
    assert html =~ "Pause requested for #1352"
    assert %{sd_mode: :cmd, sd_active: %{identifier: "1352"}} = streamdeck_assigns(view)
    assert_receive {:streamdeck_pause, "1352"}

    render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})
    html = render_hook(view, "key-press", %{"identifier" => "1345"})

    assert html =~ "Resume requested for #1345"
    assert %{sd_mode: :cmd, sd_active: %{identifier: "1345"}} = streamdeck_assigns(view)
    assert_receive {:streamdeck_resume, "1345"}
  end

  test "initial mount creates one real PubSub transcript subscription" do
    {:ok, _view, _html} = live(build_conn(), "/streamdeck")

    identifier =
      Enum.find(
        ~w(1352 1345 1350 1360 1361 1362 1363 1366 1367 1370 1371 1372 1373 1374 1375 1376 1377),
        fn id ->
          match?([{_relay, _metadata}], Registry.lookup(Aiur.PubSub, AgentEvents.agent_topic(id)))
        end
      )

    assert is_binary(identifier)
    topic = AgentEvents.agent_topic(identifier)

    assert [{relay, _metadata}] = Registry.lookup(Aiur.PubSub, topic)
    assert Process.alive?(relay)
  end

  test "key selection follows the focused agent even in read-only mode" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    previous_writable = Endpoint.config(:dashboard_writable)
    Phoenix.Config.put(Endpoint, :dashboard_writable, false)

    try do
      html = render_hook(view, "key-press", %{"identifier" => "1345"})

      assert %{sd_mode: :cmd, sd_active: %{identifier: "1345"}} = streamdeck_assigns(view)
      refute html =~ "Resume requested"
      refute_receive {:streamdeck_resume, "1345"}
    after
      Phoenix.Config.put(Endpoint, :dashboard_writable, previous_writable)
    end
  end

  test "renders LIVE plus log event keys and positions the flattened transcript when one is selected" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    html = enter_logs(view)

    assert html =~ ~s(id="sd-log-keys")
    assert html =~ ~s(data-log-event-index="0")
    assert length(Regex.scan(~r/class="sd-key sd-log-key/, html)) == 8
    assert log_pane(html, "sd-log-transcript") =~ "event-1"
    assert html =~ ~s(data-log-kind="event_header")
    assert html =~ ~s(data-log-kind="message")

    html = render_hook(view, "log-key-select", %{"index" => "2"})
    assert html =~ ~r{id="sd-log-transcript"[^>]*data-offset="2"}
    assert log_pane(html, "sd-log-transcript") =~ "event-2"
    assert html =~ ~r/data-log-event-index="2"[^>]*aria-current="true"/
    assert log_pane(html, "sd-screen") =~ "event-2"

    send(view.pid, {:streamdeck_transcript, "1352", %{}})
    html = render(view)
    assert html =~ ~r{id="sd-log-transcript"[^>]*data-offset="2"}
    assert html =~ ~r/data-log-event-index="2"[^>]*aria-current="true"/

    html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "99"})
    assert html =~ ~r{id="sd-log-transcript"[^>]*data-offset="18"[^>]*data-max-offset="18"}
    assert log_pane(html, "sd-log-transcript") =~ "event-1"
    assert html =~ ~s(id="sd-transcript-hint-down" class="sd-log-hint" aria-hidden="true")
  end

  test "projects classified AgentEventFeed entries through the flattened two-line window" do
    with_production_feed(fn ->
      write_feed("1352", [
        feed_event("assistant", "older message", "turn-1"),
        feed_event("tool", "edit lib/example.ex", "turn-1", %{
          "tool" => "edit",
          "changes" => [%{"path" => "lib/example.ex", "diff" => "--- a/lib/example.ex\n+++ b/lib/example.ex\n-old\n+new"}]
        }),
        feed_event("assistant", "newest message", "turn-2")
      ])

      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      html = enter_logs(view)

      assert html =~ "[AGENT] newest message"
      assert html =~ ~s(class="sd-log-dir" style="color:#9fd0ff">EMIT)
      assert html =~ "lib/example.ex"
      assert html =~ ~r{id="sd-log-transcript"[^>]*data-max-offset="3"}

      html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "99"})
      assert html =~ "older message"
      assert html =~ ~s(id="sd-transcript-hint-down" class="sd-log-hint" aria-hidden="true")
      assert html =~ "sd-log-entry-diff"
      assert html =~ ~s(class="sd-log-diff-line is-addition")
      assert html =~ "+new"
    end)
  end

  test "focus switching rejects old feed topics and resets to the new agent projection" do
    with_production_feed(fn ->
      write_feed("1352", [feed_event("assistant", "old focused entry", "old-turn")])
      write_feed("1345", [feed_event("assistant", "new focused entry", "new-turn")])

      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      html = enter_logs(view)
      assert html =~ "old focused entry"

      html = render_hook(view, "key-press", %{"identifier" => "1345"})
      assert html =~ ~s(data-focused-identifier="1345")
      assert html =~ "new focused entry"
      refute html =~ "old focused entry"

      AgentPubSub.broadcast_transcript("1352", AgentEvents.transcript_event(:assistant, "stale topic"))
      Process.sleep(20)
      html = render(view)
      refute html =~ "stale topic"
      assert html =~ "new focused entry"
    end)
  end

  test "read-only focus swaps relays and ignores the old agent topic" do
    with_production_feed(fn ->
      write_feed("1352", [feed_event("assistant", "old-agent-event", "old-turn")])
      write_feed("1345", [feed_event("assistant", "new-agent-event", "new-turn")])

      endpoint_config = Application.get_env(:aiur, Endpoint)
      read_only_config = Keyword.put(endpoint_config, :dashboard_writable, false)
      Endpoint.config_change(%{Endpoint => read_only_config}, [])

      try do
        {:ok, view, _html} = live(build_conn(), "/streamdeck")
        html = enter_logs(view)
        assert html =~ ~s(data-focused-identifier="1352")
        assert html =~ "old-agent-event"

        html = render_hook(view, "key-press", %{"identifier" => "1345"})
        assert html =~ ~s(data-focused-identifier="1345")
        assert html =~ "new-agent-event"
        refute html =~ "old-agent-event"
        refute_receive {:streamdeck_pause, _identifier}
        refute_receive {:streamdeck_resume, _identifier}

        AgentPubSub.broadcast_transcript("1352", AgentEvents.transcript_event(:assistant, "stale topic"))
        Process.sleep(20)
        html = render(view)
        refute html =~ "stale topic"
        assert html =~ "new-agent-event"
      after
        Endpoint.config_change(%{Endpoint => endpoint_config}, [])
      end
    end)
  end

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

  test "renders an unobserved provider without treating it as zero percent", %{meter_agent: meter_agent} do
    Agent.update(meter_agent, &Map.delete(&1, "claude"))

    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ ~s(data-provider="claude")
    assert html =~ ~s(data-observed="false")
    refute html =~ "Claude 0%"
    refute html =~ ~s(data-provider="claude" data-meter="session" data-percent="0")
  end

  test "marks retained stale readings instead of presenting them as current", %{meter_agent: meter_agent} do
    Agent.update(meter_agent, fn meters ->
      put_in(meters["claude"]["windows"]["weekly"]["freshness"], "stale")
    end)

    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ ~s(data-meter="weekly" data-percent="47" data-observed="true" data-freshness="stale")
    assert html =~ "47% · Thu 6PM · stale"
    assert html =~ "Weekly · 47% · Thu 6PM · stale"
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

  test "renders the priority star, the mic indicator, and the live segment" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    # Slots 1 and 4 carry priority?: true.
    assert html =~ "★"
    # The Claude segment always shows the mic dot.
    assert html =~ ~s(class="sd-mic")
    # The Codex segment is live?: true.
    assert html =~ "is-live"
  end

  test "the nav icon is a 4x2 key grid, matching the physical device" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    [svg] =
      Regex.run(~r{<svg[^>]*>(?:(?!</svg>).)*?x="2" y="4\.5".*?</svg>}s, html) ||
        flunk("the Stream Deck nav icon svg was not rendered")

    assert length(Regex.scan(~r/<circle /, svg)) == 8,
           "the Stream Deck nav icon must show 8 keys in a 4x2 grid, like the device"
  end

  test "mounts even when Aiur.Config raises, exercising the kind/2 rescue" do
    # There is no .aiurconfig in the test environment, so tracker_kind/0 and
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

  defp fixture_snapshot do
    %{
      running: [fixture_agent("1352", "Live running", "codex", priority: 1)],
      retrying: [],
      idle: [
        fixture_agent("1345", "Live paused", "claude", work_state: :paused),
        fixture_agent("1350", "Live queued", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1360", "Extra one", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1361", "Extra two", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1362", "Extra three", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1363", "Extra four", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1366", "Extra five", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1367", "Extra six", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1370", "Extra seven", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1371", "Extra eight", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1372", "Extra nine", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1373", "Extra ten", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1374", "Extra eleven", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1375", "Extra twelve", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1376", "Extra thirteen", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1377", "Extra fourteen", "codex", waiting_reason: :waiting_for_dependency)
      ]
    }
  end

  defp fixture_agent(identifier, title, backend, attrs \\ []) do
    Map.merge(
      %{
        identifier: identifier,
        title: title,
        backend: backend,
        work_state: :working,
        open_decision_count: 0,
        waiting_reason: :active,
        tracker_paused: false,
        progress_percent: 50,
        priority: nil
      },
      Map.new(attrs)
    )
  end

  defp fixture_provider_meters do
    %{
      "claude" => %{
        "state" => "observed",
        "windows" => %{
          "session" => %{"used_percent" => 30, "remaining" => "22m", "freshness" => "fresh"},
          "weekly" => %{"used_percent" => 47, "resets_at" => "2026-08-13T18:00:00Z", "freshness" => "fresh"}
        }
      },
      "codex" => %{
        "state" => "observed",
        "windows" => %{
          "session" => %{"used_percent" => 50, "remaining" => "1h", "freshness" => "fresh"},
          "weekly" => %{"used_percent" => 75, "resets_at" => "2026-08-14T20:00:00Z", "freshness" => "fresh"}
        }
      }
    }
  end

  defp fixture_logs(_identifier), do: Enum.map(1..10, &feed_entry("event-#{&1}", "fixture-#{&1}"))

  defp feed_entry(body, turn_id) do
    %{
      type: "message",
      badge: "AGENT",
      role: "assistant",
      body: body,
      timestamp: "2026-08-02T00:00:00Z",
      turn_id: turn_id
    }
  end

  defp feed_event(role, body, turn_id, payload \\ nil) do
    %{
      "role" => role,
      "body" => body,
      "timestamp" => "2026-08-02T00:00:00Z",
      "msg_id" => nil,
      "sequence" => 1,
      "turn_id" => turn_id,
      "payload" => payload
    }
  end

  defp write_feed(identifier, events) do
    path = IssueLog.transcript_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")
  end

  defp with_production_feed(fun) do
    previous_endpoint_value = Endpoint.config(:streamdeck_logs_fun)
    previous_endpoint_config = Application.get_env(:aiur, Endpoint, [])

    Phoenix.Config.put(Endpoint, :streamdeck_logs_fun, nil)
    Application.put_env(:aiur, Endpoint, Keyword.put(previous_endpoint_config, :streamdeck_logs_fun, nil))

    try do
      fun.()
    after
      Application.put_env(:aiur, Endpoint, previous_endpoint_config)
      Phoenix.Config.put(Endpoint, :streamdeck_logs_fun, previous_endpoint_value)
    end
  end

  defp log_pane(html, id) do
    case Regex.run(~r{<div id="#{id}"[^>]*>.*?</div>}s, html) do
      [pane | _] -> pane
      nil -> flunk("missing log pane ##{id}")
    end
  end

  defp streamdeck_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp enter_logs(view, identifier \\ "1352") do
    render_hook(view, "key-press", %{"identifier" => identifier})
    render_click(view, "command-press", %{"command" => "logs"})
  end

  defp slot_identifiers(html) do
    Regex.scan(~r/data-streamdeck-identifier="([^"]+)"/, html, capture: :all_but_first)
    |> List.flatten()
  end

  defp fleet_snapshot(total) do
    agents = for index <- 1..total, do: fixture_agent("fleet-#{index}", "Fleet #{index}", "codex")
    %{running: [hd(agents)], retrying: [], idle: tl(agents)}
  end
end
