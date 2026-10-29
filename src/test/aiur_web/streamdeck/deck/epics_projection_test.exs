defmodule AiurWeb.Streamdeck.Deck.EpicsProjectionTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.StreamdeckFleet

  test "one shared window feeds pushed Epic frames, physical key drill-in and back" do
    owner = self()
    row = %{num: 7, id: "7", title: "Feature-owned UI", sec: "nq", epic: "f-deck", general_epics: ["ui"], agent: nil, pct: nil}

    window = window(%{"ui" => %{label: "UI", general: true}, "docs" => %{label: "Docs", general: true}}, %{"ui" => %{open: 1, closed: 0, total: 1}, "docs" => %{open: 2, closed: 0, total: 2}}, [row])

    EndpointStubs.put(
      streamdeck_build_window_fun: fn _, _, _ ->
        send(owner, :read_window)
        {:ok, window}
      end
    )

    grid = StreamdeckFleet.grid(%{})
    assert [%{title: "Docs", remaining: 2}, %{title: "UI", remaining: 1, tickets: [%{id: "7"}]}] = grid.epics
    assert_received :read_window
    refute_received :read_window
    {socket, frame} = open_epics()
    ui_index = Enum.find_index(frame.keys, &(&1 && String.ends_with?(&1.label, "— UI")))
    assert is_integer(ui_index)
    assert Enum.at(frame.keys, ui_index).label =~ "1 remaining"
    assert Enum.at(frame.keys, ui_index).svg =~ "UI"

    drill = input_frame(socket, %{"kind" => "key", "index" => ui_index, "action" => "down"})
    assert hd(drill.keys).label =~ "Feature-owned UI"
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.stack == [epic: "ui"]
    back = input_frame(socket, %{"kind" => "dial", "index" => 3, "action" => "long_press"})
    assert Enum.at(back.keys, ui_index).label =~ "1 remaining"
  end

  test "pushed Epic empty state names configuration when every total is zero" do
    put_window(window(%{"ui" => %{label: "UI", general: true}}, %{"ui" => %{open: 0, closed: 0, total: 0}}))
    {_socket, frame} = open_epics()
    assert frame.keys == List.duplicate(nil, 8)
    assert hd(frame.strip).label =~ "No epics configured"
    assert hd(frame.strip).svg =~ "build_order.general_epics"
    refute hd(frame.strip).label =~ "0 remaining"
  end

  test "pushed Epic unknown counts remain unavailable with their reason" do
    put_window(window(%{"ci" => %{label: "CI", general: true}}, %{"ci" => %{open: nil, closed: nil, total: nil, reason: "history incomplete"}}))
    {_socket, frame} = open_epics()
    assert hd(frame.keys).svg =~ "—"
    assert hd(frame.keys).svg =~ "history incomplete"
    refute hd(frame.keys).svg =~ "progress-fill"
    refute hd(frame.keys).label =~ "0 remaining"
  end

  test "pushed Epic drill-in frames show priority errors and queue-edge feedback in the strip" do
    row = %{num: 7, id: "7", title: "Feature-owned UI", sec: "nq", epic: "f-deck", general_epics: ["ui"]}
    put_window(window(%{"ui" => %{label: "UI", general: true}}, %{"ui" => %{open: 1, closed: 0, total: 1}}, [row]))
    {socket, _frame} = open_epics()
    input_frame(socket, %{"kind" => "key", "index" => 0, "action" => "down"})
    input_frame(socket, %{"kind" => "key", "index" => 0, "action" => "down"})
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.selected == "7"

    EndpointStubs.put(streamdeck_build_queue_fun: fn -> %{status: :disabled, queues: []} end)
    input = %{"kind" => "dial", "index" => 1, "action" => "turn", "delta" => -1}
    assert_reply(push(socket, "input", input), :error, %{reason: "disabled"})
    error = pushed_frame(socket)
    assert hd(error.strip).label == "queue disabled"
    assert hd(error.strip).svg =~ "queue disabled"

    queue = %{status: :running, queues: [%{kind: :list, name: "ops", items: [%{number: 7, position: 0}]}]}
    EndpointStubs.put(streamdeck_build_queue_fun: fn -> queue end)
    feedback = input_frame(socket, input)
    assert hd(feedback.strip).label == "already at queue edge"
    assert hd(feedback.strip).svg =~ "already at queue edge"
  end

  defp open_epics do
    socket = joined_socket()
    assert_push("frame", _initial)
    input_frame(socket, %{"kind" => "dial", "index" => 3, "action" => "press"})
    {socket, input_frame(socket, %{"kind" => "dial", "index" => 3, "action" => "press"})}
  end

  defp input_frame(socket, input) do
    assert_reply(push(socket, "input", input), :ok, reply)
    assert Enum.sort(Map.keys(reply)) == ~w(chip_offset page view)
    assert reply["chip_offset"] == 0
    pushed_frame(socket)
  end

  defp pushed_frame(socket) do
    state = :sys.get_state(socket.channel_pid)
    send(socket.channel_pid, {:flush_fleet, state.assigns.fleet_flush})
    :sys.get_state(socket.channel_pid)
    assert_push("frame", frame)
    refute_received %Message{event: "frame"}
    frame
  end

  defp put_window(window), do: EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:ok, window} end)

  defp window(epics, progress, rows \\ []) do
    %{
      epics: epics,
      epic_progress: progress,
      sources: %{agents: %{state: "ok", observed_at: 123}},
      sections: %{now: [], plan: [], nq: rows}
    }
  end
end
