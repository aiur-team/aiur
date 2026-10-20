defmodule Aiur.DecisionProjectionDeliveryTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionAnswer, DecisionEnrichment, DecisionEvent, DecisionProjection, DecisionRevision, DecisionValidation}

  @ticket %{identifier: "979", title: "OCC-1", url: "https://github.com/its-everdred/aiur/issues/979"}

  @source %{agent_id: "agent-1", session_id: "session-1", event_id: "evt-1"}

  defp build_decision(payload_overrides, opts \\ []) do
    payload = Map.merge(%{"question" => "Deploy now?", "blocking" => true}, payload_overrides)
    {:ok, decision} = DecisionValidation.normalize(payload, Keyword.merge([ticket: @ticket, source: @source], opts))
    decision
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

  describe "reduce/1" do
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
end
