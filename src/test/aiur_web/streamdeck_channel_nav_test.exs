defmodule AiurWeb.StreamdeckChannelNavTest do
  use AiurWeb.StreamdeckChannelCase

  test "input state belongs to each connection" do
    first = joined_socket()
    second = joined_socket()
    ref = push(first, "input", %{"kind" => "dial_press", "index" => 3})
    assert_reply(ref, :ok, %{"view" => "feature", "page" => 0})
    ref = push(second, "input", %{"kind" => "dial_press", "index" => 0})
    assert_reply(ref, :ok, %{"view" => "ticket", "page" => 0})
    ref = push(first, "input", %{"kind" => "dial_press", "index" => 0})
    assert_reply(ref, :ok, %{"view" => "feature", "page" => 0})
  end

  test "keys resolve on the server and priority effects follow selection" do
    put_endpoint_config(
      streamdeck_build_queue_fun: fn -> %{status: :disabled} end,
      streamdeck_snapshot_fun: fn ->
        %{running: [AgentEvents.agent_summary("AIUR-1", :running, 0, %{title: "Navigation"})], retrying: [], idle: []}
      end
    )

    socket = joined_socket()
    ref = push(socket, "input", %{"kind" => "key_press", "index" => 0, "target" => "forged"})
    assert_reply(ref, :ok, %{"view" => "ticket", "page" => 0})
    state = :sys.get_state(socket.channel_pid)
    assert state.assigns.deck_effects == [{:open_ticket, "AIUR-1"}]
    ref = push(socket, "input", %{"kind" => "dial_turn", "index" => 1, "ticks" => -2})
    assert_reply(ref, :error, %{reason: "disabled"})
    assert :sys.get_state(socket.channel_pid).assigns.deck_effects == [{:priority, "AIUR-1", :up, 2}]
  end

  test "invalid raw inputs are refused without changing navigation" do
    socket = joined_socket()

    for input <- [%{"kind" => "bogus", "index" => 0}, %{"kind" => "key_press", "index" => 8}, %{"kind" => "dial_press", "index" => 4}, %{"kind" => "dial_turn", "index" => 0, "ticks" => -33}] do
      ref = push(socket, "input", input)
      assert_reply(ref, :error, %{reason: "invalid_input"})
    end

    ref = push(socket, "input", %{"kind" => "dial_press", "index" => 0})
    assert_reply(ref, :ok, %{"view" => "ticket", "page" => 0})
  end
end
