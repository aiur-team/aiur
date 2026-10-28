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

    for expected <- ["feature", "epic"] do
      ref = push(socket, "input", %{"kind" => "dial_press", "index" => 3})
      assert_reply(ref, :ok, %{"view" => ^expected})
    end

    ref = push(socket, "input", %{"kind" => "dial_press", "index" => 3})
    assert_reply(ref, :ok, %{"view" => "fleet", "frame" => %{keys: keys, strip: strip}})
    assert length(keys) == 8
    assert Enum.at(keys, 3).svg =~ "Waiting for CI"
    assert List.last(keys).svg =~ "1 / —"
    assert hd(strip).svg =~ "stale"
    ref = push(socket, "input", %{"kind" => "key_press", "index" => 3})
    assert_reply(ref, :ok, %{"frame" => %{keys: [ci | rest]}})
    assert ci.svg =~ "CI ticket"
    assert rest == List.duplicate(nil, 7)
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.stack == [{:state, ["ci_wait"]}]
    ref = push(socket, "input", %{"kind" => "key_press", "index" => 0})
    assert_reply(ref, :ok, %{"view" => "fleet"})
    ref = push(socket, "input", %{"kind" => "dial_turn", "index" => 1, "ticks" => -1})
    assert_reply(ref, :error, %{reason: "disabled", frame: %{keys: [ci | rest], strip: strip}})
    assert ci.svg =~ "CI ticket"
    assert rest == List.duplicate(nil, 7)
    assert hd(strip).svg =~ "queue disabled"
    ref = push(socket, "input", %{"kind" => "dial_press", "index" => 3})
    assert_reply(ref, :ok, %{"view" => "ticket", "frame" => %{keys: ticket_keys}})
    assert Enum.any?(ticket_keys, &(&1 != nil and &1.svg =~ "CI ticket"))
    refute Enum.any?(ticket_keys, &(&1 != nil and &1.svg =~ "Needs command"))
  end
end
