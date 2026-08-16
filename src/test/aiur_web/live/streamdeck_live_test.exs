defmodule AiurWeb.StreamdeckLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.{AgentEvents, AgentPubSub, CodingAgent, IssueLog}
  alias Aiur.TestSupport.AwaitingCommands
  alias AiurWeb.Endpoint

  @endpoint Endpoint

  setup context do
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
        # The control seams stand in for the orchestrator: they settle the
        # shared snapshot the same way a real control call would, so the view
        # can only render the new state by re-reading that snapshot.
        agent_chat_pause_fun: fn identifier ->
          send(test_pid, {:streamdeck_pause, identifier})
          Agent.update(snapshot_agent, &put_fixture_agent(&1, identifier, work_state: :paused))
          {:ok, 1}
        end,
        agent_chat_resume_fun: fn identifier ->
          send(test_pid, {:streamdeck_resume, identifier})
          Agent.update(snapshot_agent, &put_fixture_agent(&1, identifier, work_state: :working))
          {:ok, :resumed}
        end,
        agent_chat_prioritize_fun: fn identifier ->
          send(test_pid, {:streamdeck_prioritize, identifier})
          Agent.update(snapshot_agent, &put_fixture_agent(&1, identifier, priority: 1))
          {:ok, :prioritized}
        end,
        agent_chat_deprioritize_fun: fn identifier ->
          send(test_pid, {:streamdeck_deprioritize, identifier})
          Agent.update(snapshot_agent, &put_fixture_agent(&1, identifier, priority: nil))
          {:ok, :deprioritized}
        end
      )
      |> Keyword.merge(awaiting_commands_config(context))

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
    segment_count = length(configured_providers()) + 2

    assert html =~ "Streamdeck+"
    assert html =~ "Stream Deck + control surface"
    assert html =~ ~s(id="sd-keys")
    assert html =~ ~s(id="sd-screen")
    # The grid container is a bare <div>, so it needs an explicit role for its
    # aria-label to be exposed to assistive technology.
    assert html =~ ~s(class="sd-keys" role="group")
    assert html =~ ~s(style="--sd-screen-segments: #{segment_count}")
    assert html =~ ~s(id="sd-knobs")
    assert length(Regex.scan(~r/data-streamdeck-key=/, html)) == 8
    assert html =~ "SUMMARY"
    assert html =~ "Claude"
    assert html =~ "Codex"
    assert html =~ "MORE AGENTS"
    # A registered-but-undispatchable provider renders no segment.
    refute html =~ ~s(data-provider="deepseek")
  end

  test "the download control opens the setup modal and the install control is gone" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    # The single remaining control is a button that opens the setup modal; the
    # Install + button is gone and no direct download href is emitted.
    assert html =~ ~s(id="streamdeck-download-control")
    assert html =~ ~s(phx-click="open-streamdeck-install")
    refute html =~ ~s(id="streamdeck-install-control")
    refute html =~ "aiur-streamdeck-0.0.0-dev.0098e3ac86a2-linux-x64-c6d1f373b30d8f038538becd746acb43ea2d4364501dc7ced4e65819e9bc76c3.tar.gz"
    refute html =~ ~s(id="streamdeck-install-modal")

    html = view |> element("#streamdeck-download-control") |> render_click()

    assert html =~ ~s(id="streamdeck-install-modal")
    assert html =~ "aiur-streamdeck-0.0.0-dev.0098e3ac86a2-linux-x64-c6d1f373b30d8f038538becd746acb43ea2d4364501dc7ced4e65819e9bc76c3.tar.gz"
    assert html =~ "Install on your Stream Deck +"
    # Two steps: one download, then one copyable prompt. The old eyebrow, the
    # "download the package, then…" lede and the trailing release-metadata line
    # are gone — the steps say all of it, without the clutter.
    assert html =~ "Step 1: Download the package"
    assert html =~ "Step 2: Paste this into your agent chat"
    assert html =~ ~s(data-copy-source)
    assert html =~ ~s(data-copy-trigger)
    refute html =~ ~s(class="section-eyebrow")
    refute html =~ "Download the package, then copy the prompt below into your coding agent"
    # Exactly one download affordance in the dialog, and no release-metadata
    # line trailing it.
    assert html |> String.split(~s( download)) |> length() == 2
    refute html =~ ~s(class="modal-meta")
    assert html =~ "Walk me through installing the Aiur Stream Deck + sidecar on Linux"
    assert html =~ "packages/streamdeck/README.md"
    refute html =~ "Aiur commit"
    refute html =~ "AIUR_PHOENIX_URL"
    refute html =~ "AIUR_DASHBOARD_PASSWORD="
    refute html =~ "streamdeck-password"
    refute html =~ "browser_fixture_password"

    html = render_click(view, "close-streamdeck-install")
    refute html =~ ~s(id="streamdeck-install-modal")
  end

  test "the download control opens the setup modal even when no package is published" do
    endpoint_config = Application.get_env(:aiur, Endpoint)
    Endpoint.config_change(%{Endpoint => Keyword.put(endpoint_config, :streamdeck_package, %{})}, [])

    try do
      {:ok, view, _html} = live(build_conn(), "/streamdeck")

      html = view |> element("#streamdeck-download-control") |> render_click()

      # The prompt block renders regardless of package availability; only the
      # download link and release metadata step aside.
      assert html =~ ~s(id="streamdeck-install-modal")
      assert html =~ "Install on your Stream Deck +"
      assert html =~ "No Stream Deck + package is published for this release"
      assert html =~ "Walk me through installing the Aiur Stream Deck + sidecar on Linux"
      assert html =~ "packages/streamdeck/README.md"
      refute html =~ "Download the Stream Deck + package"
      refute html =~ "aiur-streamdeck-"
      refute html =~ "Aiur commit"
    after
      Endpoint.config_change(%{Endpoint => endpoint_config}, [])
    end
  end

  test "renders the complete agent key face" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "sd-ag-ic"
    assert html =~ ~s(class="sd-ag-vendor" src="/provider-assets/codex-color.svg")
    assert html =~ ~s(class="sd-ag-vendor" src="/provider-assets/claude-symbol.svg")
    assert html =~ ~s(class="sd-ag-prio")
    assert html =~ ~s(class="sd-ag-id">1352</span>)
    assert html =~ ~s(class="sd-ag-title">Live running</span>)

    # Slot 5 is queued and blocked by a dependency, so its footer is stacked.
    assert html =~ "Blocked"
    assert html =~ ~s(class="sd-ag-foot col")
    assert html =~ ~s(class="sd-ag-tag blocked")
    # Every non-queued, non-empty key renders the status dot + progress footer.
    assert html =~ ~s(class="sd-ag-dot")
    assert html =~ ~s(class="sr-only">Running</span>)
    assert html =~ ~s(class="sd-ag-bar")
  end

  test "uses one green, a brighter completion shade, and structural unknown/stale states", %{snapshot_agent: snapshot_agent} do
    Agent.update(snapshot_agent, fn _ ->
      %{
        running: [
          fixture_agent("zero", "Zero progress", "codex", progress_percent: 0),
          fixture_agent("full", "Full progress", "nonesuch", progress_percent: 100),
          fixture_agent("unknown", "Unknown progress", "codex", progress_percent: nil, progress_freshness: :unknown),
          fixture_agent("stale", "Stale progress", "codex", progress_percent: 40, progress_freshness: :stale)
        ],
        retrying: [],
        # No upstreams at all, so this queued key is the ready side of the badge.
        idle: [fixture_agent("ready", "Ready queue", "claude", blocked_by: [])]
      }
    end)

    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    send(view.pid, {:running_changed, []})
    html = render(view)

    # The bar fill is the contract's progress colour, carried per key rather
    # than restated in the template. Unknown uses shape, stale uses alpha.
    assert html =~ ~s|--sd-progress-fill: #3fb950|
    assert html =~ ~s|--sd-progress-fill: #74d47f|
    assert html =~ ~s|<i style="width: 0%">|
    assert html =~ ~s|<i style="width: 100%">|
    assert html =~ ~s(class="sd-ag-foot is-progress-unknown")
    assert html =~ ~s(class="sd-ag-foot is-progress-stale")
    assert html =~ ~s(class="sd-ag-vendor-fallback")
    assert html =~ ~s(class="sd-ag-tag ready">Unblocked</span>)
  end

  test "renders every registry provider logo from its descriptor", %{snapshot_agent: snapshot_agent} do
    providers = Aiur.CodingAgent.provider_descriptors()

    Agent.update(snapshot_agent, fn _ ->
      %{
        running:
          Enum.map(providers, fn provider ->
            family = Atom.to_string(provider.provider)
            fixture_agent(family, "#{provider.label} provider", family)
          end),
        retrying: [],
        idle: []
      }
    end)

    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    for provider <- providers do
      assert html =~ ~s(src="#{provider.logo}")
    end
  end

  test "renders contract-derived state, progress, and log badge styles" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    # State colours reach the page as a contract-derived stylesheet keyed by the
    # same st-<bucket> class the packaged deck keys its bitmaps by.
    assert html =~ ".sd-key.st-running{--sd-accent:#9fd0ff;"
    assert html =~ "--sd-face:linear-gradient(180deg,#18212d,#0f151d);}"
    assert html =~ ".sd-agent-key.st-alert .sd-ag-dot,.sd-agent-key.st-alert .sd-ag-stat::before{animation:sd-pulse 1.6s ease-in-out infinite;}"
    refute html =~ ".sd-agent-key.st-running .sd-ag-dot"
    # Per-key values that depend on live fleet state stay inline.
    assert html =~ "--sd-progress-fill: hsl(63 72% 50%)"
    # The log key list replaced the badge paragraph this originally asserted, so
    # the same contract ink is now checked where it renders: the event key badge
    # and the logs strip's own event header.
    logs = enter_logs(view)
    assert logs =~ ~s(<span class="sd-log-dir sd-log-badge" data-dir="AGENT" style="--sd-log-badge: #9fd0ff">AGENT</span>)

    # A key press jumps the strip to that event's own header, which is where the
    # same contract ink paints the transcript surface.
    header = render_hook(view, "log-key-select", %{"index" => "5"})
    assert header =~ ~s(<span class="sd-log-evhdr-direction" style="color: #9fd0ff">AGENT</span>)
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
    assert html =~ ~s(id="sd-keys")
    refute html =~ "data-grid-total"
    refute html =~ ~s(id="sd-logs-view")

    html = render_click(view, "command-press", %{"command" => "logs"})

    assert %{sd_mode: :logs, sd_active: ^active} = streamdeck_assigns(view)
    assert html =~ ~s(data-mode="logs")
    assert html =~ ~s(id="sd-logs-view")
    refute html =~ "data-streamdeck-command"

    html = render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})

    assert %{sd_mode: :cmd, sd_active: ^active} = streamdeck_assigns(view)
    assert html =~ ~s(data-mode="cmd")

    html = render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})

    assert %{sd_mode: :grid, sd_active: nil} = streamdeck_assigns(view)
    assert html =~ ~s(data-mode="grid")
    assert html =~ ~s(id="sd-keys")
    assert html =~ ~s(data-segment="pager")
    refute html =~ ~s(class="sd-strip-cmd")
  end

  test "renders the focused command strip and its fixed-width BACK hint" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})

    assert html =~ ~s(class="sd-screen sd-screen-cmd")
    assert html =~ ~s(class="sd-strip-cmd st-running")
    # The info segments step aside for the full-width panel; the dial-D pager
    # segment stays, relabelled with the agent being controlled (#1607).
    refute html =~ ~s(data-segment="summary")
    assert html =~ ~s(data-pager-focus="#1352")
    assert html =~ "CONTROLLING #1352"
    assert html =~ ~s(class="sd-strip-cmd-agent-icon")
    assert html =~ ~s(src="/provider-assets/codex-color.svg")
    assert html =~ ~s(aria-valuenow="50")
    # Panel accent, status wording and bar fill all come from the shared
    # key-face contract, not from a second copy of the tokens.
    assert html =~ ~s(style="--sd-accent: #9fd0ff")
    assert html =~ ~s(<span class="sd-strip-cmd-status">Running</span>)
    assert html =~ "background: hsl(63 72% 50%)"

    assert html =~
             ~r/<span class="sd-dial-hint">\s*<span style="visibility: hidden">‹<\/span>BACK<span style="visibility: hidden">›<\/span>/
  end

  test "the command panel takes the focused agent's own state accent", %{snapshot_agent: snapshot_agent} do
    Agent.update(snapshot_agent, fn _ ->
      %{running: [], retrying: [], idle: [fixture_agent("1400", "Needs a decision", "codex", open_decision_count: 2)]}
    end)

    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    html = render_hook(view, "key-press", %{"identifier" => "1400"})

    assert html =~ ~s(class="sd-strip-cmd st-alert")
    assert html =~ ~s(style="--sd-accent: #ffcf87")
    assert html =~ ~s(<span class="sd-strip-cmd-status">Needs input</span>)
    refute html =~ ~s(style="--sd-accent: #9fd0ff")
  end

  test "renders bounded BACK and EVENTS hint arrows in logs mode" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    html = enter_logs(view)

    assert html =~ ~s(class="sd-screen sd-screen-logs")
    assert html =~ ~s(class="sd-strip-logs")

    # Both surfaces open at the live end, so at entry only the older-ward arrow
    # is available on either dial, and the window shows the newest event's
    # header with the newest transcript line under it.
    assert strip(html) =~ "event-10"
    assert strip(html) =~ "line-10"
    assert html =~ ~s(data-log-kind="evhdr")
    assert html =~ ~s(data-log-kind="message")

    assert html =~
             ~r/<span class="sd-dial-hint">\s*<span style="visibility: visible">‹<\/span>BACK<span style="visibility: hidden">›<\/span>/

    assert html =~
             ~r/<span class="sd-dial-hint">\s*<span style="visibility: visible">‹<\/span>EVENTS<span style="visibility: hidden">›<\/span>/

    html = render_hook(view, "logs-scroll", %{"axis" => "events", "delta" => "-99"})

    assert html =~
             ~r/<span class="sd-dial-hint">\s*<span style="visibility: hidden">‹<\/span>EVENTS<span style="visibility: visible">›<\/span>/

    html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "-99"})

    # Offset 0 is the origin header — the surface's defined left edge — so BACK
    # can only travel newer-ward from here.
    assert strip(html) =~ "Ticket opened"
    refute strip(html) =~ "line-10"

    assert html =~
             ~r/<span class="sd-dial-hint">\s*<span style="visibility: hidden">‹<\/span>BACK<span style="visibility: visible">›<\/span>/
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

  test "the pause command key controls the agent and adopts the state the orchestrator settles on" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}

    # The key-press pause already settled the snapshot, but the view has not
    # re-read it yet, so the key still reads Pause.
    assert command_key(html, "pause") =~ "Pause"
    assert command_key(html, "pause") =~ ~s(data-command-state="running")

    # The fleet topic is what re-reads the settled state; a command press does
    # not block on a snapshot read.
    send(view.pid, {:status_changed, %{identifier: "1352"}})
    html = render(view)

    # The key adopts the state the orchestrator settled on, not the one the
    # press assumed: it now offers Play, with the paused state and icon.
    assert command_key(html, "pause") =~ "Play"
    assert command_key(html, "pause") =~ ~s(data-command-state="paused")
    assert command_icon(html, "pause") == "play"

    # Pressing the same key again resolves to resume server-side, because the
    # direction is read from orchestrator state rather than from the client.
    html = render_hook(view, "command-press", %{"command" => "pause"})

    assert_receive {:streamdeck_resume, "1352"}
    assert html =~ "Resume requested for #1352"

    send(view.pid, {:status_changed, %{identifier: "1352"}})
    html = render(view)

    assert command_key(html, "pause") =~ "Pause"
    assert command_key(html, "pause") =~ ~s(data-command-state="running")
    assert command_icon(html, "pause") == "pause"
  end

  test "the priority command key changes real dispatch priority and re-renders the star" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}

    # Slot 1 is the prioritized running agent, so the key offers Deprioritize.
    assert command_key(html, "priority") =~ "Deprioritize"

    html = render_hook(view, "command-press", %{"command" => "priority"})

    assert_receive {:streamdeck_deprioritize, "1352"}
    assert html =~ "Deprioritize requested for #1352"

    send(view.pid, {:status_changed, %{identifier: "1352"}})
    html = render(view)

    assert command_key(html, "priority") =~ "Prioritize"
    assert command_key(html, "priority") =~ ~s(data-command-state="standard")
    assert command_icon(html, "priority") == "up"

    # The `★` is the SP-201 rendering of the same priority the grid sorts on, and
    # it lives on the grid keys rather than the command keys, so backing out to
    # grid mode is what proves the control reached the shared priority state and
    # not merely the command key's own label.
    assert render_hook(view, "dial-press", %{"index" => "0", "action" => "back"}) =~
             ~s(class="sd-keys")

    refute has_element?(view, ~s(.sd-agent-key[data-streamdeck-identifier="1352"] .sd-ag-prio))

    render_hook(view, "key-press", %{"identifier" => "1352"})
    html = render_hook(view, "command-press", %{"command" => "priority"})

    assert_receive {:streamdeck_prioritize, "1352"}
    assert html =~ "Prioritize requested for #1352"

    send(view.pid, {:status_changed, %{identifier: "1352"}})
    html = render(view)

    assert command_key(html, "priority") =~ "Deprioritize"
    assert command_key(html, "priority") =~ ~s(data-command-state="prioritized")
    assert command_icon(html, "priority") == "down"

    render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})
    assert has_element?(view, ~s(.sd-agent-key[data-streamdeck-identifier="1352"] .sd-ag-prio))
  end

  test "read-only mode renders the command keys disabled and refuses the control call" do
    endpoint_config = Application.get_env(:aiur, Endpoint)
    Endpoint.config_change(%{Endpoint => Keyword.put(endpoint_config, :dashboard_writable, false)}, [])

    try do
      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      html = render_hook(view, "key-press", %{"identifier" => "1352"})

      assert html =~ "sd-cmd-key is-disabled"

      # Element selectors rather than substring checks: a bare `html =~ "disabled"`
      # also matches the `is-disabled` class, so it would pass on a button that is
      # still clickable. The hook skips `disabled` keys, so a disabled attribute
      # is what actually stops the press from ever being emitted.
      for command <- ~w(pause priority mic) do
        assert has_element?(view, ~s(button[data-streamdeck-command="#{command}"][disabled][aria-disabled="true"]))
      end

      # Logs is navigation rather than fleet control, so it stays available.
      # It is the negative control: it proves the disabling above is the
      # read-only gate and not simply every key being rendered inert.
      assert has_element?(view, ~s(button[data-streamdeck-command="logs"][aria-disabled="false"]))
      refute has_element?(view, ~s(button[data-streamdeck-command="logs"][disabled]))

      # A forged press that bypasses the client gate is still refused server-side.
      html = render_hook(view, "command-press", %{"command" => "pause"})

      assert html =~ "Read-only dashboard: controls are disabled"
      refute_receive {:streamdeck_pause, "1352"}

      render_hook(view, "command-press", %{"command" => "priority"})
      refute_receive {:streamdeck_deprioritize, "1352"}
    after
      Endpoint.config_change(%{Endpoint => endpoint_config}, [])
    end
  end

  test "a failed command control call surfaces in the status region instead of being swallowed" do
    endpoint_config = Application.get_env(:aiur, Endpoint)

    failing_config =
      Keyword.merge(endpoint_config,
        agent_chat_pause_fun: fn _identifier -> {:error, :tracker_unavailable} end,
        agent_chat_prioritize_fun: fn _identifier -> raise "tracker exploded" end
      )

    Endpoint.config_change(%{Endpoint => failing_config}, [])

    try do
      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      render_hook(view, "key-press", %{"identifier" => "1352"})

      html = render_hook(view, "command-press", %{"command" => "pause"})

      assert html =~ "Pause failed: :tracker_unavailable"
      # The failed call must not flip the key: the agent is still running.
      assert command_key(html, "pause") =~ "Pause"
      assert command_key(html, "pause") =~ ~s(data-command-state="running")

      # The status banner (outside the device) carries the failure visibly, so
      # the operator sees a swallowed control call rather than nothing.
      assert html =~ ~s(id="sd-control-status" class="streamdeck-status")

      html = render_hook(view, "command-press", %{"command" => "priority"})
      assert html =~ "Deprioritize requested for #1352"

      # The fleet topic re-reads the settled state; a command press does not
      # block on a snapshot read.
      send(view.pid, {:status_changed, %{identifier: "1352"}})
      render(view)

      # Now standard, so the same key resolves to prioritize — which raises.
      html = render_hook(view, "command-press", %{"command" => "priority"})

      assert html =~ "Prioritize failed:"
      assert html =~ "tracker exploded"
      assert command_key(html, "priority") =~ "Prioritize"
    after
      Endpoint.config_change(%{Endpoint => endpoint_config}, [])
    end
  end

  test "cmd mode offers the design's four command keys, with Mic as press-and-hold" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}

    # Four keys, in the design's order, with the design's labels and sub lines.
    assert [{"pause", "Pause", "HOLD"}, {"priority", "Deprioritize", "LOWER"}, {"logs", "Logs", "SCROLL"}, {"mic", "Mic", "HOLD"}] ==
             rendered_command_keys(html)

    # Mic is the only press-and-hold key, so it is the only one the hook drives
    # from pointer events rather than a click.
    assert has_element?(view, ~s(button[data-streamdeck-command="mic"][data-command-hold="true"]))

    for command <- ~w(pause priority logs) do
      refute has_element?(view, ~s(button[data-streamdeck-command="#{command}"][data-command-hold]))
    end

    # A click-shaped command-press for mic is inert server-side, so the
    # press-and-hold contract cannot be worked around from the client: "mic"
    # is not a control command and reaches the catch-all clause.
    html = render_hook(view, "command-press", %{"command" => "mic"})
    assert command_key(html, "mic") =~ ~s(data-command-state="idle")
    refute_receive {:streamdeck_pause, "1352"}
  end

  test "holding the mic key marks it live and releasing clears it" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    render_hook(view, "key-press", %{"identifier" => "1352"})
    assert_receive {:streamdeck_pause, "1352"}

    html = render_hook(view, "mic-hold", %{"active" => true})
    assert command_key(html, "mic") =~ ~s(data-command-state="live")
    assert html =~ "sd-mic-key mic-live"

    # Release must clear it. A hold that latched would leave the mic open after
    # the operator let go, which is the failure press-and-hold exists to avoid.
    html = render_hook(view, "mic-hold", %{"active" => false})
    assert command_key(html, "mic") =~ ~s(data-command-state="idle")
    refute html =~ "sd-mic-key mic-live"
  end

  test "read-only mode disables the mic key and refuses the hold" do
    endpoint_config = Application.get_env(:aiur, Endpoint)
    Endpoint.config_change(%{Endpoint => Keyword.put(endpoint_config, :dashboard_writable, false)}, [])

    try do
      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      render_hook(view, "key-press", %{"identifier" => "1352"})

      assert has_element?(view, ~s(button[data-streamdeck-command="mic"][disabled][aria-disabled="true"]))

      html = render_hook(view, "mic-hold", %{"active" => true})

      assert html =~ "Read-only dashboard: controls are disabled"
      assert command_key(html, "mic") =~ ~s(data-command-state="idle")
      refute html =~ "sd-mic-key mic-live"
    after
      Endpoint.config_change(%{Endpoint => endpoint_config}, [])
    end
  end

  test "renders state-derived command keys with four disabled blank slots" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    refute html =~ "data-streamdeck-command"
    html = render_hook(view, "key-press", %{"identifier" => "1352"})

    assert command_key(html, "pause") =~ "Pause"
    assert command_key(html, "priority") =~ "Deprioritize"
    assert length(Regex.scan(~r/data-streamdeck-command=/, html)) == 4
    assert length(Regex.scan(~r/<button[^>]*disabled[^>]*aria-hidden="true"[^>]*>/, html)) == 4

    html = render_hook(view, "key-press", %{"identifier" => "1345"})

    assert command_key(html, "pause") =~ "Play"
    assert command_key(html, "priority") =~ "Prioritize"
  end

  test "command key icons track pause and priority state alongside their labels" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})

    assert command_icon(html, "pause") == "pause"
    assert command_icon(html, "priority") == "down"
    assert command_icon(html, "logs") == "logs"
    assert command_icon(html, "mic") == "mic"

    html = render_hook(view, "key-press", %{"identifier" => "1345"})

    assert command_icon(html, "pause") == "play"
    assert command_icon(html, "priority") == "up"
  end

  defp rendered_command_keys(html) do
    ~r/data-streamdeck-command="([a-z]+)".*?<span class="sd-cmd-label">([^<]*)<\/span>\s*<span class="sd-cmd-sub">([^<]*)<\/span>/s
    |> Regex.scan(html)
    |> Enum.map(fn [_match, command, label, sub] -> {command, label, sub} end)
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

  test "the transcript relay is stopped when the LiveView terminates" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

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

    # The relay is `start_link`ed to the LiveView, so a normal exit does not
    # reap it through the link alone. The LiveView must stop it in terminate/2.
    GenServer.stop(view.pid)

    refute Process.alive?(relay)
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

  test "renders an origin anchor, one key per bus event and LIVE last, jumping the transcript to a pressed key" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    html = enter_logs(view)
    logs = streamdeck_assigns(view).logs

    assert html =~ ~s(id="sd-log-keys")
    assert length(Regex.scan(~r/class="sd-key sd-log-key/, html)) == 8

    # Index 0 is the synthesised origin and LIVE is the last key, not the first.
    # The eight-key window opens on the live end, so the origin is off screen
    # until the operator scrolls back to it.
    assert hd(logs.event_keys).id == :origin
    assert List.last(logs.event_keys).id == :live
    assert logs.selected_event_id == :live
    assert logs.selected_event_index == length(logs.event_keys) - 1
    refute html =~ ~s(data-log-event-index="0")
    assert html =~ ~r/data-log-event-index="#{logs.selected_event_index}"[^>]*aria-current="true"/

    # Sitting on LIVE means sitting on the newest row, which is a transcript
    # line rather than an event header.
    assert strip(html) =~ "line-10"
    assert log_pane(html, "sd-log-transcript") =~ "line-10"
    assert html =~ ~s(data-log-kind="message")

    # A press jumps to that key's own `start` — the offset of its header — which
    # is the field the client reads rather than re-deriving the anchoring rules.
    key = Enum.at(logs.event_keys, 5)
    html = render_hook(view, "log-key-select", %{"index" => "5"})

    assert strip_offset(html) == key.start
    # The mirror pane is what makes the offset bounds behind the dial hints
    # observable, so it has to track the strip rather than drift from it.
    assert html =~ ~r{id="sd-log-transcript"[^>]*data-offset="#{key.start}"}
    assert log_pane(html, "sd-log-transcript") =~ "event-5"
    assert strip(html) =~ "event-5"
    assert html =~ ~s(data-log-kind="event_header")
    assert html =~ ~s(data-log-kind="evhdr")
    # The strip left the live end rather than merely gaining a line.
    refute strip(html) =~ "line-10"
    assert html =~ ~r/data-log-event-index="5"[^>]*aria-current="true"/
    refute html =~ ~r/data-log-event-index="#{logs.selected_event_index}"[^>]*aria-current="true"/
  end

  test "a relay flush keeps the operator's transcript position instead of snapping to the event header" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    _html = enter_logs(view)

    # The jump target is the key's own `start`, so the expected offsets are read
    # off the projection rather than guessed at.
    start = streamdeck_assigns(view).logs.event_keys |> Enum.at(2) |> Map.fetch!(:start)

    html = render_hook(view, "log-key-select", %{"index" => "2"})
    assert strip_offset(html) == start

    # Scroll one line into the selected event, then let the relay flush. The
    # position, not just the selected event, has to survive.
    html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "1"})
    assert strip_offset(html) == start + 1

    send(view.pid, {:streamdeck_transcript, "1352", %{}})
    html = render(view)
    assert strip_offset(html) == start + 1
    assert html =~ ~r/data-log-event-index="2"[^>]*aria-current="true"/
  end

  test "a relay flush keeps the key window the operator scrolled to" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    _html = enter_logs(view)

    # The key window opens pinned to its newest end, so scrolling back is what
    # moves it, and the flush must not drag it forward again.
    max_offset = streamdeck_assigns(view).logs.events_max_offset
    assert max_offset >= 2

    html = render_hook(view, "logs-scroll", %{"axis" => "events", "delta" => "-2"})
    assert html =~ ~r{id="sd-log-keys"[^>]*data-offset="#{max_offset - 2}"}

    send(view.pid, {:streamdeck_transcript, "1352", %{}})
    html = render(view)
    assert html =~ ~r{id="sd-log-keys"[^>]*data-offset="#{max_offset - 2}"}
  end

  test "the transcript opens pinned to the newest row and pins again at the origin" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    html = enter_logs(view)
    max_offset = streamdeck_assigns(view).logs.transcript_max_offset
    assert max_offset > 0

    # Logs opens where the agent is working, already at the live end, so the
    # newer-ward hint is spent before the operator touches the dial.
    assert strip_offset(html) == max_offset
    assert html =~ ~r/id="sd-screen"[^>]*?data-transcript-max-offset="#{max_offset}"/s
    assert html =~ ~s(id="sd-transcript-hint-down" class="sd-log-hint" aria-hidden="true")

    # Scrolling further forward cannot escape that end, and staying on the
    # newest row is what keeps LIVE the selection.
    html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "99"})
    assert strip_offset(html) == max_offset
    assert streamdeck_assigns(view).logs.selected_event_id == :live

    # The other end is the origin header, and it pins too.
    html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "-99"})
    assert strip_offset(html) == 0
    assert strip(html) =~ "Ticket opened"
    assert html =~ ~s(id="sd-transcript-hint-up" class="sd-log-hint" aria-hidden="true")
    assert streamdeck_assigns(view).logs.selected_event_id == :origin
    assert html =~ ~r/data-log-event-index="0"[^>]*aria-current="true"/
  end

  # The LIVE key is the design's one visually distinct key, and it is selected
  # by default. Without its own chassis it renders as an ordinary log key with
  # the blue `.sd-log-key.is-selected` glow — the #1671 shape, a design rule
  # with no counterpart in the implementation. Assert both halves: the markup
  # carries the class, and dashboard.css actually styles it, selected included.
  test "the LIVE key carries the design's green chassis, not the ordinary log key's" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    html = enter_logs(view)

    assert html =~ ~r/class="sd-key sd-log-key sd-live-key is-live is-selected"/,
           "the LIVE key must carry sd-live-key and be selected on entering logs mode"

    css = File.read!(Path.expand("../../../priv/static/dashboard.css", __DIR__))

    for selector <- [
          ".sd-live-key {",
          ".sd-live-key .sd-key-face {",
          ".sd-live-key.is-selected {",
          ".sd-live-key.is-selected .sd-live-label {"
        ] do
      assert css =~ selector,
             "dashboard.css has no `#{selector}` rule, so the LIVE key falls back to the plain log key chassis"
    end

    # The design's greens (streamdeck.design.css:128-139), not a re-derived hue.
    assert css =~ "linear-gradient(180deg, #227a4d, #17583a)"
    assert css =~ "linear-gradient(180deg, #37d97e, #1f9c56)"
    assert css =~ "--sd-live: #4ade80;"
    assert css =~ "--sd-live-ink: #8fe0a8;"
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

      write_event_log("1352", [event_line(1, "emit", "ticket.1352.pr.opened", "PR #1904", "2026-08-02T00:00:00Z")])

      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      html = enter_logs(view)
      max_offset = streamdeck_assigns(view).logs.transcript_max_offset

      # Origin header, the one bus header, then the three transcript rows that
      # sit underneath it, with the diff unrolled into its own two hunk lines —
      # seven rows, so six is the newest offset.
      assert max_offset == 6

      # A transcript row is labelled by its own role; the direction badge is the
      # bus event's, and it reaches the deck as an event key rather than as a
      # key per turn.
      assert html =~ "[assistant] newest message"
      assert html =~ ~s(<span class="sd-log-dir sd-log-badge" data-dir="EMIT" style="--sd-log-badge: #9fd0ff">EMIT</span>)
      assert html =~ ~r/id="sd-screen"[^>]*?data-transcript-max-offset="#{max_offset}"/s
      assert html =~ ~r{id="sd-log-transcript"[^>]*data-max-offset="#{max_offset}"}

      # Scrolling back travels toward the origin now, not toward the newest row.
      html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "-99"})
      assert strip_offset(html) == 0
      assert html =~ ~s(id="sd-transcript-hint-up" class="sd-log-hint" aria-hidden="true")

      # Two rows forward is the classified diff, which keeps its real hunk lines.
      html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "2"})
      assert html =~ "older message"
      assert html =~ "lib/example.ex"
      assert html =~ "sd-log-entry-diff"
      assert html =~ ~s(class="sd-log-diff-line is-addition")
      assert html =~ "+new"
    end)
  end

  test "rebuilds LIVE and event starts from the durable feed when the relay receives a new event" do
    with_production_feed(fn ->
      durable_events = [
        event_line(1, "emit", "ticket.1352.pr.opened", "older durable event", "2026-08-02T00:01:00Z"),
        event_line(2, "emit", "ticket.1352.ci.passed", "newest durable event", "2026-08-02T00:02:00Z")
      ]

      durable_transcript = [
        feed_event("assistant", "older durable line", "turn-1", timestamp: "2026-08-02T00:01:30Z"),
        feed_event("assistant", "newest durable line", "turn-2", timestamp: "2026-08-02T00:02:30Z")
      ]

      write_event_log("1352", durable_events)
      write_feed("1352", durable_transcript)

      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      enter_logs(view)

      # The durable feed is the projection's only source, so it lands before the
      # relay is told about it. Writing it from a background task instead would
      # leave the file behind for whichever test ran next.
      write_event_log(
        "1352",
        durable_events ++ [event_line(3, "emit", "ticket.1352.pr.merged", "live durable event", "2026-08-02T00:03:00Z")]
      )

      write_feed("1352", durable_transcript ++ [feed_event("assistant", "live durable line", "turn-3", timestamp: "2026-08-02T00:03:30Z")])

      AgentPubSub.broadcast_transcript("1352", AgentEvents.transcript_event(:assistant, "live durable line"))

      # "PR merged" is the new bus row's key face, so waiting on it proves the
      # flush rebuilt the key list rather than only the transcript.
      assert eventually(fn -> render(view) =~ "PR merged" end)

      logs = streamdeck_assigns(view).logs

      # LIVE is the last key, after the origin and one key per bus row, and it
      # re-pins to the new newest entry because it was the selection.
      assert Enum.map(logs.event_keys, & &1.body) ==
               ["Ticket opened", "older durable event", "newest durable event", "live durable event", "LIVE"]

      assert List.last(logs.event_keys).id == :live
      assert List.last(logs.event_keys).start == logs.transcript_max_offset
      assert logs.selected_event_id == :live
      assert logs.transcript_offset == logs.transcript_max_offset

      # Every key's `start` was rebuilt against the longer transcript, so a
      # press still lands on that event's own header.
      html = render_hook(view, "log-key-select", %{"index" => "1"})
      selected = streamdeck_assigns(view).logs

      assert selected.selected_event_id == {:bus, "emit", 1}
      assert selected.transcript_offset == selected.event_starts[1]
      assert [%{kind: :event_header, body: "older durable event"} | _] = selected.transcript_visible
      assert strip(html) =~ "older durable event"
    end)
  end

  test "refreshes relative event times while logs mode remains open" do
    with_production_feed(fn ->
      timestamp = DateTime.utc_now() |> DateTime.add(-59, :second) |> DateTime.to_iso8601()
      write_feed("1352", [feed_event("assistant", "recent durable event", "turn-1", timestamp: timestamp)])

      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      assert enter_logs(view) =~ "now"

      assert eventually(fn -> render(view) =~ "1m" end)
    end)
  end

  # Both handlers reload the logs from the durable feed, so the observable proof
  # is new feed content reaching the view — not merely that render/1 still works.
  test "relay alerts and control updates reload the logs from the durable feed" do
    with_production_feed(fn ->
      write_feed("1352", [feed_event("assistant", "first durable entry", "turn-1")])

      {:ok, view, _html} = live(build_conn(), "/streamdeck")
      html = enter_logs(view)
      assert html =~ "first durable entry"
      refute html =~ "entry after the alert"

      write_feed("1352", [
        feed_event("assistant", "first durable entry", "turn-1"),
        feed_event("assistant", "entry after the alert", "turn-2")
      ])

      AgentPubSub.broadcast_alert("1352", AgentEvents.alert_event("deploy", "Needs attention"))
      assert eventually(fn -> render(view) =~ "entry after the alert" end)

      write_feed("1352", [
        feed_event("assistant", "first durable entry", "turn-1"),
        feed_event("assistant", "entry after the alert", "turn-2"),
        feed_event("assistant", "entry after the control update", "turn-3")
      ])

      AgentPubSub.broadcast_control_lifecycle("1352", %{request_id: "request-1", status: :paused})
      assert eventually(fn -> render(view) =~ "entry after the control update" end)
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

  test "marks retained stale readings instead of presenting them as current", %{meter_agent: meter_agent} do
    Agent.update(meter_agent, fn meters ->
      stale_at = DateTime.add(DateTime.utc_now(), -601, :second)

      meters
      |> put_in(["claude", "observed_at"], stale_at)
      |> put_in(["claude", "windows", "weekly", "observed_at"], stale_at)
    end)

    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ ~s(data-meter="weekly" data-percent="47" data-observed="true" data-freshness="stale")
    assert html =~ "47% · Thu 6PM · stale · 10m ago"
    assert html =~ "Weekly · 47% · Thu 6PM · stale · 10m ago"
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

  # The bezel is what tells this glyph apart from the Units four-square at nav
  # size, so it is locked in alongside the keys — and the keys have to stay
  # smaller than the frame they sit in.
  test "the nav icon is a 2x2 key grid inside a bezel" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    [svg] =
      Regex.run(~r{<svg[^>]*>(?:(?!</svg>).)*?x="2" y="2" width="20" height="20".*?</svg>}s, html) ||
        flunk("the Stream Deck nav icon svg was not rendered")

    widths = svg |> then(&Regex.scan(~r/<rect [^>]*width="(\d+)"/, &1)) |> Enum.map(&(&1 |> List.last() |> String.to_integer()))

    assert length(widths) == 5,
           "the Stream Deck nav icon must show a bezel plus 4 keys in a 2x2 grid"

    # Measured rather than hardcoded: an 8-unit key inside a 20-unit bezel would
    # satisfy a literal width assertion while losing the visual distinction the
    # bezel exists to draw.
    [bezel | keys] = widths

    assert Enum.max(keys) * 2 < bezel,
           "each key must stay well inside the bezel around them"
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

  defp put_fixture_agent(snapshot, identifier, attrs) do
    Map.new(snapshot, fn {bucket, entries} ->
      {bucket, Enum.map(entries, fn entry -> if entry.identifier == identifier, do: Map.merge(entry, Map.new(attrs)), else: entry end)}
    end)
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
        priority: nil,
        blocked_by: [%{id: "missing-upstream"}]
      },
      Map.new(attrs)
    )
  end

  defp fixture_provider_meters do
    %{
      "claude" => %{
        "state" => "observed",
        "windows" => %{
          "session" => %{"kind" => "rate_limit", "used_percent" => 30, "remaining" => "22m", "freshness" => "fresh"},
          "weekly" => %{"kind" => "rate_limit", "used_percent" => 47, "resets_at" => "2026-08-13T18:00:00Z", "freshness" => "fresh"}
        }
      },
      "codex" => %{
        "state" => "observed",
        "windows" => %{
          "session" => %{"kind" => "rate_limit", "used_percent" => 50, "remaining" => "1h", "freshness" => "fresh"},
          "weekly" => %{"kind" => "rate_limit", "used_percent" => 75, "resets_at" => "2026-08-14T20:00:00Z", "freshness" => "fresh"}
        }
      }
    }
  end

  defp configured_providers do
    families =
      Aiur.Config.agent_backend_configs()
      |> CodingAgent.dispatchable_backends()
      |> Enum.map(&CodingAgent.family_for/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.to_atom/1)
      |> MapSet.new()

    Enum.filter(CodingAgent.provider_descriptors(), &MapSet.member?(families, &1.provider))
  end

  # The emulator's injected feed stands in for both real sources: ten
  # shared-event-bus rows, which are the deck's keys, and one transcript line
  # under each, which is the detail a key jumps into. A bare list would now be
  # read as transcript only and project no event keys at all.
  defp fixture_logs(_identifier) do
    %{
      events: Enum.map(1..10, &fixture_bus_event/1),
      # `AgentEventFeed.list/2` hands the transcript back newest first; the
      # projection is what reverses it into reading order.
      transcript: Enum.map(10..1//-1, &feed_entry("line-#{&1}", fixture_stamp(&1, 30)))
    }
  end

  defp fixture_bus_event(index) do
    %{
      type: "event",
      id: index,
      kind: "self",
      topic: "ticket.1352.agent.progress",
      badge: Aiur.AgentEventFeed.badge_for_kind("self"),
      label: "event-#{index}",
      body: "",
      timestamp: fixture_stamp(index, 0)
    }
  end

  defp feed_entry(body, timestamp) do
    %{
      type: "message",
      badge: "AGENT",
      role: "assistant",
      body: body,
      timestamp: timestamp
    }
  end

  defp fixture_stamp(minute, second) do
    "2026-08-02T00:#{String.pad_leading(to_string(minute), 2, "0")}:#{String.pad_leading(to_string(second), 2, "0")}Z"
  end

  defp feed_event(role, body, turn_id, opts \\ [])

  defp feed_event(role, body, turn_id, payload) when is_map(payload),
    do: feed_event(role, body, turn_id, payload: payload)

  defp feed_event(role, body, turn_id, opts) when is_list(opts) do
    %{
      "role" => role,
      "body" => body,
      "timestamp" => Keyword.get(opts, :timestamp, "2026-08-02T00:00:00Z"),
      "msg_id" => nil,
      "sequence" => 1,
      "turn_id" => turn_id,
      "payload" => Keyword.get(opts, :payload)
    }
  end

  defp write_feed(identifier, events) do
    path = IssueLog.transcript_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")
  end

  # The shared event bus is a second, separate source from the transcript, so a
  # production-feed test that wants real event keys has to write real
  # `[event:<kind>]` rows. `with_production_feed/1` removes them again, because
  # one of these tests rewrites the log from a Task, which cannot register an
  # `on_exit`, and the whole suite shares the "1352" identifier.
  defp write_event_log(identifier, lines) do
    path = IssueLog.event_log_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  defp event_line(id, kind, topic, summary, timestamp) do
    "#{timestamp} [event:#{kind}] id=#{id} #{topic}: #{summary}"
  end

  defp with_production_feed(fun) do
    previous_endpoint_value = Endpoint.config(:streamdeck_logs_fun)
    previous_endpoint_config = Application.get_env(:aiur, Endpoint, [])

    Phoenix.Config.put(Endpoint, :streamdeck_logs_fun, nil)
    Application.put_env(:aiur, Endpoint, Keyword.put(previous_endpoint_config, :streamdeck_logs_fun, nil))

    try do
      fun.()
    after
      Enum.each(~w(1352 1345), &File.rm(IssueLog.event_log_path(&1)))
      Application.put_env(:aiur, Endpoint, previous_endpoint_config)
      Phoenix.Config.put(Endpoint, :streamdeck_logs_fun, previous_endpoint_value)
    end
  end

  # The touch strip is the transcript surface in logs mode, so its contents run
  # from the `#sd-screen` tag to the well that follows it. A non-greedy
  # `</div>` would stop at the first strip entry.
  defp strip(html) do
    case Regex.run(~r{id="sd-screen".*?class="sd-well"}s, html) do
      [pane | _] -> pane
      nil -> flunk("missing #sd-screen touch strip")
    end
  end

  defp strip_offset(html) do
    case Regex.run(~r/id="sd-screen"[^>]*?data-transcript-offset="(\d+)"/s, html) do
      [_full, offset] -> String.to_integer(offset)
      nil -> flunk("#sd-screen carries no data-transcript-offset")
    end
  end

  defp log_pane(html, id) do
    case Regex.run(~r{<div id="#{id}"[^>]*>.*?</div>}s, html) do
      [pane | _] -> pane
      nil -> flunk("missing log pane ##{id}")
    end
  end

  defp streamdeck_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp eventually(fun, attempts \\ 30)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end

  defp enter_logs(view, identifier \\ "1352") do
    render_hook(view, "key-press", %{"identifier" => identifier})
    render_click(view, "command-press", %{"command" => "logs"})
  end

  defp slot_identifiers(html) do
    Regex.scan(~r/data-streamdeck-identifier="([^"]+)"/, html, capture: :all_but_first)
    |> List.flatten()
  end

  defp command_key(html, command) do
    [key] = Regex.run(~r{<button[^>]*data-streamdeck-command="#{command}".*?</button>}s, html)
    key
  end

  defp command_icon(html, command) do
    [_key, icon] = Regex.run(~r/data-streamdeck-icon="([^"]+)"/, command_key(html, command))
    icon
  end

  defp fleet_snapshot(total) do
    agents = for index <- 1..total, do: fixture_agent("fleet-#{index}", "Fleet #{index}", "codex")
    %{running: [hd(agents)], retrying: [], idle: tl(agents)}
  end

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "carries the awaiting-Commands banner into Stream Deck" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "2 units awaiting commands"
    assert html =~ ~s(href="/decisions")
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

  # --- awaiting-Commands banner ---------------------------------------------

  defp awaiting_commands_config(context) do
    case context[:awaiting_commands] do
      nil -> []
      counts -> [decision_store: AwaitingCommands.start(counts)]
    end
  end
end
