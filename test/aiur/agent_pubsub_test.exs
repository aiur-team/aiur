defmodule Aiur.AgentPubSubTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentEvents, AgentPubSub}

  describe "transcript round-trip" do
    test "subscribers receive the broadcast event" do
      :ok = AgentPubSub.subscribe_agent("MT-99")
      event = AgentEvents.transcript_event(:user, "hi")

      :ok = AgentPubSub.broadcast_transcript("MT-99", event)

      assert_receive {:transcript_event, ^event}
    end

    test "subscriptions are scoped per identifier" do
      :ok = AgentPubSub.subscribe_agent("MT-99")
      :ok = AgentPubSub.broadcast_transcript("MT-OTHER", AgentEvents.transcript_event(:user, "hi"))

      refute_receive {:transcript_event, _}, 50
    end
  end

  describe "alert round-trip" do
    test "subscribers receive the alert on the agent topic" do
      :ok = AgentPubSub.subscribe_agent("MT-1")
      event = AgentEvents.alert_event("task.todo", "go!")

      :ok = AgentPubSub.broadcast_alert("MT-1", event)

      assert_receive {:alert, ^event}
    end
  end

  describe "running and status topics" do
    test "running_changed reaches subscribers" do
      :ok = AgentPubSub.subscribe_running()
      summaries = [AgentEvents.agent_summary("MT-1", :running, 0)]

      :ok = AgentPubSub.broadcast_running_change(summaries)

      assert_receive {:running_changed, ^summaries}
    end

    test "status_changed reaches subscribers" do
      :ok = AgentPubSub.subscribe_status()

      :ok = AgentPubSub.broadcast_status_change("MT-1", :paused)

      assert_receive {:status_changed, %{identifier: "MT-1", status: :paused}}
    end
  end

  describe "broadcast when PubSub registry is absent" do
    # Exercises the `Process.whereis(@pubsub) == nil` branch in
    # `do_broadcast/2`: producers must NOT crash if the PubSub
    # registry isn't running (early boot, test teardown, etc).
    test "swallows the broadcast and returns :ok" do
      pubsub_name = Aiur.PubSub
      pid = Process.whereis(pubsub_name)

      try do
        # Re-register the name to something innocuous so the lookup
        # returns nil for the real PubSub. We unregister the current
        # process to detach the original pid from the name.
        true = Process.unregister(pubsub_name)
        assert is_nil(Process.whereis(pubsub_name))

        assert :ok = AgentPubSub.broadcast_status_change("MT-1", :working)
      after
        if is_pid(pid) and Process.alive?(pid) and is_nil(Process.whereis(pubsub_name)) do
          Process.register(pid, pubsub_name)
        end
      end
    end
  end
end
