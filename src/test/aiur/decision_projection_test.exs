defmodule Aiur.DecisionProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.{Decision, DecisionProjection, DecisionValidation}

  @ticket %{identifier: "979", title: "OCC-1", url: "https://github.com/its-everdred/aiur/issues/979"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: "evt-1"}

  defp build_decision(payload_overrides \\ %{}, opts \\ []) do
    payload = Map.merge(%{"question" => "Deploy now?", "blocking" => true}, payload_overrides)
    {:ok, decision} = DecisionValidation.normalize(payload, Keyword.merge([ticket: @ticket, source: @source], opts))
    decision
  end

  # Simulates the exact bytes that would be on disk: encode through
  # to_json_safe/1, then Jason round-trip so every value is the plain
  # string-keyed map decode_record/1 actually receives from DecisionLog.
  defp persisted_raw(decision) do
    decision |> DecisionProjection.to_json_safe() |> Jason.encode!() |> Jason.decode!()
  end

  describe "decode_record/1 happy path" do
    test "a persisted record decodes back to an equivalent Decision" do
      decision = build_decision()
      raw = persisted_raw(decision)

      assert {:ok, decoded} = DecisionProjection.decode_record(raw)
      assert decoded.decision_id == decision.decision_id
      assert decoded.version == decision.version
      assert decoded.question == decision.question
      assert decoded.content_hash == decision.content_hash
      assert decoded.ticket.identifier == "979"
      assert decoded.authority == :human_required
    end

    test "a later version and full option/recommendation content survive the round trip" do
      decision =
        build_decision(%{
          "options" => [%{"id" => "a", "label" => "Option A"}],
          "recommendation" => %{"option_id" => "a", "reason" => "simplest"},
          "source_id" => "retry-1"
        })

      raw = persisted_raw(decision) |> Map.put("version", 3)

      assert {:ok, decoded} = DecisionProjection.decode_record(raw)
      assert decoded.version == 3
      assert decoded.recommendation == %{option_id: "a", reason: "simplest"}
    end
  end

  describe "decode_record/1 corruption" do
    test "a tampered content field changes the hash and is rejected" do
      decision = build_decision()
      raw = persisted_raw(decision) |> Map.put("question", "Deploy NOW immediately?")

      assert DecisionProjection.decode_record(raw) == {:error, :content_hash_mismatch}
    end

    test "a missing envelope field fails closed" do
      decision = build_decision()
      raw = persisted_raw(decision) |> Map.delete("decision_id")

      assert DecisionProjection.decode_record(raw) == {:error, {:decision_id, :missing_or_invalid}}
    end

    test "a semantically invalid content field fails closed even though the record parses as JSON" do
      decision = build_decision()
      raw = persisted_raw(decision) |> Map.put("authority", "not_a_real_authority")

      assert {:error, {:decision_invalid, {:authority, :invalid_enum}}} = DecisionProjection.decode_record(raw)
    end

    test "a non-map input is rejected" do
      assert DecisionProjection.decode_record("not a map") == {:error, :not_a_map}
    end
  end

  describe "reduce/1" do
    test "groups by decision_id, current is the highest version, history preserves order" do
      base = build_decision(%{"source_id" => "retry-1"})
      v1 = base
      v2 = %{base | version: 2, question: "Deploy now, revised?"}
      v3 = %{base | version: 3, question: "Deploy now, final?"}

      other = build_decision(%{"question" => "Different ticket entirely?"}, ticket: %{identifier: "111"})

      result = DecisionProjection.reduce([v1, v2, v3, other])

      assert result.current[base.decision_id].version == 3
      assert result.current[base.decision_id].question == "Deploy now, final?"
      assert Enum.map(result.history[base.decision_id], & &1.version) == [1, 2, 3]
      assert result.current[other.decision_id].decision_id == other.decision_id
    end

    test "an out-of-order (stale) version never becomes current" do
      base = build_decision()
      v1 = base
      v2 = %{base | version: 2}

      result = DecisionProjection.reduce([v2, v1])

      assert result.current[base.decision_id].version == 2
      assert Enum.map(result.history[base.decision_id], & &1.version) == [2, 1]
    end

    test "an empty list reduces to empty current and history" do
      assert DecisionProjection.reduce([]) == %{current: %{}, history: %{}}
    end
  end

  describe "serialize_current/1" do
    test "produces the schema-versioned decisions list" do
      decision = build_decision()
      serialized = DecisionProjection.serialize_current(%{decision.decision_id => decision})

      assert serialized["schema_version"] == Decision.schema_version()
      assert [entry] = serialized["decisions"]
      assert entry["decision_id"] == decision.decision_id
      assert entry["authority"] == "human_required"
    end
  end
end
