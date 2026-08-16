defmodule Aiur.AgentEventsTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentEvents

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

  describe "tool_call_body/2" do
    test "derives read/edit/write bodies from the file argument, matching the chat pane convention" do
      assert AgentEvents.tool_call_body("read_file", %{"file_path" => "lib/a.ex"}) == "read lib/a.ex"
      assert AgentEvents.tool_call_body("view", %{"path" => "lib/b.ex"}) == "read lib/b.ex"
      assert AgentEvents.tool_call_body("edit", %{"file_path" => "lib/c.ex"}) == "edit lib/c.ex"
      assert AgentEvents.tool_call_body("write_to_file", %{"file" => "lib/d.ex"}) == "write lib/d.ex"
    end

    test "carries the query for search tools instead of the tool name" do
      assert AgentEvents.tool_call_body("grep", %{"query" => "defmodule Aiur"}) == "defmodule Aiur"
      assert AgentEvents.tool_call_body("search", %{"glob" => "*.ex"}) == "*.ex"
    end

    test "keeps the tool name for a tool with no scalar argument" do
      assert AgentEvents.tool_call_body("sequential-thinking", %{"thought" => "think"}) == "sequential-thinking"
      assert AgentEvents.tool_call_body("bash", %{}) == "bash"
    end

    test "keeps the tool name for non-map arguments" do
      assert AgentEvents.tool_call_body("read_file", "lib/a.ex") == "read_file"
    end

    test "ignores an empty file argument and falls through" do
      assert AgentEvents.tool_call_body("read_file", %{"file_path" => ""}) == "read_file"
    end
  end

  describe "alert_event/3" do
    test "builds the expected shape with defaults" do
      event = AgentEvents.alert_event("task.todo", "you have a new todo")

      assert event.name == "task.todo"
      assert event.message == "you have a new todo"
      assert event.reason == "you have a new todo"
      assert event.severity == "info"
      assert event.needs_attention == false
      assert event.source_ticket_id == nil
      assert is_nil(event.sound)
      assert %DateTime{} = event.timestamp
    end

    test "accepts structured alert metadata overrides" do
      event =
        AgentEvents.alert_event("task.done", "done",
          sound: "ding.wav",
          reason: "review needed",
          severity: "warning",
          needs_attention: true,
          source_ticket_id: "42"
        )

      assert event.sound == "ding.wav"
      assert event.reason == "review needed"
      assert event.severity == "warning"
      assert event.needs_attention == true
      assert event.source_ticket_id == "42"
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

  describe "tag_name/1 and tag_display/1" do
    test "maps every role to its canonical short tag" do
      assert AgentEvents.tag_name(:assistant) == "agent"
      assert AgentEvents.tag_name(:user) == "user"
      assert AgentEvents.tag_name(:system) == "sys"
      assert AgentEvents.tag_name(:command) == "cmd"
      assert AgentEvents.tag_name(:alert) == "alert"
    end

    test "tag_display brackets the short tag" do
      assert AgentEvents.tag_display(:assistant) == "[agent]"
      assert AgentEvents.tag_display(:alert) == "[alert]"
    end
  end

  describe "state_emoji/1" do
    test "maps every known work_state (atom + string) to its canonical glyph" do
      assert AgentEvents.state_emoji(:working) == "🟢"
      assert AgentEvents.state_emoji("working") == "🟢"
      assert AgentEvents.state_emoji(:paused) == "⏸️"
      assert AgentEvents.state_emoji("paused") == "⏸️"
      assert AgentEvents.state_emoji(:error) == "🔴"
      assert AgentEvents.state_emoji("error") == "🔴"
      assert AgentEvents.state_emoji(:done) == "🏁"
      assert AgentEvents.state_emoji("done") == "🏁"
      assert AgentEvents.state_emoji(:completed) == "⏹️"
      assert AgentEvents.state_emoji("completed") == "⏹️"
      assert AgentEvents.state_emoji(:sleeping) == "💤"
      assert AgentEvents.state_emoji("sleeping") == "💤"
    end

    test "falls back to ⚫ for unknown / nil / queued-style values" do
      assert AgentEvents.state_emoji(nil) == "⚫"
      assert AgentEvents.state_emoji(:idle) == "⚫"
      assert AgentEvents.state_emoji("unknown") == "⚫"
    end
  end

  describe "streamdeck_bucket/1" do
    test "prioritizes attention, intervention, activity, and queued readiness states" do
      assert AgentEvents.streamdeck_bucket(%{open_decision_count: 1, streamdeck_source: :running}) == :alert
      assert AgentEvents.streamdeck_bucket(%{work_state: :error, streamdeck_source: :running}) == :stuck
      assert AgentEvents.streamdeck_bucket(%{waiting_reason: :unresponsive, streamdeck_source: :running}) == :stuck
      assert AgentEvents.streamdeck_bucket(%{waiting_reason: :tracker_unavailable, streamdeck_source: :queued}) == :stuck
      assert AgentEvents.streamdeck_bucket(%{streamdeck_source: :retrying}) == :stuck
      assert AgentEvents.streamdeck_bucket(%{work_state: :working, streamdeck_source: :running}) == :running
      assert AgentEvents.streamdeck_bucket(%{tracker_paused: true, streamdeck_source: :running}) == :paused

      for work_state <- [:paused, :sleeping, :done, :deactivated, :completed] do
        assert AgentEvents.streamdeck_bucket(%{work_state: work_state, streamdeck_source: :running}) == :paused
      end

      assert AgentEvents.streamdeck_bucket(%{streamdeck_source: :queued}) == :queued
    end

    test "uses the documented precedence when a row matches multiple buckets" do
      assert AgentEvents.streamdeck_bucket(%{open_decision_count: 1, work_state: :error, tracker_paused: true, streamdeck_source: :retrying}) == :alert
      assert AgentEvents.streamdeck_bucket(%{work_state: :error, tracker_paused: true, streamdeck_source: :running}) == :stuck
      assert AgentEvents.streamdeck_bucket(%{waiting_reason: :unresponsive, tracker_paused: true, streamdeck_source: :running}) == :stuck
    end
  end

  describe "agent_summary/4" do
    test "merges extras and filters nil values" do
      summary =
        AgentEvents.agent_summary("MT-2", :running, 0, %{
          tag: "agent:in-progress",
          title: "Demo",
          runtime_seconds: 30,
          turn_count: nil,
          work_state: :working
        })

      assert summary == %{
               identifier: "MT-2",
               status: :running,
               alert_count: 0,
               tag: "agent:in-progress",
               title: "Demo",
               runtime_seconds: 30,
               work_state: :working
             }

      refute Map.has_key?(summary, :turn_count)
    end
  end
end
