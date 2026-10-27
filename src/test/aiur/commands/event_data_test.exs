defmodule Aiur.Commands.EventDataTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.EventData
  alias Aiur.DecisionEvent

  test "closed attribution data round trips through the event envelope and drops unknown keys" do
    raw = %{
      "requester" => %{"kind" => "executor", "executor_id" => "operator", "session_ref" => "session:1", "extra" => "discard"},
      "origin" => "executor_cli",
      "native" => %{"harness" => "codex", "native_ref" => "req-1", "hold" => "in_band", "question_ids" => ["q1"], "extra" => "discard"},
      "questions" => [%{"id" => "q1"}],
      "short_label" => "Choose scope",
      "extra" => "discard"
    }

    assert {:ok, event} = DecisionEvent.new(:request_attributed, "dec_1", 2, raw, event_id: "attrs", run_id: "run")
    encoded = DecisionEvent.to_json_safe(event)
    assert {:ok, ^event} = DecisionEvent.from_json_safe(encoded)
    assert event.data.requester == %{kind: :executor, executor_id: "operator", session_ref: "session:1", ticket: nil, harness: nil}
    assert event.data.native == %{harness: :codex, native_ref: "req-1", hold: :in_band, question_ids: ["q1"], call_id: nil, turn_id: nil}
    assert event.data.questions == [%{"id" => "q1"}]
    assert event.data.short_label == "Choose scope"
    assert encoded["data"]["origin"] == "executor_cli"
    refute Map.has_key?(encoded["data"], "extra")
    refute Map.has_key?(encoded["data"]["requester"], "extra")
    refute Map.has_key?(encoded["data"]["native"], "extra")
  end

  test "invalid enums, containers and bounded strings are rejected" do
    cases = [
      {%{origin: :other}, {:origin, :invalid_enum}},
      {%{origin: "never-an-atom"}, {:origin, :invalid_enum}},
      {%{requester: %{kind: :agent}}, {:requester_kind, :invalid_enum}},
      {%{requester: "executor"}, {:requester, :invalid_type}},
      {%{requester: %{kind: :worker, session_ref: String.duplicate("s", 257)}}, {:session_ref, :too_long}},
      {%{short_label: String.duplicate("x", 41)}, {:short_label, :too_long}},
      {%{short_label: "bad\x01label"}, {:short_label, :unsafe_characters}},
      {%{native: false}, {:native, :invalid_type}},
      {%{native: %{harness: :other}}, {:native_harness, :invalid_enum}},
      {%{native: %{harness: :claude, native_ref: "n", hold: :unknown}}, {:hold, :invalid_enum}},
      {%{native: %{harness: :claude, native_ref: "n", hold: :released, question_ids: false}}, {:question_ids, :invalid_type}},
      {%{native: %{harness: :claude, native_ref: "n", hold: :released, question_ids: [String.duplicate("q", 257)]}}, {:question_id, :too_long}},
      {%{questions: [false]}, {:questions, :invalid_type}}
    ]

    for {raw, reason} <- cases, do: assert(EventData.normalize(:request_attributed, raw) == {:error, reason})
  end

  test "missing optional attribution fields have explicit defaults" do
    assert {:ok, %{requester: nil, origin: nil, native: nil, questions: [], short_label: nil}} = EventData.normalize(:request_attributed, %{})
    assert {:error, {:event_data, :invalid}} = EventData.normalize(:request_attributed, [])
  end

  test "tampering attribution fails the durable envelope hash" do
    {:ok, event} = DecisionEvent.new(:request_attributed, "dec_1", 1, %{origin: :attention}, event_id: "attrs", run_id: "run")
    raw = put_in(DecisionEvent.to_json_safe(event), ["data", "origin"], "executor_cli")
    assert {:error, :event_content_hash_mismatch} = DecisionEvent.from_json_safe(raw)
  end
end
