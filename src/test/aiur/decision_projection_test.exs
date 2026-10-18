defmodule Aiur.DecisionProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionEvent, DecisionProjection, DecisionProvenance, DecisionValidation}

  @ticket %{identifier: "979", title: "OCC-1", url: "https://github.com/its-everdred/aiur/issues/979"}

  @source %{agent_id: "agent-1", session_id: "session-1", event_id: "evt-1"}

  defp build_decision(payload_overrides \\ %{}, opts \\ []) do
    payload = Map.merge(%{"question" => "Deploy now?", "blocking" => true}, payload_overrides)
    {:ok, decision} = DecisionValidation.normalize(payload, Keyword.merge([ticket: @ticket, source: @source], opts))
    decision
  end

  # Simulates the exact bytes that would be on disk: encode through
  # to_json_safe/1, then Jason round-trip so every value is the plain
  # string-keyed map decode_record/1 actually receives from Journal.
  defp persisted_raw(decision) do
    decision |> DecisionProjection.to_json_safe() |> Jason.encode!() |> Jason.decode!()
  end

  # Schema-1 request and enrichment event hashes have to remain readable by
  # the rollback reader. Its primary hash did not include provenance or this
  # release's binding fields, so exercise that exact material against a record
  # produced by the new writer rather than converting it into an old record.
  defp rollback_reader_decode(raw, type) when type in [:requested, :enriched] do
    data = rollback_reader_data(raw["data"], type)

    with 1 <- raw["schema_version"],
         :ok <- verify_rollback_reader_hash(raw, type, data),
         {:ok, decision} <- DecisionProjection.decode_request_record(rollback_reader_snapshot(data, type)) do
      {:ok, decision}
    else
      other -> other
    end
  end

  defp rollback_reader_data(data, :requested),
    do: Map.drop(data, ["provenance", "provenance_hash", "provenance_state"])

  defp rollback_reader_data(data, :enriched) do
    data
    |> Map.drop(["provenance_hash", "provenance_state"])
    |> update_in(["decision"], &Map.delete(&1, "provenance"))
  end

  defp rollback_reader_snapshot(data, :requested), do: data

  defp rollback_reader_snapshot(data, :enriched), do: data["decision"]

  defp verify_rollback_reader_hash(raw, type, data) do
    actual_hash =
      DecisionValidation.content_hash(%{
        schema_version: 1,
        event_type: type,
        event_id: raw["event_id"],
        run_id: raw["run_id"],
        decision_id: raw["decision_id"],
        decision_version: raw["decision_version"],
        occurred_at: raw["occurred_at"],
        data: data
      })

    if actual_hash == raw["content_hash"], do: :ok, else: {:error, :event_content_hash_mismatch}
  end

  defp legacy_typed_snapshot_raw(raw, type) when type in [:requested, :enriched] do
    event_id = "legacy-#{type}-event-id"

    provenance =
      case type do
        :requested -> raw["data"]["provenance"]
        :enriched -> raw["data"]["decision"]["provenance"]
      end

    provenance_hash =
      DecisionValidation.content_hash(%{
        schema_version: 1,
        event_type: type,
        event_id: event_id,
        run_id: raw["run_id"],
        decision_id: raw["decision_id"],
        decision_version: raw["decision_version"],
        occurred_at: raw["occurred_at"],
        provenance: provenance
      })

    data =
      raw["data"]
      |> Map.delete("provenance_state")
      |> Map.put("provenance_hash", provenance_hash)

    hash_data =
      case type do
        :requested -> Map.drop(data, ["provenance", "provenance_hash"])
        :enriched -> data |> Map.delete("provenance_hash") |> update_in(["decision"], &Map.delete(&1, "provenance"))
      end

    content_hash =
      DecisionValidation.content_hash(%{
        schema_version: 1,
        event_type: type,
        event_id: event_id,
        run_id: raw["run_id"],
        decision_id: raw["decision_id"],
        decision_version: raw["decision_version"],
        occurred_at: raw["occurred_at"],
        data: hash_data
      })

    raw
    |> Map.put("schema_version", 1)
    |> Map.put("event_id", event_id)
    |> Map.put("data", data)
    |> Map.put("content_hash", content_hash)
  end

  defp legacy_unknown_snapshot_raw(raw, type, event_id) when type in [:requested, :enriched] do
    data = rollback_reader_data(raw["data"], type)

    content_hash =
      DecisionValidation.content_hash(%{
        schema_version: 1,
        event_type: type,
        event_id: event_id,
        run_id: raw["run_id"],
        decision_id: raw["decision_id"],
        decision_version: raw["decision_version"],
        occurred_at: raw["occurred_at"],
        data: data
      })

    raw
    |> Map.put("event_id", event_id)
    |> Map.put("data", data)
    |> Map.put("content_hash", content_hash)
  end

  defp versioned_snapshot_raw(raw, type) when type in [:requested, :enriched] do
    event_id = "pre-marker-schema-2-#{type}"
    data = Map.delete(raw["data"], "provenance_hash")

    content_hash =
      DecisionValidation.content_hash(%{
        schema_version: 2,
        event_type: type,
        event_id: event_id,
        run_id: raw["run_id"],
        decision_id: raw["decision_id"],
        decision_version: raw["decision_version"],
        occurred_at: raw["occurred_at"],
        data: data
      })

    raw
    |> Map.put("schema_version", 2)
    |> Map.put("event_id", event_id)
    |> Map.put("data", data)
    |> Map.put("content_hash", content_hash)
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
      assert decoded.authority == :supervisor_allowed
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

    test "legacy-attention provenance survives the round trip" do
      legacy_attention = %{
        slug: "scope-question",
        topic: "ticket.979.agent.attention.scope-question"
      }

      decision =
        build_decision(
          %{"source_id" => "legacy_attention:scope-question"},
          legacy_attention: legacy_attention
        )

      assert {:ok, decoded} = decision |> persisted_raw() |> DecisionProjection.decode_record()
      assert decoded.legacy_attention == legacy_attention
      assert decoded.content_hash == decision.content_hash
    end

    test "typed request events bind trusted provenance state against stripping" do
      provenance = %{
        agent_family: "codex",
        backend: "codex",
        requested_model: "gpt-5.6-terra",
        session_id: "thread-123",
        attempt_id: "attempt-456",
        source: "agent_runner"
      }

      decision = build_decision(%{"source_id" => "trusted-provenance"}, provenance: provenance)

      forged_legacy =
        build_decision(%{"source_id" => "legacy-forged-provenance"})
        |> persisted_raw()
        |> Map.put("provenance", DecisionProvenance.to_json_safe(decision.provenance))

      assert {:ok, decoded_legacy} = DecisionProjection.decode_record(forged_legacy)
      assert decoded_legacy.provenance == nil

      assert {:ok, request_event} =
               DecisionEvent.new(:requested, decision.decision_id, decision.version, decision,
                 event_id: 101,
                 run_id: "run-provenance",
                 now: ~U[2026-07-13 12:01:00Z]
               )

      raw = DecisionEvent.to_json_safe(request_event)
      assert raw["schema_version"] == 1
      assert raw["event_id"] == "decision-provenance-v1:101"
      assert raw["data"]["provenance_state"] == "captured"
      assert is_binary(raw["data"]["provenance_hash"])

      assert DecisionEvent.new(:requested, decision.decision_id, decision.version, decision,
               event_id: "pre-marker-request-event-id",
               run_id: "run-provenance",
               now: ~U[2026-07-13 12:01:00Z]
             ) == {:error, {:event_id, :snapshot_marker_required}}

      assert {:ok, %DecisionEvent{data: decoded}} = DecisionProjection.decode_record(raw)
      assert decoded.provenance.backend == "codex"
      assert decoded.provenance.session_id == "thread-123"

      assert {:ok, %DecisionEvent{schema_version: 2, data: versioned_decoded}} =
               raw |> versioned_snapshot_raw(:requested) |> DecisionProjection.decode_record()

      assert versioned_decoded.provenance == decoded.provenance

      assert {:ok, rollback_decoded} = rollback_reader_decode(raw, :requested)
      assert rollback_decoded.provenance == nil

      assert {:ok, %DecisionEvent{schema_version: 1, data: legacy_decoded}} =
               raw |> legacy_typed_snapshot_raw(:requested) |> DecisionProjection.decode_record()

      assert legacy_decoded.provenance == decoded.provenance

      for event_id <- [101, "legacy-request-event-id"] do
        assert {:ok, %DecisionEvent{data: legacy_unknown}} =
                 raw |> legacy_unknown_snapshot_raw(:requested, event_id) |> DecisionProjection.decode_record()

        assert legacy_unknown.provenance == nil
      end

      tampered =
        raw
        |> put_in(["data", "provenance", "backend"], "forged")

      assert DecisionProjection.decode_record(tampered) == {:error, :provenance_hash_mismatch}

      tampered_binding_hash = put_in(raw, ["data", "provenance_hash"], String.duplicate("0", 64))
      assert DecisionProjection.decode_record(tampered_binding_hash) == {:error, :provenance_hash_mismatch}

      stripped =
        update_in(raw, ["data"], fn data ->
          data
          |> Map.delete("provenance")
          |> Map.delete("provenance_state")
        end)

      assert DecisionProjection.decode_record(stripped) == {:error, :provenance_state_missing}

      stripped_with_captured_state = update_in(raw, ["data"], &Map.delete(&1, "provenance"))

      assert DecisionProjection.decode_record(stripped_with_captured_state) ==
               {:error, :provenance_missing}

      fully_stripped =
        update_in(raw, ["data"], &Map.drop(&1, ["provenance", "provenance_state", "provenance_hash"]))

      assert DecisionProjection.decode_record(fully_stripped) == {:error, :provenance_binding_missing}

      downgraded =
        update_in(raw, ["data"], fn data ->
          data
          |> Map.delete("provenance")
          |> Map.put("provenance_state", "unknown")
        end)

      assert DecisionProjection.decode_record(downgraded) == {:error, :provenance_hash_mismatch}

      malformed_marker = Map.put(raw, "event_id", "decision-provenance-v1:001")
      assert DecisionProjection.decode_record(malformed_marker) == {:error, :invalid_provenance_event_id}

      unknown = build_decision(%{"source_id" => "typed-unknown-provenance"})

      assert {:ok, unknown_event} =
               DecisionEvent.new(:requested, unknown.decision_id, unknown.version, unknown,
                 event_id: 102,
                 run_id: "run-unknown-provenance",
                 now: ~U[2026-07-13 12:02:00Z]
               )

      unknown_raw = DecisionEvent.to_json_safe(unknown_event)
      assert unknown_raw["data"]["provenance_state"] == "unknown"
      assert {:ok, %DecisionEvent{data: %{provenance: nil}}} = DecisionProjection.decode_record(unknown_raw)
    end

    test "records written before legacy provenance existed keep their content hash" do
      decision = build_decision(%{"source_id" => "pre-occ-2"})
      raw = persisted_raw(decision)

      refute Map.has_key?(raw, "legacy_attention")
      assert {:ok, decoded} = DecisionProjection.decode_record(raw)
      assert decoded.legacy_attention == nil
      assert decoded.content_hash == decision.content_hash
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
end
