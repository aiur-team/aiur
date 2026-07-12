defmodule Aiur.DecisionProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.{
    Decision,
    DecisionAnswer,
    DecisionEnrichment,
    DecisionEvent,
    DecisionProjection,
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
        actor: %{kind: :supervisor, id: "supervisor-1"},
        now: now
      )
    end

    {:ok, revision} =
      DecisionRevision.normalize(payload,
        decision_id: decision.decision_id,
        decision_version: decision.version,
        current_action_id: prior_answer.action_id,
        current_revision_sequence: 0,
        actor: %{kind: :supervisor, id: "supervisor-1"},
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
        build_decision(%{
          "source_id" => "lifecycle-1",
          "options" => [%{"id" => "ship", "label" => "Ship it"}]
        })

      accepted = answer(request)

      events = [
        request,
        event(:answer_recorded, request, accepted, 1),
        event(:dispatch_queued, request, %{action_id: accepted.action_id, attempt_id: "attempt-1", queue_item_id: 17}, 2),
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
        event(:dispatch_queued, request, %{action_id: accepted.action_id, attempt_id: "attempt-1", queue_item_id: 17}, 2),
        event(:failed, request, %{action_id: accepted.action_id, attempt_id: "attempt-1", queue_item_id: 17, reason_class: "agent_unavailable"}, 3),
        event(:dispatch_queued, request, %{action_id: accepted.action_id, attempt_id: "attempt-2", queue_item_id: 18}, 4),
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

      current = DecisionProjection.reduce([request, answered, queued]).current[request.decision_id]

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
                 event_id: "evt-3",
                 run_id: "run-1",
                 now: ~U[2026-07-12 11:00:00Z]
               )

      raw = enriched_event |> DecisionEvent.to_json_safe() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, %DecisionEvent{type: :enriched}} = DecisionProjection.decode_record(raw)

      result = DecisionProjection.reduce([request, answered, queued, enriched_event])
      updated = result.current[request.decision_id]

      assert updated.version == 2
      assert updated.context.short_summary == "Use the canonical path"
      assert updated.answer == accepted
      assert [%{attempt_id: "attempt-1"}] = updated.dispatch_attempts
      assert Enum.map(result.history[request.decision_id], & &1.version) == [1, 2]
      assert List.last(result.audit_history[request.decision_id]).data.actor == enrichment.actor
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
        event(:dispatch_queued, request, %{action_id: original.action_id, attempt_id: "original:1", queue_item_id: 17}, 2),
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
        event(:dispatch_queued, request, %{action_id: original.action_id, attempt_id: "original:1", queue_item_id: 17}, 2),
        event(:revision_recorded, request, correction, 3),
        event(:revision_dispatched, request, %{action_id: correction.action_id, attempt_id: "revision:1", queue_item_id: 18}, 4),
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
