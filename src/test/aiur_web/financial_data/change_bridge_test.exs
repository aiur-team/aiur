defmodule AiurWeb.FinancialData.ChangeBridgeTest do
  use ExUnit.Case, async: true

  alias AiurWeb.FinancialData.ChangeBridge

  test "subscribes on boot and broadcasts a facade update when the aggregate changes" do
    parent = self()

    {:ok, bridge} =
      ChangeBridge.start_link(
        name: :"change_bridge_#{System.unique_integer([:positive])}",
        subscribe_fun: fn -> send(parent, :subscribed) end,
        provider_meter_subscribe_fun: fn -> :ok end,
        broadcast_fun: fn -> send(parent, :broadcast) end
      )

    assert_receive :subscribed

    send(bridge, {:usage_aggregate_changed, %{generation: 3}})
    assert_receive :broadcast
  end

  # A focused dashboard must reflect a fresh balance promptly: when the daemon
  # observes a provider meter (on focus, on cadence, on the boot baseline), the
  # open cards re-read the projection rather than holding their previous value.
  test "broadcasts a facade update when a provider meter is observed" do
    parent = self()

    {:ok, bridge} =
      ChangeBridge.start_link(
        name: :"change_bridge_#{System.unique_integer([:positive])}",
        subscribe_fun: fn -> :ok end,
        provider_meter_subscribe_fun: fn -> send(parent, :meter_subscribed) end,
        broadcast_fun: fn -> send(parent, :broadcast) end
      )

    assert_receive :meter_subscribed

    send(bridge, {:provider_meter_changed, %{provider: :deepseek}})
    assert_receive :broadcast
  end

  test "boots even when subscription raises and ignores unrelated messages" do
    parent = self()

    {:ok, bridge} =
      ChangeBridge.start_link(
        name: :"change_bridge_#{System.unique_integer([:positive])}",
        subscribe_fun: fn -> raise "pubsub not started" end,
        provider_meter_subscribe_fun: fn -> :ok end,
        broadcast_fun: fn -> send(parent, :broadcast) end
      )

    assert Process.alive?(bridge)

    send(bridge, :some_other_message)
    refute_receive :broadcast, 100
  end
end
