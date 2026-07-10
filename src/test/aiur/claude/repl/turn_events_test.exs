defmodule Aiur.Claude.Repl.TurnEventsTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.Repl.TurnEvents

  test "emit/3 merges event and timestamp over the details map" do
    collector = fn msg -> send(self(), {:msg, msg}) end

    TurnEvents.emit(collector, :turn_completed, %{session_id: "abc"})
    assert_receive {:msg, msg}

    assert msg.event == :turn_completed
    assert msg.session_id == "abc"
    assert %DateTime{} = msg.timestamp
  end

  test "emit/3 does not lose detail keys that match event name" do
    collector = fn msg -> send(self(), {:msg, msg}) end

    TurnEvents.emit(collector, :session_started, %{session_id: "s", thread_id: "t", turn_id: "u"})
    assert_receive {:msg, msg}

    assert msg.session_id == "s"
    assert msg.thread_id == "t"
    assert msg.turn_id == "u"
  end

  test "emit_transcript/2 wraps as %{event: :transcript, transcript_event:, timestamp:}" do
    collector = fn msg -> send(self(), {:msg, msg}) end
    inner = %{type: "assistant", text: "hello"}

    TurnEvents.emit_transcript(collector, inner)
    assert_receive {:msg, msg}

    assert msg.event == :transcript
    assert msg.transcript_event == inner
    assert %DateTime{} = msg.timestamp
    refute Map.has_key?(msg, :type)
  end
end
