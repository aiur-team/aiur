defmodule AiurWeb.StreamdeckChannelPriorityTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.StreamdeckBuildFixture
  alias AiurWeb.Streamdeck.Deck.Nav
  alias AiurWeb.Streamdeck.Render

  setup do
    owner = self()
    queue = start_supervised!({Agent, fn -> model(3) end})

    put_endpoint_config(
      streamdeck_snapshot_fun: fn -> %{running: [], retrying: [], idle: [AgentEvents.agent_summary("4", :queued, 0, %{title: "Priority"})]} end,
      streamdeck_build_window_fun: fn _, _, _ -> StreamdeckBuildFixture.window(%{idle: [AgentEvents.agent_summary("4", :queued, 0, %{title: "Priority"})]}) end,
      streamdeck_build_queue_fun: fn -> Agent.get(queue, & &1) end,
      streamdeck_reorder_fun: fn id, at ->
        send(owner, {:reorder, id, at})
        Agent.update(queue, fn _ -> model(at) end)
        :ok
      end
    )

    :ok
  end

  test "raw input resolves selection, moves once, replies with read-back and renders queue position" do
    socket = joined_socket()
    :sys.get_state(socket.channel_pid)
    assert_push("frame", _initial, 2_000)
    ref = push(socket, "input", %{"kind" => "key_press", "index" => 0})
    assert_reply(ref, :ok, %{"view" => "ticket"}, 2_000)
    ref = push(socket, "input", %{"kind" => "dial_turn", "index" => 1, "ticks" => -3})
    :sys.get_state(socket.channel_pid)
    assert_reply(ref, :ok, reply, 2_000)
    assert reply == %{"view" => "ticket", "page" => 0}
    refute Map.has_key?(reply, "frame")
    frame = flush_frame(socket)
    assert_received {:reorder, "4", 0}
    refute_received {:reorder, _, _}
    face = Enum.find(frame.keys, & &1)
    assert face.label =~ "Queued #1"
    assert face.svg =~ "Queued #1"
    assert hd(frame.strip).label == "Queued #1"
    assert hd(frame.strip).svg =~ "Queued #1"
  end

  test "physical input pushes priority feedback and read-back in a coalesced frame" do
    socket = joined_socket()
    :sys.get_state(socket.channel_pid)
    assert_push("frame", _initial, 2_000)
    ref = push(socket, "input", %{"kind" => "key", "index" => 0, "action" => "down"})
    assert_reply(ref, :ok, %{"view" => "ticket"}, 2_000)
    ref = push(socket, "input", %{"kind" => "dial", "index" => 1, "action" => "turn", "delta" => -3})
    assert_reply(ref, :ok, %{"view" => "ticket", "page" => 0}, 2_000)
    assert_received {:reorder, "4", 0}
    refute_received {:reorder, _, _}
    state = :sys.get_state(socket.channel_pid)
    send(socket.channel_pid, {:flush_fleet, state.assigns.fleet_flush})
    :sys.get_state(socket.channel_pid)
    assert_push("frame", %{keys: keys, strip: strip}, 2_000)
    assert Enum.find(keys, & &1).label =~ "Queued #1"
    assert hd(strip).label == "Queued #1"
    assert hd(strip).svg =~ "Queued #1"
  end

  test "unauthenticated socket refuses priority without calling the queue" do
    socket = %Phoenix.Socket{assigns: %{deck_nav: %Nav{selected: "4"}, streamdeck_authenticated: false}}
    assert {:reply, {:error, %{reason: "unauthorized"}}, _} = StreamdeckChannel.handle_in("input", %{"kind" => "dial_turn", "index" => 1, "ticks" => -1}, socket)
    refute_received {:reorder, _, _}
  end

  test "unknown outcome appears in strip feedback and is never retried" do
    owner = self()

    put_endpoint_config(
      streamdeck_reorder_fun: fn id, at ->
        send(owner, {:reorder, id, at})
        {:error, :outcome_unknown}
      end
    )

    socket = joined_socket()
    :sys.get_state(socket.channel_pid)
    assert_push("frame", _initial, 2_000)
    ref = push(socket, "input", %{"kind" => "key_press", "index" => 0})
    assert_reply(ref, :ok, %{"view" => "ticket"}, 2_000)
    ref = push(socket, "input", %{"kind" => "dial_turn", "index" => 1, "ticks" => -1})
    :sys.get_state(socket.channel_pid)
    assert_reply(ref, :error, %{reason: "outcome_unknown"} = reply, 2_000)
    refute Map.has_key?(reply, :frame)
    frame = flush_frame(socket)
    assert_received {:reorder, "4", 2}
    refute_received {:reorder, _, _}
    assert hd(frame.strip).label == "outcome unknown"
    assert hd(frame.strip).svg =~ "outcome unknown"
    assert Enum.find(frame.keys, & &1).label =~ "Queued #4"
  end

  test "queue refusals render short explanations without writes" do
    for {model, reason, text} <- [
          {%{status: :running, queues: []}, "not_queued", "not in a queue"},
          {put_in(model(3), [:queues, Access.at(0), :kind], :build_order), "not_list", "plan order is fixed"},
          {%{status: :disabled, queues: []}, "disabled", "queue disabled"}
        ] do
      put_endpoint_config(streamdeck_build_queue_fun: fn -> model end)
      socket = %Phoenix.Socket{assigns: %{deck_nav: %Nav{selected: "4"}, streamdeck_authenticated: true}}
      assert {:reply, {:error, %{reason: ^reason} = reply}, updated} = StreamdeckChannel.handle_in("input", %{"kind" => "dial_turn", "index" => 1, "ticks" => -1}, socket)
      refute Map.has_key?(reply, :frame)
      assert updated.assigns.deck_toast == text
    end

    refute_received {:reorder, _, _}
  end

  test "unavailable queue positions preserve the authoritative Build backlog label" do
    for read <- [fn -> %{status: :disabled, queues: []} end, fn -> Map.put(model(3), :snapshot, %{carried_age_ms: 100}) end, fn -> raise "queue read failed" end] do
      put_endpoint_config(streamdeck_build_queue_fun: read)
      grid = StreamdeckProjection.grid()
      face = Enum.find(grid.agents, &(&1.identifier == "4"))
      assert face.queue_position == nil
      image = Render.key(face)
      assert image.label =~ "Queued #1"
      assert image.svg =~ "Queued #1"
    end
  end

  defp flush_frame(socket) do
    state = :sys.get_state(socket.channel_pid)
    send(socket.channel_pid, {:flush_fleet, state.assigns.fleet_flush})
    :sys.get_state(socket.channel_pid)
    assert_push("frame", frame, 2_000)
    frame
  end

  defp model(position) do
    %{
      status: :running,
      queues: [%{kind: :list, queue_id: "ops", set_rank: 0, name: "ops", progress: %{total: 0}, items: [%{number: 4, position: position} | Enum.map(1..3, &%{number: &1, position: &1 - 1})]}]
    }
  end
end
