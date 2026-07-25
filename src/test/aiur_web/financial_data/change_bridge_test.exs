defmodule AiurWeb.FinancialData.ChangeBridgeTest do
  use ExUnit.Case, async: true

  alias AiurWeb.FinancialData.ChangeBridge

  test "subscribes on boot and broadcasts a facade update when the aggregate changes" do
    parent = self()

    {:ok, bridge} =
      ChangeBridge.start_link(
        name: :"change_bridge_#{System.unique_integer([:positive])}",
        subscribe_fun: fn -> send(parent, :subscribed) end,
        broadcast_fun: fn -> send(parent, :broadcast) end
      )

    assert_receive :subscribed

    send(bridge, {:usage_aggregate_changed, %{generation: 3}})
    assert_receive :broadcast
  end

  test "boots even when subscription raises and ignores unrelated messages" do
    parent = self()

    {:ok, bridge} =
      ChangeBridge.start_link(
        name: :"change_bridge_#{System.unique_integer([:positive])}",
        subscribe_fun: fn -> raise "pubsub not started" end,
        broadcast_fun: fn -> send(parent, :broadcast) end
      )

    assert Process.alive?(bridge)

    send(bridge, :some_other_message)
    refute_receive :broadcast, 100
  end
end
