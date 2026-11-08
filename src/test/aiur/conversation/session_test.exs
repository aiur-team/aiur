defmodule Aiur.Conversation.SessionTest do
  use ExUnit.Case, async: true
  alias Aiur.Conversation.Session

  test "start and end records preserve identity and range" do
    session = %Session{
      session_seq: 2,
      harness: "codex",
      provider_session_id: "thread",
      aiur_attempt_id: "attempt",
      aiur_run_id: "run",
      first_pos: 7,
      started_at: "2026-10-01T00:00:00Z",
      start_reason: "spawn"
    }

    start = Session.start_line(session)
    assert start["type"] == "start"
    assert start["provider_session_id"] == "thread"
    refute Map.has_key?(start, "ended_at")
    assert {:ok, ^session} = Session.from_json(Jason.encode!(start))
    ending = Session.end_line(session, end_reason: "superseded", ended_at: "2026-10-01T00:01:00Z", last_pos: 9)
    assert ending == %{"v" => 1, "type" => "end", "session_seq" => 2, "end_reason" => "superseded", "ended_at" => "2026-10-01T00:01:00Z", "last_pos" => 9}
    assert {:ok, %Session{end_reason: "superseded", last_pos: 9}} = Session.from_json(ending)
    assert Session.start_line(session) == start
  end

  test "codec rejects unknown versions and invalid sequences" do
    valid = Session.start_line(%Session{session_seq: 1, harness: "codex", start_reason: "spawn", first_pos: 1})
    assert {:error, :invalid_session} = Session.from_json(Map.put(valid, "v", 2))
    assert {:error, :invalid_session} = Session.from_json(Map.put(valid, "session_seq", 0))
    assert {:error, :invalid_session} = Session.from_json(Map.delete(valid, "v"))
    assert {:error, :invalid_session} = Session.from_json("invalid")
  end
end
