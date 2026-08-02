defmodule AiurWeb.StreamdeckLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.AgentEvents
  alias Aiur.AgentPubSub
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
        streamdeck_snapshot_fun: fn -> Agent.get(snapshot_agent, & &1) end,
        streamdeck_provider_meters_fun: fn -> Agent.get(meter_agent, & &1) end,
        streamdeck_logs_fun: fn -> fixture_logs() end,
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

    assert html =~ "Streamdeck+"
    assert html =~ "Stream Deck + control surface"
    assert html =~ ~s(id="sd-keys")
    assert html =~ ~s(id="sd-screen")
    assert html =~ ~s(id="sd-knobs")
    assert length(Regex.scan(~r/data-streamdeck-key=/, html)) == 8
    assert html =~ "Summary"
    assert html =~ "Claude"
    assert html =~ "Codex"
    assert html =~ "Pager"
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

  test "key presses request pause for running and resume for paused agents" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    html = render_hook(view, "key-press", %{"identifier" => "1352"})
    assert html =~ "Pause requested for #1352"
    assert html =~ ~s(data-grid-selected-identifier="1352")
    assert_receive {:streamdeck_pause, "1352"}

    html = render_hook(view, "key-press", %{"identifier" => "1345"})
    assert html =~ "Resume requested for #1345"
    assert html =~ ~s(data-grid-selected-identifier="1345")
    assert_receive {:streamdeck_resume, "1345"}
  end

  test "subscribes the initial focused agent exactly once" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    event = AgentEvents.transcript_event(:assistant, "focused-agent-event")

    assert :ok = AgentPubSub.broadcast_transcript("1352", event)

    html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "99"})
    assert html |> String.split("focused-agent-event") |> length() == 2
  end

  test "read-only focus swaps subscriptions and ignores the old agent topic" do
    endpoint_config = Application.get_env(:aiur, Endpoint)
    read_only_config = Keyword.put(endpoint_config, :dashboard_writable, false)
    Endpoint.config_change(%{Endpoint => read_only_config}, [])

    try do
      {:ok, view, html} = live(build_conn(), "/streamdeck")
      assert html =~ ~s(data-grid-selected-identifier="1352")

      html = render_hook(view, "key-press", %{"identifier" => "1345"})
      assert html =~ ~s(data-grid-selected-identifier="1345")
      refute_receive {:streamdeck_pause, _identifier}
      refute_receive {:streamdeck_resume, _identifier}

      old_event = AgentEvents.transcript_event(:assistant, "old-agent-event")
      new_event = AgentEvents.transcript_event(:assistant, "new-agent-event")
      assert :ok = AgentPubSub.broadcast_transcript("1352", old_event)
      assert :ok = AgentPubSub.broadcast_transcript("1345", new_event)

      html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "99"})
      refute html =~ "old-agent-event"
      assert html |> String.split("new-agent-event") |> length() == 2
    after
      Endpoint.config_change(%{Endpoint => endpoint_config}, [])
    end
  end

  test "pages the complete fleet and clamps the page at both ends" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    assert html =~ ~s(data-grid-page-count="3")
    assert html =~ ~s(data-streamdeck-identifier="1352")
    refute html =~ ~s(data-streamdeck-identifier="1367")

    html = render_hook(view, "grid-page", %{"page" => "1"})
    assert html =~ ~s(data-grid-page="1")
    assert html =~ ~s(data-page="1" aria-current="page")
    assert html =~ ~s(data-streamdeck-identifier="1367")

    html = render_hook(view, "grid-page", %{"page" => "99"})
    assert html =~ ~s(data-grid-page="2")
    assert html =~ ~s(data-streamdeck-identifier="1377")
  end

  test "scrolls bounded event and transcript logs and accepts live transcript events" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "event-1"
    assert html =~ "transcript-1"

    html = render_hook(view, "logs-scroll", %{"axis" => "events", "delta" => "1"})
    assert html =~ ~r{id="sd-log-events"[^>]*data-offset="1"}
    assert html =~ "event-2"
    refute html =~ "event-1"

    html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "99"})
    assert html =~ ~r{id="sd-log-transcript"[^>]*data-offset="6"[^>]*data-max-offset="6"}
    assert html =~ "transcript-10"
    assert html =~ ~s(id="sd-transcript-hint-down" class="sd-log-hint" aria-hidden="true")

    send(view.pid, {:transcript_event, %{role: :assistant, body: "live transcript", sequence: 99}})
    html = render_hook(view, "logs-scroll", %{"axis" => "transcript", "delta" => "99"})
    assert html =~ "live transcript"
  end

  test "renders provider percentages and refreshes them from the live meter event", %{meter_agent: meter_agent} do
    {:ok, view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "daily 30%"
    assert html =~ "daily 50%"

    Agent.update(meter_agent, fn meters ->
      put_in(meters["claude"]["windows"]["daily"]["used_percent"], 60)
    end)

    send(view.pid, {:provider_meter_changed, %{}})
    assert render(view) =~ "daily 60%"
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
      "claude" => %{"state" => "observed", "windows" => %{"daily" => %{"used_percent" => 30}}},
      "codex" => %{"state" => "observed", "windows" => %{"daily" => %{"used_percent" => 50}}}
    }
  end

  defp fixture_logs do
    %{
      events: Enum.map(1..10, &%{role: :system, body: "event-#{&1}"}),
      transcript: Enum.map(1..10, &%{role: :assistant, body: "transcript-#{&1}"})
    }
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
