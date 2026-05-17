defmodule SymphonyElixir.AgentPubSubTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentEvents, AgentPubSub}

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
end
