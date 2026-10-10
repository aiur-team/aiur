defmodule AiurWeb.RefreshRelayTest do
  use ExUnit.Case, async: true
  alias AiurWeb.RefreshRelay

  test "latest values survive a slow consumer, unrelated messages are ignored, owner exit cleans up" do
    parent = self()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, relay} = GenServer.start_link(RefreshRelay, {owner, fn -> send(parent, :subscribed) end, [:changed, :health]})
    assert_receive :subscribed, 1_000
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    monitor = Process.monitor(relay)
    for n <- 1..5_000, do: send(relay, {:changed, n})
    send(relay, {:health, :stale})
    send(relay, {:ignored, 1})
    send(relay, {})
    Process.sleep(550)
    assert {:messages, [{:coalesced_refresh, ^relay, messages}]} = Process.info(owner, :messages)
    assert Enum.sort(messages) == [{:changed, 5_000}, {:health, :stale}]
    for n <- 1..5_000, do: send(relay, {:changed, n})
    Process.sleep(550)
    state = :sys.get_state(relay)
    assert state.pending == %{changed: {:changed, 5_000}}
    assert state.waiting?
    assert state.timer == nil
    assert {:message_queue_len, 1} = Process.info(owner, :message_queue_len)
    GenServer.cast(relay, :ack)
    Process.sleep(550)
    assert {:message_queue_len, 2} = Process.info(owner, :message_queue_len)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^relay, :normal}, 1_000
  end

  test "disconnected sockets do not subscribe" do
    socket = %Phoenix.LiveView.Socket{}
    assert RefreshRelay.mount(socket, fn -> flunk("unexpected subscription") end, [:changed]) == socket
  end
end
