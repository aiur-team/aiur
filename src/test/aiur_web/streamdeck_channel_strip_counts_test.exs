defmodule AiurWeb.StreamdeckChannelStripCountsTest do
  use AiurWeb.StreamdeckChannelCase

  test "dial B moves the category window in the pushed frame, with navigation only in the reply" do
    states = ~w(error command retrying active ci_wait usage_limited parked paused blocked merge-queued unknown)

    rows =
      states
      |> Enum.with_index(1)
      |> Enum.map(fn {state, number} ->
        %{id: "AIUR-#{number}", num: number, title: state, sec: "now", agent: %{state: state}}
      end)

    put_endpoint_config(
      streamdeck_build_window_fun: fn _, _, _ ->
        {:ok, %{sources: %{agents: %{state: "ok", observed_at: System.system_time(:millisecond)}}, sections: %{now: rows, plan: [], nq: []}}}
      end
    )

    socket = joined_socket()
    assert_push("frame", %{strip: [build, before, backlog]})
    assert before.svg =~ ~s(data-state="error")
    refute before.svg =~ ~s(data-state="paused")
    assert before.svg =~ "+4 more"

    ref = push(socket, "input", %{"kind" => "dial", "index" => 1, "action" => "turn", "delta" => 1})
    state = :sys.get_state(socket.channel_pid)
    assert_reply(ref, :ok, reply)
    assert reply == %{"view" => "ticket", "page" => 0, "chip_offset" => 1}
    assert state.assigns.deck_nav.chip_offset == 1
    assert is_reference(state.assigns.fleet_flush)

    send(socket.channel_pid, {:flush_fleet, state.assigns.fleet_flush})
    :sys.get_state(socket.channel_pid)
    assert_push("frame", %{strip: [^build, after_tick, ^backlog]})
    refute after_tick.svg =~ ~s(data-state="error")
    assert after_tick.svg =~ ~s(data-state="paused")
    assert after_tick.svg =~ "+4 more"
    refute before.hash == after_tick.hash
    refute_received %Message{event: "frame"}
  end
end
