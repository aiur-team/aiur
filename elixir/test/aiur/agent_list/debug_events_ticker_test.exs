defmodule Aiur.AgentList.DebugEventsTickerTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentList.Renderer
  alias Aiur.Events.DebugLog

  defp build_state(overrides) do
    %{
      summaries: [],
      selection_index: 0,
      selection_focus: :agents,
      columns: 80,
      rows: 24,
      help_visible?: false,
      project_label: nil,
      dashboard_url: nil,
      refresh_label: nil,
      debug_mode?: true,
      perf_summary: %{
        agent_list_ready_ms: 100,
        chat_pane_visible_ms: nil,
        opencode_render_ms: nil
      },
      warmth_events: [],
      debug_events: []
    }
    |> Map.merge(Map.new(overrides))
  end

  describe "events section (always on, bordered)" do
    test "renders events inside the AgentList box even when debug_mode? is false (always-on now)" do
      state = build_state(debug_mode?: false, debug_events: [debug_entry(:publish, topic: "ticket.42.branch.push")])
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      # Single box: AgentList top + bottom curved corners.
      assert output =~ "╭─ AIUR"
      assert output =~ "╰"

      # No separate "Events" box header anymore.
      refute output =~ "╭─ Events"

      # Event line renders inside the box, separated from the table
      # rows by a `├──┤` divider.
      assert output =~ "├"
      assert output =~ "💬 42"
    end

    test "events render inline with the agent table; legend lives in the footer" do
      events = [
        debug_entry(:read, topic: "ticket.42.branch.push", id: 4290, identifier: "42"),
        debug_entry(:receive, topic: "ticket.42.branch.push", id: 4287, identifier: "99"),
        debug_entry(:publish, topic: "ticket.42.branch.push", id: 4287)
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      # Inside the same box; divider above the events block.
      assert output =~ "├"

      # Per-line format:
      assert output =~ "💬 42 pushed:"
      assert output =~ "📬 99 Agent received from 42:"
      assert output =~ "📄 42 Agent ingested:"

      # Legend now renders in the footer (outside the box), not above the events.
      assert output =~ "💬 publish · 📬 receive · 📄 read"
    end

    test "newest event renders BELOW older events (anchored to bottom)" do
      events = [
        debug_entry(:read, topic: "ticket.42.branch.push", id: 3),
        debug_entry(:receive, topic: "ticket.42.branch.push", id: 2, identifier: "99"),
        debug_entry(:publish, topic: "ticket.42.branch.push", id: 1)
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      publish_pos = :binary.match(output, "💬 42 pushed:") |> elem(0)
      receive_pos = :binary.match(output, "📬 99 Agent received from 42:") |> elem(0)
      read_pos = :binary.match(output, "📄 42 Agent ingested:") |> elem(0)

      assert publish_pos < receive_pos
      assert receive_pos < read_pos
    end

    test "hides oldest events when section would exceed budget" do
      # 24 rows total, table chrome eats some; the events box gets a
      # bounded budget. Generate more events than can fit and verify
      # OLDEST are dropped, not the newest.
      events =
        for i <- 100..1, do: debug_entry(:publish, topic: "ticket.#{i}.branch.push", id: i)

      state = build_state(rows: 24, debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      # Newest (ticket 100) MUST appear; oldest (ticket 1) MUST NOT.
      assert output =~ "💬 100 pushed:"
      refute output =~ "💬 1 pushed:"
    end

    test "events block collapses when pane has no remaining vertical budget" do
      # Tiny pane — chrome alone fills it; the events block needs at
      # least 2 rows (divider + one event line) and won't render here.
      events = [debug_entry(:publish, topic: "ticket.1.branch.push", id: 1)]
      state = build_state(rows: 6, debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      refute output =~ "💬 1 pushed:"
    end
  end

  describe "persistence across render cycles" do
    test "events survive consecutive renders with unchanged debug_events" do
      events = [debug_entry(:publish, topic: "ticket.42.branch.push", id: 42)]
      state = build_state(debug_events: events)

      first = state |> Renderer.render() |> IO.iodata_to_binary()
      assert first =~ "💬 42 pushed:"

      second = state |> Renderer.render() |> IO.iodata_to_binary()
      assert second =~ "💬 42 pushed:"
    end
  end

  describe "App render() pipes debug_events through" do
    test "Renderer reads debug_events from the state map" do
      events = [debug_entry(:publish, topic: "ticket.7.branch.push", id: 7)]
      with_events = build_state(debug_events: events)
      without_events = build_state(debug_events: [])

      with_out = with_events |> Renderer.render() |> IO.iodata_to_binary()
      without_out = without_events |> Renderer.render() |> IO.iodata_to_binary()

      assert with_out =~ "💬 7 pushed:"
      refute without_out =~ "💬 7 pushed:"
    end
  end

  describe "DebugLog broadcast" do
    test "subscribers receive {:event_debug, entry} on publish kind" do
      DebugLog.subscribe()
      DebugLog.broadcast(:publish, "ticket.7.branch.push", id: 99)
      assert_receive {:event_debug, %{kind: :publish, topic: "ticket.7.branch.push", id: 99}}, 500
      DebugLog.unsubscribe()
    end

    test "receive kind carries identifier" do
      DebugLog.subscribe()
      DebugLog.broadcast(:receive, "ticket.7.branch.push", id: 100, identifier: "7")

      assert_receive {:event_debug, %{kind: :receive, identifier: "7"}}, 500
      DebugLog.unsubscribe()
    end
  end

  defp debug_entry(kind, opts \\ []) do
    %{
      kind: kind,
      topic: Keyword.get(opts, :topic, "ticket.1.branch.push"),
      id: Keyword.get(opts, :id),
      identifier: Keyword.get(opts, :identifier),
      at: System.monotonic_time(:millisecond)
    }
  end
end
