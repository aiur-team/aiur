defmodule Aiur.DecisionProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.{
    Decision,
    DecisionAnswer,
    DecisionEnrichment,
    DecisionEvent,
    DecisionProjection,
    DecisionProvenance,
    DecisionRevision,
    DecisionValidation
  }

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

  defp answer(decision, overrides \\ %{}) do
    payload =
      Map.merge(
        %{
          "idempotency_key" => "operator-answer-1",
          "expected_version" => decision.version,
          "option_id" => "ship"
        },
        overrides
      )

    {:ok, answer} =
      DecisionAnswer.normalize(payload,
        decision_id: decision.decision_id,
        decision_version: decision.version,
        options: decision.options,
        actor: %{kind: :operator, id: "operator-1"},
        now: ~U[2026-07-12 10:01:00Z]
      )

    answer
  end

  defp event(type, decision, data, sequence) do
    {:ok, event} =
      DecisionEvent.new(type, decision.decision_id, decision.version, data,
        event_id: "evt-#{sequence}",
        run_id: "run-1",
        now: DateTime.add(~U[2026-07-12 10:00:00Z], sequence, :second)
      )

    event
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

  defp revision(decision, prior_answer, overrides \\ %{}) do
    now = ~U[2026-07-12 10:10:00Z]

    payload =
      Map.merge(
        %{
          "idempotency_key" => "revision-1",
          "expected_version" => decision.version,
          "expected_action_id" => prior_answer.action_id,
          "expected_revision_sequence" => 0,
          "custom_response" => "Hold the rollout",
          "rationale" => "New production evidence"
        },
        overrides
      )

    normalizer = fn answer_payload, _opts ->
      DecisionAnswer.normalize(answer_payload,
        decision_id: decision.decision_id,
        decision_version: decision.version,
        options: decision.options,
        actor: %{kind: :operator, id: "operator-1"},
        now: now
      )
    end

    {:ok, revision} =
      DecisionRevision.normalize(payload,
        decision_id: decision.decision_id,
        decision_version: decision.version,
        current_action_id: prior_answer.action_id,
        current_revision_sequence: 0,
        actor: %{kind: :operator, id: "operator-1"},
        now: now,
        answer_normalizer: normalizer
      )

    revision
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
      assert DecisionProjection.reduce([]) == %{current: %{}, history: %{}, audit_history: %{}}
    end

    test "lifecycle events keep decision and delivery state independent" do
      request =
        build_decision(
          %{
            "source_id" => "lifecycle-1",
            "options" => [%{"id" => "ship", "label" => "Ship it"}]
          },
          provenance: %{
            backend: "codex",
            requested_model: "gpt-5.6-terra",
            session_id: "thread-123",
            attempt_id: "attempt-456",
            source: "agent_runner"
          }
        )

      accepted = answer(request)

      events = [
        request,
        event(:answer_recorded, request, accepted, 1),
        event(
          :dispatch_queued,
          request,
          %{action_id: accepted.action_id, attempt_id: "attempt-1", queue_item_id: 17},
          2
        ),
        event(:delivered, request, %{action_id: accepted.action_id, attempt_id: "attempt-1", queue_item_id: 17}, 3),
        event(:acknowledged, request, %{action_id: accepted.action_id, actor: %{kind: :agent, id: "agent-1"}}, 4),
        event(:resolved, request, %{action_id: accepted.action_id, actor: %{kind: :agent, id: "agent-1"}}, 5)
      ]

      result = DecisionProjection.reduce(events)
      current = result.current[request.decision_id]

      assert current.answer == accepted
      assert current.decision_status == :resolved
      assert current.delivery_status == :delivered
      assert [%{attempt_id: "attempt-1", queue_item_id: 17, status: :delivered}] = current.dispatch_attempts
      assert current.acknowledgement.action_id == accepted.action_id
      assert current.resolution.action_id == accepted.action_id
      assert current.provenance.backend == "codex"
      assert current.provenance.session_id == "thread-123"
      assert length(result.audit_history[request.decision_id]) == 6
    end

    test "multiple dispatch attempts remain correlated to one immutable answer" do
      request =
        build_decision(%{
          "source_id" => "attempts-1",
          "options" => [%{"id" => "ship", "label" => "Ship it"}]
        })

      accepted = answer(request)

      events = [
        request,
        event(:answer_recorded, request, accepted, 1),
        event(
          :dispatch_queued,
          request,
          %{action_id: accepted.action_id, attempt_id: "attempt-1", queue_item_id: 17},
          2
        ),
        event(
          :failed,
          request,
          %{
            action_id: accepted.action_id,
            attempt_id: "attempt-1",
            queue_item_id: 17,
            reason_class: "agent_unavailable"
          },
          3
        ),
        event(
          :dispatch_queued,
          request,
          %{action_id: accepted.action_id, attempt_id: "attempt-2", queue_item_id: 18},
          4
        ),
        event(:restored, request, %{action_id: accepted.action_id, attempt_id: "attempt-2", queue_item_id: 18}, 5)
      ]

      current = DecisionProjection.reduce(events).current[request.decision_id]

      assert current.answer == accepted
      assert current.decision_status == :decided
      assert current.delivery_status == :queued

      assert Enum.map(current.dispatch_attempts, &{&1.attempt_id, &1.queue_item_id, &1.status}) == [
               {"attempt-1", 17, :failed},
               {"attempt-2", 18, :queued}
             ]
    end

    test "a later request enrichment preserves the accepted answer and attempts" do
      v1 =
        build_decision(%{
          "source_id" => "enrichment-1",
          "options" => [%{"id" => "ship", "label" => "Ship it"}]
        })

      accepted = answer(v1)

      v2 =
        %{v1 | version: 2, question: "Deploy after the final smoke test?", content_hash: String.duplicate("a", 64)}

      events = [
        v1,
        event(:answer_recorded, v1, accepted, 1),
        event(:dispatch_queued, v1, %{action_id: accepted.action_id, attempt_id: "attempt-1", queue_item_id: 17}, 2),
        v2
      ]

      result = DecisionProjection.reduce(events)
      current = result.current[v1.decision_id]

      assert current.version == 2
      assert current.answer == accepted
      assert current.answer.decision_version == 1
      assert [%{attempt_id: "attempt-1"}] = current.dispatch_attempts
      assert Enum.map(result.history[v1.decision_id], & &1.version) == [1, 2]
    end

    test "an attributed enrichment event advances request content and preserves lifecycle" do
      request =
        build_decision(%{
          "source_id" => "supervisor-enrichment",
          "options" => [%{"id" => "ship", "label" => "Ship it"}]
        })

      accepted = answer(request)
      answered = event(:answer_recorded, request, accepted, 1)

      queued =
        event(
          :dispatch_queued,
          request,
          %{action_id: accepted.action_id, attempt_id: "attempt-1", queue_item_id: 17},
          2
        )

      correction = revision(request, accepted)
      revised = event(:revision_recorded, request, correction, 3)

      current =
        DecisionProjection.reduce([request, answered, queued, revised]).current[request.decision_id]

      assert {:ok, enrichment} =
               DecisionEnrichment.normalize(
                 current,
                 %{"context" => %{"short_summary" => "Use the canonical path"}},
                 expected_version: 1,
                 actor: %{kind: :supervisor, id: "supervising-agent"},
                 now: ~U[2026-07-12 11:00:00Z]
               )

      assert {:ok, enriched_event} =
               DecisionEvent.new(
                 :enriched,
                 request.decision_id,
                 2,
                 %{
                   decision: enrichment.decision,
                   actor: enrichment.actor,
                   expected_version: enrichment.expected_version
                 },
                 event_id: 104,
                 run_id: "run-1",
                 now: ~U[2026-07-12 11:00:00Z]
               )

      raw = enriched_event |> DecisionEvent.to_json_safe() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, %DecisionEvent{type: :enriched}} = DecisionProjection.decode_record(raw)
      assert enriched_event.data.decision.answer == nil
      assert enriched_event.data.decision.active_action_id == nil
      assert enriched_event.data.decision.revisions == []
      assert enriched_event.data.decision.revision_outcomes == %{}

      result = DecisionProjection.reduce([request, answered, queued, revised, enriched_event])
      updated = result.current[request.decision_id]

      assert updated.version == 2
      assert updated.context.short_summary == "Use the canonical path"
      assert updated.answer == accepted
      assert updated.active_action_id == correction.action_id
      assert updated.revisions == [correction]
      assert [%{attempt_id: "attempt-1"}] = updated.dispatch_attempts
      assert Enum.map(result.history[request.decision_id], & &1.version) == [1, 2]
      assert List.last(result.audit_history[request.decision_id]).data.actor == enrichment.actor
    end

    test "typed enrichment events bind trusted provenance state against stripping" do
      request =
        build_decision(
          %{"source_id" => "rollback-provenance-enrichment"},
          provenance: %{backend: "codex", session_id: "thread-123", source: "agent_runner"}
        )

      assert {:ok, enrichment} =
               DecisionEnrichment.normalize(
                 request,
                 %{"context" => %{"short_summary" => "Keep the trusted context"}},
                 expected_version: 1,
                 actor: %{kind: :supervisor, id: "supervising-agent"},
                 now: ~U[2026-07-13 12:02:00Z]
               )

      assert {:ok, event} =
               DecisionEvent.new(
                 :enriched,
                 request.decision_id,
                 2,
                 %{decision: enrichment.decision, actor: enrichment.actor, expected_version: enrichment.expected_version},
                 event_id: 105,
                 run_id: "run-rollback-provenance-enrichment",
                 now: ~U[2026-07-13 12:03:00Z]
               )

      raw = DecisionEvent.to_json_safe(event)
      assert raw["schema_version"] == 1
      assert raw["event_id"] == "decision-provenance-v1:105"
      assert raw["data"]["provenance_state"] == "captured"
      assert is_binary(raw["data"]["provenance_hash"])
      assert {:ok, %DecisionEvent{data: %{decision: decoded}}} = DecisionProjection.decode_record(raw)
      assert decoded.provenance.backend == "codex"

      assert {:ok, %DecisionEvent{schema_version: 2, data: %{decision: versioned_decoded}}} =
               raw |> versioned_snapshot_raw(:enriched) |> DecisionProjection.decode_record()

      assert versioned_decoded.provenance == decoded.provenance

      assert {:ok, rollback_decoded} = rollback_reader_decode(raw, :enriched)
      assert rollback_decoded.provenance == nil

      tampered = put_in(raw, ["data", "decision", "provenance", "backend"], "forged")
      assert DecisionProjection.decode_record(tampered) == {:error, :provenance_hash_mismatch}

      tampered_binding_hash = put_in(raw, ["data", "provenance_hash"], String.duplicate("0", 64))
      assert DecisionProjection.decode_record(tampered_binding_hash) == {:error, :provenance_hash_mismatch}

      stripped =
        update_in(raw, ["data"], fn data ->
          data
          |> Map.delete("provenance_state")
          |> update_in(["decision"], &Map.delete(&1, "provenance"))
        end)

      assert DecisionProjection.decode_record(stripped) == {:error, :provenance_state_missing}

      stripped_with_captured_state = update_in(raw, ["data", "decision"], &Map.delete(&1, "provenance"))

      assert DecisionProjection.decode_record(stripped_with_captured_state) ==
               {:error, :provenance_missing}

      fully_stripped =
        update_in(raw, ["data"], fn data ->
          data
          |> Map.drop(["provenance_state", "provenance_hash"])
          |> update_in(["decision"], &Map.delete(&1, "provenance"))
        end)

      assert DecisionProjection.decode_record(fully_stripped) == {:error, :provenance_binding_missing}

      downgraded =
        update_in(raw, ["data"], fn data ->
          data
          |> Map.put("provenance_state", "unknown")
          |> update_in(["decision"], &Map.delete(&1, "provenance"))
        end)

      assert DecisionProjection.decode_record(downgraded) == {:error, :provenance_hash_mismatch}

      assert {:ok, %DecisionEvent{schema_version: 1, data: %{decision: legacy_decoded}}} =
               raw |> legacy_typed_snapshot_raw(:enriched) |> DecisionProjection.decode_record()

      assert legacy_decoded.provenance == decoded.provenance

      assert {:ok, %DecisionEvent{data: %{decision: legacy_unknown}}} =
               raw
               |> legacy_unknown_snapshot_raw(:enriched, "legacy-enriched-event-id")
               |> DecisionProjection.decode_record()

      assert legacy_unknown.provenance == nil
    end

    test "rejects an enrichment that changes captured provenance" do
      request =
        build_decision(
          %{"source_id" => "provenance-immutable"},
          provenance: %{backend: "codex", session_id: "thread-123", source: "agent_runner"}
        )

      tampered = %{
        request
        | version: 2,
          provenance: %{request.provenance | backend: "forged"}
      }

      assert {:ok, enrichment} =
               DecisionEvent.new(
                 :enriched,
                 request.decision_id,
                 2,
                 %{
                   decision: tampered,
                   actor: %{kind: :supervisor, id: "supervising-agent"},
                   expected_version: 1
                 },
                 event_id: 106,
                 run_id: "run-provenance-tampered",
                 now: ~U[2026-07-13 12:01:00Z]
               )

      assert {_, {:corrupt, 2, {:invalid_transition, :enrichment_forbidden_change}}} =
               DecisionProjection.reduce_checked([request, enrichment])
    end

    test "a revision preserves the original answer and advances the active action" do
      request =
        build_decision(%{
          "source_id" => "revision-1",
          "options" => [%{"id" => "ship", "label" => "Ship it"}]
        })

      original = answer(request)
      correction = revision(request, original)

      events = [
        request,
        event(:answer_recorded, request, original, 1),
        event(
          :dispatch_queued,
          request,
          %{action_id: original.action_id, attempt_id: "original:1", queue_item_id: 17},
          2
        ),
        event(:delivered, request, %{action_id: original.action_id, attempt_id: "original:1", queue_item_id: 17}, 3),
        event(:acknowledged, request, %{action_id: original.action_id, actor: %{kind: :agent, id: "agent-1"}}, 4),
        event(:resolved, request, %{action_id: original.action_id, actor: %{kind: :agent, id: "agent-1"}}, 5),
        event(:revision_recorded, request, correction, 6)
      ]

      current = DecisionProjection.reduce(events).current[request.decision_id]

      assert current.answer == original
      assert current.active_action_id == correction.action_id
      assert current.revision_sequence == 1
      assert current.revisions == [correction]
      assert current.revision_result == :recorded
      assert current.decision_status == :decided
      assert current.delivery_status == :pending
      assert current.acknowledgement == nil
      assert current.resolution == nil
      assert current.acknowledgements[original.action_id].action_id == original.action_id
      assert current.resolutions[original.action_id].action_id == original.action_id
      assert [%{action_id: original_action}] = current.dispatch_attempts
      assert original_action == original.action_id
    end

    test "revision dispatch and transport remain correlated without rewriting prior attempts" do
      request = build_decision(%{"source_id" => "revision-dispatch"})
      original = answer(request, %{"option_id" => nil, "custom_response" => "Proceed"})
      correction = revision(request, original)

      events = [
        request,
        event(:answer_recorded, request, original, 1),
        event(
          :dispatch_queued,
          request,
          %{action_id: original.action_id, attempt_id: "original:1", queue_item_id: 17},
          2
        ),
        event(:revision_recorded, request, correction, 3),
        event(
          :revision_dispatched,
          request,
          %{action_id: correction.action_id, attempt_id: "revision:1", queue_item_id: 18},
          4
        ),
        event(:delivered, request, %{action_id: correction.action_id, attempt_id: "revision:1", queue_item_id: 18}, 5)
      ]

      current = DecisionProjection.reduce(events).current[request.decision_id]

      assert current.answer == original
      assert current.revision_result == :dispatched
      assert current.delivery_status == :delivered

      assert Enum.map(current.dispatch_attempts, &{&1.action_id, &1.status}) == [
               {original.action_id, :queued},
               {correction.action_id, :delivered}
             ]
    end

    test "checked reduction rejects a lifecycle event with the wrong action" do
      request =
        build_decision(%{
          "source_id" => "bad-action",
          "options" => [%{"id" => "ship", "label" => "Ship it"}]
        })

      accepted = answer(request)
      invalid = event(:delivered, request, %{action_id: "act_wrong", attempt_id: "attempt-1", queue_item_id: 17}, 2)

      assert {projection, {:corrupt, 3, {:invalid_transition, :action_mismatch}}} =
               DecisionProjection.reduce_checked([request, event(:answer_recorded, request, accepted, 1), invalid])

      assert projection.current[request.decision_id].delivery_status == :pending
    end
  end

  describe "typed audit records" do
    test "decode rejects a lifecycle record whose content hash changed" do
      request =
        build_decision(%{
          "source_id" => "hash-1",
          "options" => [%{"id" => "ship", "label" => "Ship it"}]
        })

      accepted = answer(request)
      lifecycle = event(:answer_recorded, request, accepted, 1)

      raw = lifecycle |> DecisionEvent.to_json_safe() |> Map.put("run_id", "tampered-run")

      assert DecisionProjection.decode_record(raw) == {:error, :event_content_hash_mismatch}
    end

    test "decode rejects an unsupported lifecycle schema version" do
      request =
        build_decision(%{
          "source_id" => "schema-version-1",
          "options" => [%{"id" => "ship", "label" => "Ship it"}]
        })

      lifecycle = event(:answer_recorded, request, answer(request), 1)
      raw = lifecycle |> DecisionEvent.to_json_safe() |> Map.put("schema_version", 2)

      assert DecisionProjection.decode_record(raw) == {:error, {:schema_version, :unsupported}}
    end

    test "an OCC-1 record without a discriminator still decodes as a legacy Decision" do
      decision = build_decision(%{"source_id" => "legacy-1"})

      assert {:ok, %Decision{} = decoded} = DecisionProjection.decode_record(persisted_raw(decision))
      assert decoded.decision_id == decision.decision_id
      assert decoded.decision_status == :open
      assert decoded.delivery_status == :not_dispatched
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
