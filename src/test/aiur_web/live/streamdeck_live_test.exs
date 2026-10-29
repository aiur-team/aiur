defmodule AiurWeb.StreamdeckLiveTest do
  use AiurWeb.StreamdeckLiveCase

  setup do
    previous = Application.get_env(:aiur, :build_conversation_source)
    Application.put_env(:aiur, :build_conversation_source, :unavailable)
    on_exit(fn -> if previous, do: Application.put_env(:aiur, :build_conversation_source, previous), else: Application.delete_env(:aiur, :build_conversation_source) end)
  end

  test "renders the Stream Deck chassis, eight keys, strip, and knobs" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ ~s(<b id="route-title" role="heading" aria-level="1">Streamdeck+</b>)
    assert html =~ ~s(<span class="snav-label aiur-shell__label">Streamdeck</span>)
    assert html =~ ~s(id="sd-keys")
    assert html =~ ~s(id="sd-screen")
    # The grid container is a bare <div>, so it needs an explicit role for its
    # aria-label to be exposed to assistive technology.
    assert html =~ ~s(class="sd-keys" role="group")
    assert html =~ ~s(width: 800px; height: 100px;)
    assert html =~ ~s(id="sd-knobs")
    assert length(Regex.scan(~r/data-streamdeck-key=/, html)) == 8
    assert html =~ "AIUR"
    assert html =~ ~s(data-streamdeck-region="200")
    assert html =~ "Queued"
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

    Endpoint.config_change(
      %{Endpoint => Keyword.put(endpoint_config, :streamdeck_package, %{})},
      []
    )

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

  test "renders the complete agent key face as one accessible SVG" do
    {:ok, _view, html} = live(build_conn(), "/streamdeck")
    document = Floki.parse_fragment!(html)

    [label] =
      Floki.attribute(document, "#sd-keys [data-streamdeck-identifier='1352']", "aria-label")

    assert label == "1352 Running 50% — Live running"
    assert length(Floki.find(document, "#sd-keys [data-streamdeck-identifier='1352'] svg")) == 1
    assert Floki.find(document, "#sd-keys .sd-agent-top, #sd-keys .sd-ag-title") == []
    assert html =~ "Blocked"
    assert html =~ "★"
    assert html =~ ~s(data-part="progress-fill")
  end

  test "uses one green, a brighter completion shade, and structural unknown/stale states", %{
    snapshot_agent: snapshot_agent
  } do
    Agent.update(snapshot_agent, fn _ ->
      %{
        running: [
          fixture_agent("zero", "Zero progress", "codex", progress_percent: 0),
          fixture_agent("full", "Full progress", "nonesuch", progress_percent: 100),
          fixture_agent("unknown", "Unknown progress", "codex",
            progress_percent: nil,
            progress_freshness: :unknown
          ),
          fixture_agent("stale", "Stale progress", "codex",
            progress_percent: 40,
            progress_freshness: :stale
          )
        ],
        retrying: [],
        # No upstreams at all, so this queued key is the ready side of the badge.
        idle: [fixture_agent("ready", "Ready queue", "claude", blocked_by: [])]
      }
    end)

    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    send(view.pid, {:running_changed, []})
    html = render(view)

    document = Floki.parse_fragment!(html)

    assert Floki.attribute(
             document,
             "[data-streamdeck-identifier='zero'] [data-part='progress-fill']",
             "fill"
           ) == ["#3fb950"]

    assert Floki.attribute(
             document,
             "[data-streamdeck-identifier='full'] [data-part='progress-fill']",
             "fill"
           ) == ["#74d47f"]

    assert Floki.find(
             document,
             "[data-streamdeck-identifier='unknown'] [data-part='progress-fill']"
           ) == []

    assert Floki.attribute(document, "[data-streamdeck-identifier='unknown']", "aria-label") == [
             "unknown Running progress unknown — Unknown progress"
           ]

    assert Floki.find(
             document,
             "[data-streamdeck-identifier='stale'] [data-freshness='stale'][opacity='0.45']"
           ) != []

    assert html =~ "Unblocked"

    stale = render_hook(view, "key-press", %{"identifier" => "stale"})
    refute stale =~ "is-progress-stale"
    assert strip(stale) =~ "Conversation unavailable"
    assert streamdeck_assigns(view).sd_active.progress_freshness == "stale"

    render_hook(view, "dial-press", %{"index" => "0", "action" => "back"})
    unknown = render_hook(view, "key-press", %{"identifier" => "unknown"})
    assert strip(unknown) =~ "Conversation unavailable"
    assert streamdeck_assigns(view).sd_active.progress_percent == nil
    refute strip(unknown) =~ ~s(data-part="progress-fill")
  end

  test "renders every registry provider logo from its descriptor", %{
    snapshot_agent: snapshot_agent
  } do
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
    document = Floki.parse_fragment!(html)

    for provider <- providers do
      logo =
        File.read!(Path.expand("../../../priv/static/#{Path.basename(provider.logo)}", __DIR__))
        |> Floki.parse_fragment!()

      assert Floki.find(logo, "path, image") != []

      for {tag, attribute} <- [{"path", "d"}, {"image", "href"}],
          value <- Floki.attribute(logo, tag, attribute) do
        rendered_values =
          Floki.attribute(
            document,
            "#sd-keys [data-streamdeck-identifier='#{provider.provider}'] svg #{tag}",
            attribute
          )

        assert value in rendered_values
      end
    end
  end

  test "the shared renderer paints state, progress and log direction inks" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")
    assert html =~ ~s(fill="#3fb950")
    logs = enter_logs(view)
    document = Floki.parse_fragment!(logs)

    assert Floki.attribute(document, "#sd-log-keys [data-dir='AGENT']", "fill") |> Enum.uniq() ==
             ["#9fd0ff"]

    header = render_hook(view, "log-key-select", %{"index" => "5"})
    assert has_element?(view, "#sd-screen [data-log-kind='evhdr'][fill='#9fd0ff']", "AGENT")
    assert strip(header) =~ "event-5"
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

    html = render_click(view, "dial-press", %{"index" => "3", "action" => "cycle-window"})

    assert %{sd_mode: :logs, sd_active: %{identifier: identifier}} = streamdeck_assigns(view)
    assert identifier == active.identifier
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
    assert html =~ ~s(data-streamdeck-region="600")
    refute html =~ ~s(class="sd-strip-cmd")
  end

  test "renders full-width conversation and the fixed-width BACK hint" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})

    assert has_element?(view, "#sd-screen[data-mode-view='cmd-strip']")
    assert has_element?(view, "[data-streamdeck-region='0']", "Conversation unavailable")
    refute has_element?(view, "[data-streamdeck-region='600']")
    assert streamdeck_assigns(view).deck_chat.ref.id == "1352"
    assert streamdeck_assigns(view).sd_active.progress_percent == 50

    assert html =~
             ~r/<span class="sd-dial-hint">\s*<span style="visibility: hidden">‹<\/span>BACK<span style="visibility: hidden">›<\/span>/
  end

  test "the command panel takes the focused agent's own state accent", %{
    snapshot_agent: snapshot_agent
  } do
    Agent.update(snapshot_agent, fn _ ->
      %{
        running: [],
        retrying: [],
        idle: [fixture_agent("1400", "Needs a decision", "codex", open_decision_count: 2)]
      }
    end)

    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    html = render_hook(view, "key-press", %{"identifier" => "1400"})

    assert streamdeck_assigns(view).sd_active.bucket == :alert
    assert strip(html) =~ "Conversation unavailable"
    assert streamdeck_assigns(view).sd_active.state == "command"
  end

  test "renders bounded BACK and EVENTS hint arrows in logs mode" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    html = enter_logs(view)

    assert has_element?(view, "#sd-screen[data-mode-view='logs-strip']")

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

    assert %{sd_mode: :logs, sd_active: %{identifier: identifier}} = streamdeck_assigns(view)
    assert identifier == active.identifier
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

    assert %{sd_mode: :grid, selected_identifier: "1400", sd_active: nil} =
             streamdeck_assigns(view)

    assert html =~ ~s(data-grid-selected-identifier="1400")
  end

  test "renders grid keys in authoritative column-major order on each shared server page" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    assert slot_identifiers(html) |> Enum.take(8) ==
             ["1352", "1350", "1361", "1363", "1345", "1360", "1362", "1366"]

    html = render_hook(view, "grid-page", %{"value" => "50"})

    assert html =~ ~s(data-grid-column-offset="4")

    assert slot_identifiers(html) |> Enum.take(8) ==
             ["1367", "1371", "1373", "1375", "1370", "1372", "1374", "1376"]
  end

  test "retains the shared server page across fleet shrink and grow", %{
    snapshot_agent: snapshot_agent
  } do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "grid-page", %{"value" => "50"})
    assert html =~ ~s(data-grid-dial-value="50")
    assert html =~ ~s(data-grid-column-offset="4")

    Agent.update(snapshot_agent, fn _ -> fleet_snapshot(9) end)
    send(view.pid, {:running_changed, []})
    html = render(view)
    assert html =~ ~s(data-grid-dial-value="50")
    assert html =~ ~s(data-grid-column-offset="4")

    Agent.update(snapshot_agent, fn _ -> fleet_snapshot(25) end)
    send(view.pid, {:running_changed, []})
    html = render(view)
    assert html =~ ~s(data-grid-dial-value="50")
    assert html =~ ~s(data-grid-column-offset="4")
  end

  test "refreshes the grid when the fleet topic changes", %{snapshot_agent: snapshot_agent} do
    {:ok, view, html} = live(build_conn(), "/streamdeck")
    assert html =~ "Live running"

    Agent.update(snapshot_agent, fn _ ->
      %{running: [], retrying: [], idle: [fixture_agent("1400", "Live replacement", "codex")]}
    end)

    send(view.pid, {:running_changed, []})

    html = render(view)
    assert html =~ "Live replacement"
    refute html =~ "Live running"
  end

  test "keeps same-rank key order stable when snapshot order changes", %{
    snapshot_agent: snapshot_agent
  } do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    snapshot = %{
      running: [
        fixture_agent("10", "First raw", "codex"),
        fixture_agent("2", "Second raw", "codex")
      ],
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
