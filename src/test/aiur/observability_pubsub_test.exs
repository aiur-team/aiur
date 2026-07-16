defmodule Aiur.ObservabilityPubSubTest do
  use Aiur.TestSupport

  alias AiurWeb.ObservabilityPubSub

  test "subscribe and broadcast_update deliver dashboard updates" do
    assert :ok = ObservabilityPubSub.subscribe()
    assert :ok = ObservabilityPubSub.broadcast_update()
    assert_receive :observability_updated
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    pubsub_child_id = Phoenix.PubSub.Supervisor

    assert is_pid(Process.whereis(Aiur.PubSub))
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, pubsub_child_id)

    try do
      refute Process.whereis(Aiur.PubSub)
      assert :ok = ObservabilityPubSub.broadcast_update()
    after
      restart_pubsub(pubsub_child_id)
    end
  end

  defp restart_pubsub(pubsub_child_id) do
    assert {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, pubsub_child_id)
  catch
    :exit, :shutdown -> :ok
  end
end
