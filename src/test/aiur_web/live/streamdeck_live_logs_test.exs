defmodule AiurWeb.StreamdeckLiveLogsTest do
  use AiurWeb.StreamdeckLiveCase

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
      refute_receive {:streamdeck_resume, "1345"}, 100
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
        refute_receive {:streamdeck_pause, _identifier}, 100
        refute_receive {:streamdeck_resume, _identifier}, 100

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
end
