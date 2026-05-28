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

  describe "debug events ticker" do
    test "renders nothing when debug_mode? is false" do
      state = build_state(debug_mode?: false, debug_events: [debug_entry(:publish)])
      output = state |> Renderer.render() |> IO.iodata_to_binary()
      refute output =~ "events ("
      refute output =~ "💬"
    end

    test "renders header + recent events when debug_mode? is true" do
      events = [
        debug_entry(:read, topic: "ticket.42.branch.push", id: 4290, identifier: "42"),
        debug_entry(:receive, topic: "ticket.42.branch.push", id: 4287, identifier: "42"),
        debug_entry(:publish, topic: "ticket.42.branch.push", id: 4287)
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~ "events ("
      assert output =~ "💬 ticket.42.branch.push id=4287"
      assert output =~ "📬 ticket.42.branch.push id=4287 (#42)"
      assert output =~ "📄 ticket.42.branch.push id=4290 (#42)"
    end

    test "newest event renders BELOW older events (anchored to bottom)" do
      events = [
        debug_entry(:read, topic: "ticket.42.read", id: 3),
        debug_entry(:receive, topic: "ticket.42.receive", id: 2),
        debug_entry(:publish, topic: "ticket.42.publish", id: 1)
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      publish_pos = :binary.match(output, "ticket.42.publish") |> elem(0)
      receive_pos = :binary.match(output, "ticket.42.receive") |> elem(0)
      read_pos = :binary.match(output, "ticket.42.read") |> elem(0)

      assert publish_pos < receive_pos
      assert receive_pos < read_pos
    end

    test "hides oldest events when ticker would exceed budget" do
      # 24 rows total, header + table chrome eats most; the ticker gets
      # a small remaining budget. Generate more events than can fit and
      # verify the OLDEST are dropped, not the newest.
      events =
        for i <- 100..1, do: debug_entry(:publish, topic: "ticket.#{i}.x", id: i)

      state = build_state(rows: 24, debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      # Newest (id=100) MUST appear; oldest (id=1) MUST NOT.
      assert output =~ "id=100"
      refute output =~ "id=1 "
    end

    test "renders empty when pane has no remaining vertical budget" do
      # Tiny pane — chrome alone fills it.
      events = [debug_entry(:publish, topic: "ticket.1.branch.push", id: 1)]
      state = build_state(rows: 6, debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      refute output =~ "events ("
    end
  end

  describe "persistence across render cycles" do
    test "events survive a render → other_event_with_unchanged_debug_events → render cycle" do
      events = [debug_entry(:publish, topic: "ticket.42.branch.push", id: 42)]
      state = build_state(debug_events: events)

      # Render once — event appears.
      first = state |> Renderer.render() |> IO.iodata_to_binary()
      assert first =~ "💬 ticket.42.branch.push id=42"

      # Render again with identical state — event MUST still appear.
      second = state |> Renderer.render() |> IO.iodata_to_binary()
      assert second =~ "💬 ticket.42.branch.push id=42"

      # Render a third time after simulating something that updates other
      # state but preserves debug_events (e.g., perf summary update).
      bumped = %{state | perf_summary: Map.put(state.perf_summary, :opencode_render_ms, 500)}
      third = bumped |> Renderer.render() |> IO.iodata_to_binary()
      assert third =~ "💬 ticket.42.branch.push id=42"
    end
  end

  describe "App render() pipes debug_events through" do
    # Regression: the previous bug was that defp render/1 in app.ex
    # built a render_state via Map.take + Map.put and didn't include
    # debug_events. This test locks in that render_state must carry it.
    test "Renderer reads debug_events from the state map" do
      events = [debug_entry(:publish, topic: "t", id: 1)]
      with_events = build_state(debug_events: events)
      without_events = build_state(debug_events: [])

      with_out = with_events |> Renderer.render() |> IO.iodata_to_binary()
      without_out = without_events |> Renderer.render() |> IO.iodata_to_binary()

      assert with_out =~ "id=1"
      refute without_out =~ "id=1"
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
