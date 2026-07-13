defmodule Aiur.DecisionPubSubTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionPubSub

  test "subscribe/0 and broadcast_changed/2 round-trip through the real PubSub server" do
    assert :ok = DecisionPubSub.subscribe()
    assert :ok = DecisionPubSub.broadcast_changed("dec_1", 3)
    assert_receive {:decision_changed, "dec_1", 3}, 500
  end

  test "broadcast_changed/2 is a no-op (never raises) without a subscriber" do
    assert :ok = DecisionPubSub.broadcast_changed("dec_2", 1)
  end
end
