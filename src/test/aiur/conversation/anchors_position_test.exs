defmodule Aiur.Conversation.AnchorsPositionTest do
  use ExUnit.Case, async: true

  alias Aiur.Conversation.{Anchors, Entry, Session}

  defp time(seconds), do: DateTime.add(~U[2026-01-01 10:00:00Z], seconds)

  defp event(attrs \\ %{}) do
    Map.merge(%{event_id: 7, kind: "progress", topic: "ticket.1.agent.progress", conversation_id: "conv_test", observed_at: time(10), occurred_at: time(-100)}, attrs)
  end

  defp entry(pos, seconds, refs \\ %{}),
    do: %Entry{pos: pos, session_seq: 1, kind: "message", observed_at: DateTime.to_iso8601(time(seconds)), refs: refs}

  defp session(attrs \\ %{}),
    do: struct(Session, Map.merge(%{session_seq: 1, first_pos: 1, started_at: time(0)}, attrs))

  test "exact beats observed when the tool call entry exists and preserves JSON context" do
    entries = [entry(1, 2), entry(2, 5, %{tool_call_id: "call_1"}), entry(3, 9)]
    event = event(%{source_tool_call_id: "call_1", label: "Halfway", subject_ref: %{"head_sha" => "abc"}})
    assert {:ok, exact} = Anchors.exact(event, entries)
    assert {:ok, observed} = Anchors.position(event, entries, [session()])
    assert exact["pos"] == 2
    assert exact["precision"] == "exact"
    assert exact["placement"] == "at"
    assert exact["method"] == "tool_call"
    assert exact["v"] == 1
    assert exact["event"] == %{"event_id" => 7, "topic" => event.topic, "observed_at" => DateTime.to_iso8601(time(10)), "occurred_at" => DateTime.to_iso8601(time(-100))}
    assert exact["label"] == "Halfway"
    assert exact["subject_ref"] == %{"head_sha" => "abc"}
    assert Jason.decode!(Jason.encode!(exact)) == exact
    assert Anchors.strongest([observed, exact]) == [exact]
  end

  test "command_requested anchors via decision source rather than publication source" do
    entries = [entry(1, 2, %{tool_call_id: "publish"}), entry(2, 4, %{"tool_call_id" => "decision"})]
    event = event(%{kind: "command_requested", source_tool_call_id: "publish", decision_tool_call_id: "decision"})
    assert {:ok, anchor} = Anchors.exact(event, entries)
    assert anchor["pos"] == 2
    assert anchor["method"] == "decision_source"
    assert anchor["precision"] == "exact"
    assert Anchors.decision_source(event, entries) == {:ok, anchor}
    assert Anchors.exact(Map.delete(event, :decision_tool_call_id), entries) == :none
  end

  test "missing, empty and unmatched tool ids do not prove an exact anchor" do
    for id <- [nil, "", "absent"] do
      assert Anchors.exact(event(%{source_tool_call_id: id}), [entry(1, 1)]) == :none
      assert Anchors.decision_source(event(%{decision_tool_call_id: id}), [entry(1, 1)]) == :none
    end
  end

  test "observed selects greatest position at or before, including ties; deck membership is unchanged" do
    entries = [entry(5, 10), entry(2, 3), entry(6, 11), entry(4, 10)]
    assert {:ok, anchor} = Anchors.position(event(), entries, [session()])
    assert anchor["pos"] == 5
    assert anchor["placement"] == "after"
    assert anchor["precision"] == "observed"
    assert anchor["method"] == "observed_at"
    tied = %{timestamp: DateTime.to_iso8601(time(10))}

    assert [%{entries: []}, %{id: :event, entries: [^tied]}] =
             [%{id: :event, timestamp: tied.timestamp}] |> Anchors.with_origin([tied]) |> Anchors.at_or_before([tied])
  end

  test "event before first session, between sessions or after ended session is unanchored" do
    for sessions <- [[], [session(%{started_at: time(11)})], [session(%{ended_at: time(9)})], [session(%{ended_at: time(9)}), session(%{started_at: time(11)})]] do
      assert_unanchored(event(), [entry(1, 1)], sessions)
    end
  end

  test "session start and end are inclusive and missing earlier entries claim no position" do
    for sessions <- [[session(%{started_at: time(10)})], [session(%{ended_at: time(10)})]] do
      assert {:ok, anchor} = Anchors.position(event(), [entry(1, 10)], sessions)
      assert anchor["pos"] == 1
    end

    assert_unanchored(event(), [], [session()])
    assert_unanchored(event(), [entry(1, 11)], [session()])
  end

  test "event during a gap including endpoints is unanchored even when the gap row is later" do
    gap = %Entry{pos: 2, kind: "gap", observed_at: time(20), meta: %{"from" => DateTime.to_iso8601(time(8)), "to" => DateTime.to_iso8601(time(12))}}
    entries = [entry(1, 1), gap]
    for seconds <- [8, 10, 12], do: assert_unanchored(event(%{observed_at: time(seconds)}), entries, [session()])
    assert {:ok, after_gap} = Anchors.position(event(%{observed_at: time(21)}), entries, [session()])
    assert after_gap["pos"] == 1
    atom_gap = %{gap | meta: %{from: time(8), to: time(12)}}
    assert_unanchored(event(), [entry(1, 1), atom_gap], [session()])
  end

  test "nil or unusable observation time is unanchored regardless of provider time" do
    for observed_at <- [nil, "bad"], do: assert_unanchored(event(%{observed_at: observed_at, occurred_at: time(10)}), [entry(1, 1)], [session()])
  end

  test "anchor id has stable encoding and changes with each identity dimension" do
    {:ok, anchor} = Anchors.position(event(), [entry(1, 1)], [session()])
    expected = :crypto.hash(:sha256, ~s([7,"progress","conv_test","observed"])) |> Base.encode32(case: :lower, padding: false) |> binary_part(0, 26)
    assert anchor["anchor_id"] == "anc_" <> expected
    assert Anchors.anchor_id(Map.merge(anchor, %{"pos" => 99, "label" => "New label"})) == anchor["anchor_id"]

    for {key, value} <- [{"precision", "exact"}, {"kind", "push"}, {"conversation_id", "conv_other"}, {"event", %{"event_id" => 8}}] do
      refute Anchors.anchor_id(Map.put(anchor, key, value)) == anchor["anchor_id"]
    end
  end

  test "strongest implements the whole ladder with separate events, kinds and conversations" do
    {:ok, observed} = Anchors.position(event(), [entry(1, 1)], [session()])
    levels = for precision <- ~w(unanchored observed causal exact), do: Map.put(observed, "precision", precision)

    for count <- 1..4 do
      candidates = Enum.take(levels, count)
      assert Anchors.strongest(candidates) == [List.last(candidates)]
      assert Anchors.strongest(Enum.reverse(candidates)) == [List.last(candidates)]
    end

    exact = List.last(levels)
    other_event = put_in(observed, ["event", "event_id"], 8)
    other_kind = Map.put(observed, "kind", "push")
    other_conversation = Map.put(observed, "conversation_id", "conv_other")
    assert Anchors.strongest([observed, other_event, other_kind, other_conversation, exact]) == [exact, other_event, other_kind, other_conversation]
    assert Anchors.strongest([observed, Map.put(observed, "pos", 99)]) == [observed]
    assert Anchors.strongest([]) == []
  end

  defp assert_unanchored(event, entries, sessions) do
    assert {:ok, anchor} = Anchors.position(event, entries, sessions)
    assert anchor["precision"] == "unanchored"
    assert anchor["pos"] == nil
    assert anchor["placement"] == nil
    assert anchor["method"] == nil
  end
end
