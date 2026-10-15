defmodule AiurWeb.StreamdeckLiveTest do
  use AiurWeb.StreamdeckLiveCase

  test "renders the Stream Deck chassis, eight keys, strip, and knobs" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")
    segment_count = length(configured_providers()) + 2

    assert html =~ ~s(<b id="route-title" role="heading" aria-level="1">Streamdeck+</b>)
    assert html =~ ~s(<span class="snav-label">Streamdeck</span>)
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
    refute html =~ "releases/download/streamdeck-nightly/aiur-streamdeck-nightly-linux-x64.tar.gz"
    refute html =~ ~s(id="streamdeck-install-modal")

    html = view |> element("#streamdeck-download-control") |> render_click()

    assert html =~ ~s(id="streamdeck-install-modal")
    # The download points at the rolling nightly's fixed-name asset, never at a
    # per-commit release that housekeeping could remove.
    assert html =~ "releases/download/streamdeck-nightly/aiur-streamdeck-nightly-linux-x64.tar.gz"
    refute html =~ ~r|releases/download/streamdeck-[0-9a-f]{40}/|
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
    refute html =~ "is-progress-stale"
    assert html =~ ~s(class="sd-ag-vendor-fallback")
    # Unblocked is drawn as the open-padlock glyph in the key's bottom-right
    # corner, matching the sidecar; only the held side keeps a text pill.
    assert html =~ ~s(class="sd-ag-unblocked" role="img" aria-label="Unblocked")
    refute html =~ ~s(class="sd-ag-tag ready")

    stale = render_hook(view, "key-press", %{"identifier" => "stale"})
    refute stale =~ "is-progress-stale"
    assert stale =~ ~s(aria-valuenow="40")

    render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})
    unknown = render_hook(view, "key-press", %{"identifier" => "unknown"})
    assert unknown =~ ~r/class="sd-strip-cmd st-running is-progress-unknown(?:\s*)"/
    refute strip(unknown) =~ "aria-valuenow"
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
    assert html =~ "--sd-progress-fill: #3fb950"
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
    assert html =~ ~r/class="sd-strip-cmd st-running(?:\s*)"/
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
    assert html =~ "background: #3fb950"

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
end
