defmodule AiurWeb.Streamdeck.FleetChannelTest do
  use AiurWeb.StreamdeckChannelCase

  test "channel builds Fleet from the shared window and returns category and CI drill images" do
    owner = self()

    put_endpoint_config(
      streamdeck_build_queue_fun: fn -> %{status: :disabled} end,
      streamdeck_build_window_fun: fn _, _, _ ->
        send(owner, :window_read)

        {:ok,
         %{
           sources: %{agents: %{state: "ok", observed_at: 1}},
           sections: %{now: [%{num: 17, id: "17", sec: "now", title: "CI ticket", agent: %{state: "ci_wait"}}], plan: [], nq: []},
           capacity: %{max: nil, stale: true},
           daemon: %{state: "stale", heartbeat_at: System.system_time(:millisecond) - 7_000}
         }}
      end
    )

    socket = joined_socket()
    receive_barrier(:window_read)
    assert_push("frame", _initial)

    for expected <- ["feature", "epic"] do
      ref = push(socket, "input", %{"kind" => "dial_press", "index" => 3})
      assert_reply(ref, :ok, %{"view" => ^expected})
      flush_frame(socket)
      assert_push("frame", _intermediate)
    end

    ref = push(socket, "input", %{"kind" => "dial_press", "index" => 3})
    assert_reply(ref, :ok, %{"view" => "fleet"})
    flush_frame(socket)
    assert_push("frame", %{keys: keys, strip: strip})
    assert length(keys) == 8
    assert Enum.at(keys, 5).svg =~ "Waiting for CI"
    assert List.last(keys).svg =~ "1 / —"
    assert hd(strip).svg =~ "stale"
    ref = push(socket, "input", %{"kind" => "key", "index" => 5, "action" => "down"})
    assert_reply(ref, :ok, %{"view" => "fleet"})
    flush_frame(socket)
    assert_push("frame", %{keys: [ci | rest]})
    assert ci.svg =~ "CI ticket"
    assert rest == List.duplicate(nil, 7)
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.stack == [{:state, ["ci_wait"]}]
    ref = push(socket, "input", %{"kind" => "key_press", "index" => 0})
    assert_reply(ref, :ok, %{"view" => "fleet"})
    flush_frame(socket)
    assert_push("frame", _selected)
    ref = push(socket, "input", %{"kind" => "dial_turn", "index" => 1, "ticks" => -1})
    assert_reply(ref, :error, %{reason: "disabled", frame: %{keys: [ci | rest], strip: strip}})
    assert ci.svg =~ "CI ticket"
    assert rest == List.duplicate(nil, 7)
    assert hd(strip).svg =~ "queue disabled"
    assert Enum.at(strip, 1).svg =~ "Capacity — stale"
    flush_frame(socket)
    assert_push("frame", _feedback)
    ref = push(socket, "input", %{"kind" => "dial_press", "index" => 3})
    assert_reply(ref, :ok, %{"view" => "ticket"})
    flush_frame(socket)
    assert_push("frame", %{keys: ticket_keys, strip: ticket_strip})
    refute Enum.at(ticket_strip, 1).svg =~ "Capacity"
    assert Enum.any?(ticket_keys, &(&1 != nil and &1.svg =~ "CI ticket"))
    refute Enum.any?(ticket_keys, &(&1 != nil and &1.svg =~ "Needs command"))
  end

  defp flush_frame(socket) do
    state = :sys.get_state(socket.channel_pid)
    send(socket.channel_pid, {:flush_fleet, state.assigns.fleet_flush})
    :sys.get_state(socket.channel_pid)
  end
end
