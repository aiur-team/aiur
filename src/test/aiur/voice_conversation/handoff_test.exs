defmodule Aiur.VoiceConversation.HandoffTest do
  use Aiur.TestSupport

  alias Aiur.ExecutorEvents
  alias Aiur.ExecutorListener
  alias Aiur.ExecutorWakeInbox
  alias Aiur.ExecutorWakeProjection
  alias Aiur.VoiceConversation.Handoff

  @topic "executor.voice.session_ended"
  @inbox __MODULE__.Inbox
  @listener __MODULE__.Listener

  setup do
    previous = Application.get_env(:aiur, :executor_state_dir)
    root = Aiur.TestSupport.tmp_root!("voice-handoff")
    File.mkdir_p!(root)
    Application.put_env(:aiur, :executor_state_dir, Path.join(root, "executor"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :executor_state_dir, previous),
        else: Application.delete_env(:aiur, :executor_state_dir)
    end)

    %{root: root}
  end

  test "queues full transcript durably and wakes the Executor with its persisted event id" do
    start_supervised!({ExecutorWakeInbox, name: @inbox, debounce_ms: 0})

    listener =
      start_supervised!({ExecutorListener, name: @listener, inbox: @inbox, resubscribe_interval_ms: :infinity})

    transcript = [%{role: "user", text: "Check the build"}, %{role: "agent", text: "I will check it"}]
    assert {:ok, %{id: id, topic: @topic, at: at, status: "queued"}} = Handoff.deliver("session-1", transcript, :user_ended)
    assert {:ok, _, 0} = DateTime.from_iso8601(at)
    # The event send precedes this synchronous call, so delivery is complete.
    :sys.get_state(listener)
    send(@inbox, :flush)
    :sys.get_state(@inbox)
    assert {:ok, [wake]} = ExecutorWakeInbox.wait(0, @inbox)
    assert wake["event_id"] == id
    assert wake["topic"] == @topic
    assert wake["action"] == "session_ended"
    refute Map.has_key?(wake, "transcript")

    assert {:ok, [event]} = ExecutorEvents.replay([@topic], 0)
    assert event["id"] == id
    assert event["session_id"] == "session-1"
    assert event["source"] == "internal"
    assert event["transcript"] == Enum.map(transcript, fn turn -> %{"role" => turn.role, "text" => turn.text} end)
    assert event["summary"] == %{"status" => "unstructured"}
    assert event["ended_at"] == at
    assert event["reason"] == "user_ended"
    assert event["untrusted_fields"] == ["transcript", "summary"]
  end

  test "publish failure yields no successful queue receipt", %{root: root} do
    blocked = Path.join(root, "not-a-directory")
    File.write!(blocked, "blocked")
    Application.put_env(:aiur, :executor_state_dir, blocked)
    assert {:error, _reason} = Handoff.deliver("session-2", [], :disconnect)
  end

  test "voice projection preserves only identifiers for both live and journal events" do
    for event <- [
          %{id: 123, topic: @topic, transcript: "untrusted", summary: "untrusted"},
          %{"id" => 123, "topic" => @topic, "transcript" => "untrusted", "summary" => "untrusted"}
        ] do
      assert {:ok, record} = ExecutorWakeProjection.project(event)
      assert record["event_id"] == 123
      assert record["wake_id"] == 123
      assert record["topic_class"] == "executor.voice"
      refute Jason.encode!(record) =~ "untrusted"
    end

    assert :ignore = ExecutorWakeProjection.project(%{id: 124, topic: "executor.voice.unknown"})
  end
end
