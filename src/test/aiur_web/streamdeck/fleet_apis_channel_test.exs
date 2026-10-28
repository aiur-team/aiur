defmodule AiurWeb.Streamdeck.FleetAPIsChannelTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.BuildHome.UsageInputs, as: I
  alias AiurWeb.Streamdeck.FrameUpdates

  test "Fleet input pushes shared API bars once using the initial usage load" do
    owner = self()
    now = DateTime.utc_now()
    reset = DateTime.add(now, 3600)

    windows =
      Map.new([{"core", 3950}, {"graphql", 400}], fn {tag, remaining} ->
        {tag, %{limit: 5000, remaining: remaining, used_percent: (5000 - remaining) / 50, reset_at: reset, observed_at: now}}
      end)

    inputs = I.inputs(%{github: {:ok, %{state: :observed, windows: windows, backoffs: []}}})

    put_endpoint_config(
      streamdeck_usage_load_fun: fn :streamdeck, _opts ->
        send(owner, :usage_loaded)
        inputs
      end
    )

    socket = joined_socket()
    receive_barrier(:usage_loaded)
    assert_push("frame", %{strip: initial_strip})
    refute Enum.at(initial_strip, 1).svg =~ "GitHub"

    for view <- ["feature", "epic", "fleet"] do
      ref = push(socket, "input", %{"kind" => "dial_press", "index" => 3})
      assert_reply(ref, :ok, reply)
      assert reply == %{"view" => view, "page" => 0}
      flush(socket)
      assert_push("frame", frame)

      if view == "fleet" do
        svg = Enum.at(frame.strip, 2).svg
        assert svg =~ "core 79% left"
        assert svg =~ "gql 8% ⏸ held until #{Calendar.strftime(reset, "%H:%M")}"
        state = :sys.get_state(socket.channel_pid)
        assert frame == FrameUpdates.frame(state)
      end
    end

    refute_received :usage_loaded
    refute_push("frame", _extra)
  end

  test "fleet flush refreshes expired usage once and keeps rapid flushes coalesced" do
    owner = self()
    count = :atomics.new(1, [])
    inputs = I.inputs()

    put_endpoint_config(
      streamdeck_usage_load_fun: fn :streamdeck, _opts ->
        send(owner, :usage_loaded)
        if :atomics.add_get(count, 1, 1) == 1, do: inputs, else: %{inputs | github: {:error, :unavailable}}
      end
    )

    socket = joined_socket()
    receive_barrier(:usage_loaded)
    assert_push("frame", _initial)

    :sys.replace_state(socket.channel_pid, fn state ->
      Phoenix.Socket.assign(state, :deck_usage_refreshed_at, System.monotonic_time(:millisecond) - 60_001)
    end)

    send(socket.channel_pid, :fleet_changed)
    :sys.get_state(socket.channel_pid)
    flush(socket)
    receive_barrier(:usage_loaded)
    assert_push("frame", _updated)
    assert [%{lines: [%{remaining_percent: nil, tip: tip} | _]}] = :sys.get_state(socket.channel_pid).assigns.deck_usage["apis"]
    assert tip =~ "GitHub budget meter unavailable"
    send(socket.channel_pid, :fleet_changed)
    :sys.get_state(socket.channel_pid)
    flush(socket)
    assert_push("frame", _next)
    refute_received :usage_loaded
  end

  defp flush(socket) do
    state = :sys.get_state(socket.channel_pid)
    send(socket.channel_pid, {:flush_fleet, state.assigns.fleet_flush})
    :sys.get_state(socket.channel_pid)
  end
end
