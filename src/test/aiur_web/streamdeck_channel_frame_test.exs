defmodule AiurWeb.StreamdeckChannelFrameTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.BuildHome.UsageInputs
  alias Aiur.TestSupport.StreamdeckBuildFixture
  alias AiurWeb.Streamdeck.FrameUpdates

  test "join sends a full SVG frame and raw inputs coalesce into one full frame" do
    socket = joined_socket()
    assert_push("frame", %{keys: keys, strip: strip})
    assert length(keys) == 8
    assert Enum.all?(strip, &String.starts_with?(&1.svg, "<svg"))

    for input <- [%{"kind" => "dial", "index" => 3, "action" => "press"}, %{"kind" => "key", "index" => 0, "action" => "down"}] do
      ref = push(socket, "input", input)
      assert_reply(ref, :ok, _reply)
    end

    state = :sys.get_state(socket.channel_pid)
    assert state.assigns.deck_nav.view == :feature
    send(socket.channel_pid, {:flush_fleet, state.assigns.fleet_flush})
    :sys.get_state(socket.channel_pid)
    assert_push("frame", %{keys: updated, strip: [_ | _]})
    assert length(updated) == 8
    refute_received %Message{event: "frame"}
  end

  test "physical key positions, page labels and shrink follow the server list" do
    rows = Enum.map(1..12, &AgentEvents.agent_summary("AIUR-#{&1}", :running, 0, %{title: "Ticket #{&1}"}))
    put_rows(rows)
    socket = joined_socket()
    assert_push("frame", %{keys: keys})
    shown = Enum.at(keys, 1).label
    ref = push(socket, "input", %{"kind" => "key", "index" => 1, "action" => "down"})
    assert_reply(ref, :ok, _reply)
    [{:open_ticket, selected}] = :sys.get_state(socket.channel_pid).assigns.deck_effects
    assert String.starts_with?(shown, selected <> " ")

    ref = push(socket, "input", %{"kind" => "dial", "index" => 3, "action" => "turn", "delta" => 1})
    assert_reply(ref, :ok, %{"page" => 1})
    flush_frame(socket)
    assert_push("frame", %{keys: later, strip: strip})
    assert List.last(strip).label == "9–12 / 12"
    ref = push(socket, "input", %{"kind" => "key", "index" => 1, "action" => "down"})
    assert_reply(ref, :ok, _reply)
    [{:open_ticket, selected}] = :sys.get_state(socket.channel_pid).assigns.deck_effects
    assert String.starts_with?(Enum.at(later, 1).label, selected <> " ")

    put_rows(Enum.take(rows, 2))
    send(socket.channel_pid, :fleet_changed)
    :sys.get_state(socket.channel_pid)
    flush_frame(socket)
    assert_push("frame", %{keys: shrunk})
    assert Enum.count(shrunk, &is_map/1) == 2
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.pages.ticket == 0
  end

  test "view changes and drills render the same items the reducer resolves" do
    put_rows([AgentEvents.agent_summary("AIUR-1", :running, 0, %{title: "Drill"})])
    socket = joined_socket()
    assert_push("frame", _initial)

    for view <- ["feature", "epic", "fleet"] do
      ref = push(socket, "input", %{"kind" => "dial", "index" => 3, "action" => "press"})
      assert_reply(ref, :ok, %{"view" => ^view})
      flush_frame(socket)
      assert_push("frame", %{keys: keys})
      if view in ["feature", "epic"], do: assert(keys == List.duplicate(nil, 8))
    end

    ref = push(socket, "input", %{"kind" => "key", "index" => 0, "action" => "down"})
    assert_reply(ref, :ok, _reply)
    flush_frame(socket)
    assert_push("frame", %{keys: drilled})
    assert Enum.any?(drilled, &is_map/1)
    assert [{:fleet, _id}] = :sys.get_state(socket.channel_pid).assigns.deck_nav.stack
  end

  test "a meter update behind a pending fleet flush reaches the last physical frame" do
    meter = start_supervised!({Agent, fn -> 20 end})

    put_endpoint_config(
      streamdeck_usage_load_fun: fn _, _ ->
        percent = Agent.get(meter, & &1)
        UsageInputs.inputs(%{meters: %{codex: UsageInputs.snapshot(:codex, %{"primary" => UsageInputs.window(percent)})}})
      end
    )

    socket = joined_socket()
    assert_push("frame", initial)
    send(socket.channel_pid, :fleet_changed)
    fleet = :sys.get_state(socket.channel_pid).assigns.fleet_flush
    assert is_reference(fleet)
    Agent.update(meter, fn _ -> 90 end)
    send(socket.channel_pid, {:provider_meter_changed, %ProviderMeterSnapshot{}})
    pending = :sys.get_state(socket.channel_pid)
    assert pending.assigns.fleet_flush == fleet

    send(socket.channel_pid, {:flush_fleet, fleet})
    :sys.get_state(socket.channel_pid)
    assert_push("frame", before_usage)
    assert before_usage.strip == initial.strip

    send(socket.channel_pid, {:flush_usage, pending.assigns.usage_flush})
    updated = :sys.get_state(socket.channel_pid)
    assert updated.assigns.deck_usage["codex"]["windows"]["session"]["used_percent"] == 90
    assert_push("usage", %{"codex" => %{"windows" => %{"session" => %{"used_percent" => 90}}}})
    assert is_reference(updated.assigns.fleet_flush)
    flush_frame(socket)
    assert_push("frame", latest)
    assert latest == FrameUpdates.frame(:sys.get_state(socket.channel_pid))
    refute latest.strip == initial.strip
    assert Enum.find(latest.strip, &(&1.x == 200)).svg =~ "10%"
  end

  test "usage and fleet changes refresh frames and stale flushes are ignored" do
    socket = joined_socket()
    assert_push("frame", _initial)
    # Inspect the handler result before its 250 ms timer can run on a slow host.
    state =
      :sys.replace_state(socket.channel_pid, fn current ->
        {:noreply, scheduled} = AiurWeb.StreamdeckChannel.handle_info({:provider_meter_changed, %ProviderMeterSnapshot{}}, current)
        assert is_reference(scheduled.assigns.usage_flush)
        assert scheduled.assigns.fleet_flush == nil
        scheduled
      end)

    send(socket.channel_pid, {:flush_usage, state.assigns.usage_flush})
    state = :sys.get_state(socket.channel_pid)
    assert is_reference(state.assigns.fleet_flush)
    send(socket.channel_pid, {:flush_fleet, state.assigns.fleet_flush})
    :sys.get_state(socket.channel_pid)
    assert_push("frame", %{keys: keys})
    assert length(keys) == 8
    send(socket.channel_pid, {:flush_fleet, make_ref()})
    :sys.get_state(socket.channel_pid)
    refute_received %Message{event: "frame"}
  end

  test "raw release, touch and dial edges are validated without navigation" do
    socket = joined_socket()

    for input <- [
          %{"kind" => "key", "index" => 0, "action" => "up"},
          %{"kind" => "dial", "index" => 0, "action" => "down"},
          %{"kind" => "dial", "index" => 0, "action" => "up"},
          %{"kind" => "touch", "index" => 0, "action" => "tap", "x" => 0}
        ] do
      ref = push(socket, "input", input)
      assert_reply(ref, :ok, %{})
    end

    for input <- [
          %{"kind" => "key", "index" => 0, "action" => "turn"},
          %{"kind" => "dial", "index" => 0, "action" => "tap"},
          %{"kind" => "dial", "index" => 0, "action" => "turn", "delta" => 33},
          %{"kind" => "touch", "index" => 0, "action" => "tap", "x" => 800}
        ] do
      ref = push(socket, "input", input)
      assert_reply(ref, :error, %{reason: "invalid_input"})
    end

    for input <- [%{"kind" => "dial", "index" => 3, "action" => "long_press"}, %{"kind" => "dial", "index" => 0, "action" => "turn", "delta" => 1}] do
      ref = push(socket, "input", input)
      assert_reply(ref, :ok, %{"view" => "ticket", "page" => 0})
    end
  end

  defp put_rows(rows) do
    snapshot = %{running: rows, retrying: [], idle: []}

    put_endpoint_config(
      streamdeck_snapshot_fun: fn -> snapshot end,
      streamdeck_build_window_fun: fn _, _, _ -> StreamdeckBuildFixture.window(snapshot) end
    )
  end

  defp flush_frame(socket) do
    state = :sys.get_state(socket.channel_pid)
    send(socket.channel_pid, {:flush_fleet, state.assigns.fleet_flush})
    :sys.get_state(socket.channel_pid)
  end
end
