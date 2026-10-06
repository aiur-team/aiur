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
        host_meter_subscribe_fun: fn -> :ok end,
        broadcast_fun: fn -> send(parent, :broadcast) end
      )

    assert_receive :subscribed, 1000

    send(bridge, {:usage_aggregate_changed, %{generation: 3}})
    assert_receive :broadcast, 1000
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
        host_meter_subscribe_fun: fn -> :ok end,
        broadcast_fun: fn -> send(parent, :broadcast) end
      )

    assert_receive :meter_subscribed, 1000

    send(bridge, {:provider_meter_changed, %{provider: :deepseek}})
    assert_receive :broadcast, 1000
  end

  test "host meter invalidation reaches the protected facade without observation data" do
    parent = self()

    {:ok, bridge} =
      ChangeBridge.start_link(
        name: nil,
        subscribe_fun: fn -> :ok end,
        provider_meter_subscribe_fun: fn -> :ok end,
        host_meter_subscribe_fun: fn -> send(parent, :host_subscribed) end,
        broadcast_fun: fn -> send(parent, :host_refresh) end
      )

    assert_receive :host_subscribed, 1000
    send(bridge, {:host_meter_changed, :muse})
    assert_receive :host_refresh, 1000
  end

  test "boots even when subscription raises and ignores unrelated messages" do
    parent = self()

    {:ok, bridge} =
      ChangeBridge.start_link(
        name: :"change_bridge_#{System.unique_integer([:positive])}",
        subscribe_fun: fn -> raise "pubsub not started" end,
        provider_meter_subscribe_fun: fn -> :ok end,
        host_meter_subscribe_fun: fn -> :ok end,
        broadcast_fun: fn -> send(parent, :broadcast) end
      )

    assert Process.alive?(bridge)

    send(bridge, :some_other_message)
    :sys.get_state(bridge)
    refute_received :broadcast
  end
end
