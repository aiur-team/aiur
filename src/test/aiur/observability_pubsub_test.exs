defmodule Aiur.ObservabilityPubSubTest do
  use Aiur.TestSupport

  alias AiurWeb.ObservabilityPubSub

  test "subscribe and broadcast_update deliver dashboard updates" do
    pubsub = Aiur.ObservabilityPubSubTest.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub}, id: {Phoenix.PubSub, pubsub})

    assert :ok = ObservabilityPubSub.subscribe(pubsub)
    assert :ok = ObservabilityPubSub.broadcast_update(pubsub)
    assert_receive {:observability_updated, event_id}
    assert is_integer(event_id)
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    pubsub = Aiur.ObservabilityPubSubTest.UnavailablePubSub
    application_pubsub = Process.whereis(Aiur.PubSub)

    assert is_pid(application_pubsub)
    refute Process.whereis(pubsub)
    assert :ok = ObservabilityPubSub.broadcast_update(pubsub)
    refute_receive {:observability_updated, _event_id}
    assert Process.whereis(Aiur.PubSub) == application_pubsub
  end
end
