defmodule Aiur.DecisionEnrichmentTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionAnswer, DecisionEnrichment, DecisionValidation}

  @actor %{kind: :supervisor, id: "supervising-agent"}
  @ticket %{identifier: "984", title: "OCC-7", url: "https://github.com/its-everdred/aiur/issues/984"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: "request-1"}
  @now ~U[2026-07-12 12:00:00Z]

  test "normalizes a narrow patch while preserving immutable Decision identity and policy fields" do
    current = current_decision()

    patch = %{
      "context" => %{"short_summary" => "A sharper summary"},
      "options" => [
        %{
          "id" => "a",
          "label" => "Option A",
          "description" => "Use the canonical store",
          "benefits" => "One audit",
          "drawbacks" => nil,
          "risk" => "Low"
        }
      ],
      "recommendation" => %{"option_id" => "a", "reason" => "Preserves ownership"},
      "consequence_of_delay" => "The agent stays blocked.",
      "artifacts" => ["https://github.com/its-everdred/aiur/issues/984"]
    }

    assert {:ok, enrichment} = normalize(current, patch)

    assert enrichment.expected_version == 3
    assert enrichment.actor == @actor
    assert enrichment.changed

    decision = enrichment.decision
    assert decision.decision_id == current.decision_id
    assert decision.version == 4
    assert decision.ticket == current.ticket
    assert decision.source == current.source
    assert decision.created_at == current.created_at
    assert decision.question == current.question
    assert decision.authority == current.authority
    assert decision.kind == current.kind
    assert decision.reversibility == current.reversibility
    assert decision.context.long_context_markdown == current.context.long_context_markdown
    assert decision.context.short_summary == "A sharper summary"
    assert decision.recommendation == %{option_id: "a", reason: "Preserves ownership"}
  end

  test "rejects every immutable, policy, correlation, and actor field" do
    current = current_decision()

    forbidden_fields = ~w(
      actor authority blocking content_hash created_at decision_id kind question
      reversibility schema_version source source_created_at source_id ticket urgency version
    )

    for field <- forbidden_fields do
      assert {:error, {:enrichment_invalid, {:forbidden_fields, [^field]}}} =
               normalize(current, %{field => "attempted replacement"})
    end
  end

  test "rejects unknown or ambiguous fields at every supported nested boundary" do
    current = current_decision()

    assert {:error, {:enrichment_invalid, {:unknown_fields, :enrichment, ["mystery"]}}} =
             normalize(current, %{"mystery" => true})

    assert {:error, {:enrichment_invalid, {:unknown_fields, :context, ["authority"]}}} =
             normalize(current, %{"context" => %{"authority" => "supervisor_preferred"}})

    assert {:error, {:enrichment_invalid, {:unknown_fields, :option, ["actor"]}}} =
             normalize(current, %{
               "options" => [%{"id" => "a", "label" => "A", "actor" => "human"}]
             })

    assert {:error, {:enrichment_invalid, {:duplicate_fields, ["context"]}}} =
             normalize(current, %{
               "context" => %{"short_summary" => "one"},
               context: %{short_summary: "two"}
             })
  end

  test "requires current optimistic correlation and the fixed trusted actor" do
    current = current_decision()

    assert {:error, {:enrichment_invalid, {:stale_version, 2, 3}}} =
             normalize(current, %{"context" => %{"short_summary" => "stale"}}, expected_version: 2)

    assert {:error, {:enrichment_invalid, {:expected_version, :invalid}}} =
             normalize(current, %{"context" => %{"short_summary" => "bad"}}, expected_version: "3")

    assert {:error, {:enrichment_invalid, {:actor, :untrusted}}} =
             normalize(current, %{"context" => %{"short_summary" => "bad"}}, actor: %{kind: "human", id: "operator"})
  end

  test "reuses canonical validation, option correlation, artifact safety, and redaction" do
    current = current_decision()
    secret = "GHSAT0" <> String.duplicate("A", 36)

    assert {:ok, enrichment} =
             normalize(current, %{"context" => %{"short_summary" => "Token #{secret}"}})

    refute enrichment.decision.context.short_summary =~ secret
    assert enrichment.decision.context.short_summary =~ "[REDACTED:ghsat]"

    assert {:error, {:decision_invalid, {:recommendation, :dangling_option_id}}} =
             normalize(current, %{"recommendation" => %{"option_id" => "missing"}})

    assert {:error, {:decision_invalid, {:artifacts, :artifact_url_insecure_scheme}}} =
             normalize(current, %{"artifacts" => ["http://github.com/unsafe"]})
  end

  test "an exact replay is normalized as unchanged while an empty patch is invalid" do
    current = current_decision()

    assert {:ok, %{changed: false, decision: replay}} =
             normalize(current, %{"context" => %{"short_summary" => current.context.short_summary}})

    assert replay.content_hash == current.content_hash
    assert {:error, {:enrichment_invalid, :empty_patch}} = normalize(current, %{})
  end

  test "normalization preserves the landed OCC-3 lifecycle projection" do
    current = current_decision()

    {:ok, answer} =
      DecisionAnswer.normalize(
        %{
          "idempotency_key" => "supervisor-answer",
          "expected_version" => current.version,
          "option_id" => "original",
          "rationale" => "The canonical option"
        },
        decision_id: current.decision_id,
        decision_version: current.version,
        options: current.options,
        actor: %{kind: :operator, id: "operator-1"},
        now: ~U[2026-07-12 11:00:00Z]
      )

    acknowledgement = %{
      action_id: answer.action_id,
      actor: %{kind: :agent, id: "agent-1"},
      source: %{agent_id: "agent-1"},
      detail: "Applied",
      occurred_at: ~U[2026-07-12 11:01:00Z],
      event_id: "ack-1",
      run_id: nil
    }

    dispatch_attempt = %{
      action_id: answer.action_id,
      attempt_id: "attempt-1",
      queue_item_id: 1,
      run_id: "run-1",
      status: :consumed,
      attempted_at: ~U[2026-07-12 11:00:10Z],
      queued_at: ~U[2026-07-12 11:00:10Z],
      delivered_at: ~U[2026-07-12 11:00:20Z],
      restored_at: nil,
      consumed_at: ~U[2026-07-12 11:00:30Z],
      failed_at: nil,
      failure_reason_class: nil
    }

    resolution = %{acknowledgement | detail: "Resolved", event_id: "resolve-1"}

    current =
      %{
        current
        | answer: answer,
          decision_status: :resolved,
          delivery_status: :consumed,
          dispatch_attempts: [dispatch_attempt],
          acknowledgement: acknowledgement,
          resolution: resolution
      }

    assert {:ok, %{decision: enriched}} =
             normalize(current, %{"context" => %{"short_summary" => "Lifecycle-safe"}})

    assert enriched.answer == answer
    assert enriched.decision_status == :resolved
    assert enriched.delivery_status == :consumed
    assert enriched.dispatch_attempts == [dispatch_attempt]
    assert enriched.acknowledgement == acknowledgement
    assert enriched.resolution == resolution
  end

  defp current_decision do
    payload = %{
      "source_id" => "decision-enrichment",
      "question" => "Which scope should own this?",
      "blocking" => true,
      "kind" => "architecture",
      "authority" => "supervisor_allowed",
      "reversibility" => "reversible",
      "context" => %{
        "short_summary" => "Original summary",
        "long_context_markdown" => "Full original context"
      },
      "options" => [%{"id" => "original", "label" => "Original option"}]
    }

    {:ok, decision} = DecisionValidation.normalize(payload, ticket: @ticket, source: @source, now: ~U[2026-07-12 10:00:00Z])
    %{decision | version: 3}
  end

  defp normalize(current, patch, overrides \\ []) do
    opts =
      [expected_version: current.version, actor: @actor, now: @now]
      |> Keyword.merge(overrides)

    DecisionEnrichment.normalize(current, patch, opts)
  end
end
