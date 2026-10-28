defmodule AiurWeb.Streamdeck.Deck.EpicsProjectionTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.StreamdeckFleet

  test "one shared window feeds Epic keys, channel frames, drill-in and back" do
    owner = self()
    row = %{num: 7, id: "7", title: "Feature-owned UI", sec: "nq", epic: "f-deck", general_epics: ["ui"], agent: nil, pct: nil}

    window = %{
      epics: %{"ui" => %{label: "UI", general: true}},
      epic_progress: %{"ui" => %{open: 1, closed: 0, total: 1}},
      sources: %{agents: %{state: "ok", observed_at: 123}},
      sections: %{now: [], plan: [], nq: [row]}
    }

    EndpointStubs.put(
      streamdeck_build_window_fun: fn _, _, _ ->
        send(owner, :read_window)
        {:ok, window}
      end
    )

    grid = StreamdeckFleet.grid(%{})
    assert [%{title: "UI", remaining: 1, tickets: [%{id: "7"}]}] = grid.epics
    assert_received :read_window
    refute_received :read_window
    socket = joined_socket()
    assert_reply(push(socket, "input", %{"kind" => "dial_press", "index" => 3}), :ok, %{"view" => "feature"})
    assert_reply(push(socket, "input", %{"kind" => "dial_press", "index" => 3}), :ok, %{"view" => "epic", "frame" => frame})
    assert hd(frame.keys).label =~ "1 remaining"
    assert hd(frame.keys).svg =~ "UI"
    assert_reply(push(socket, "input", %{"kind" => "key_press", "index" => 0}), :ok, %{"frame" => drill})
    assert hd(drill.keys).label =~ "Feature-owned UI"
    assert_reply(push(socket, "input", %{"kind" => "key_press", "index" => 0}), :ok)
    assert :sys.get_state(socket.channel_pid).assigns.deck_effects == [{:open_ticket, "7"}]
    assert_reply(push(socket, "input", %{"kind" => "dial_long_press", "index" => 3}), :ok, %{"frame" => back})
    assert hd(back.keys).label =~ "1 remaining"
  end
end
