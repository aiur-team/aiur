defmodule Aiur.DecisionProjectionReductionTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionAnswer, DecisionEnrichment, DecisionEvent, DecisionProjection, DecisionRevision, DecisionValidation}

  @ticket %{identifier: "979", title: "OCC-1", url: "https://github.com/its-everdred/aiur/issues/979"}

  @source %{agent_id: "agent-1", session_id: "session-1", event_id: "evt-1"}

  defp build_decision(payload_overrides \\ %{}, opts \\ []) do
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
  end
end
