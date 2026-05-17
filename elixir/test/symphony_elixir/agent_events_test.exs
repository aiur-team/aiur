defmodule SymphonyElixir.AgentEventsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentEvents

  describe "transcript_event/3" do
    test "builds a map with the supplied role and body and a default timestamp" do
      event = AgentEvents.transcript_event(:user, "hello")

      assert event.role == :user
      assert event.body == "hello"
      assert %DateTime{} = event.timestamp
      assert is_nil(event.msg_id)
    end

    test "honors a caller-supplied timestamp and msg_id" do
      ts = ~U[2026-01-01 00:00:00Z]
      event = AgentEvents.transcript_event(:assistant, "hi", timestamp: ts, msg_id: "abc-123")

      assert event.timestamp == ts
      assert event.msg_id == "abc-123"
    end
  end

  describe "alert_event/3" do
    test "builds the expected shape with defaults" do
      event = AgentEvents.alert_event("task.todo", "you have a new todo")

      assert event.name == "task.todo"
      assert event.message == "you have a new todo"
      assert is_nil(event.sound)
      assert %DateTime{} = event.timestamp
    end

    test "accepts a sound override" do
      event = AgentEvents.alert_event("task.done", "done", sound: "ding.wav")
      assert event.sound == "ding.wav"
    end
  end

  describe "agent_summary/3" do
    test "rejects negative alert counts at the guard" do
      assert_raise FunctionClauseError, fn ->
        AgentEvents.agent_summary("MT-1", :running, -1)
      end
    end

    test "builds a summary map" do
      assert AgentEvents.agent_summary("MT-1", :running, 0) == %{
               identifier: "MT-1",
               status: :running,
               alert_count: 0
             }
    end
  end

  describe "topic helpers" do
    test "agent_topic scopes by identifier" do
      assert AgentEvents.agent_topic("MT-1") == "agent:MT-1"
    end

    test "running_topic and status_topic are stable strings" do
      assert AgentEvents.running_topic() == "agents:running"
      assert AgentEvents.status_topic() == "agents:status"
    end
  end
end
