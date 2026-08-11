defmodule Aiur.DecisionHistoryTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionEvent, DecisionHistory, DecisionValidation}

  test "projects every version newest first with honest source actors" do
    histories = %{
      "dec_1" => [
        record(%{version: 1, created_at: ~U[2026-07-12 12:00:00Z]}),
        record(%{version: 2, question: "Choose again?", created_at: ~U[2026-07-12 12:01:00Z]})
      ],
      "dec_2" => [
        record(%{
          decision_id: "dec_2",
          version: 1,
          created_at: ~U[2026-07-12 12:02:00Z],
          source: %{agent_id: nil}
        })
      ]
    }

    [unknown, enriched, requested] = DecisionHistory.from_histories(histories)

    assert unknown.decision_id == "dec_2"
    assert unknown.actor == %{type: :unknown, id: nil, label: "Unknown source"}
    assert enriched.change == :enriched
    assert enriched.source_version == 2
    assert requested.change == :requested
    assert requested.actor == %{type: :ticket_agent, id: "agent-1", label: "agent-1"}
  end

  test "uses explicit human and supervising-agent provenance without guessing" do
    human =
      record(%{
        actor: %{type: :human_operator, id: "operator-1", label: "Kevin"},
        change_kind: :answered,
        choice: "ship",
        rationale: "CI is green",
        dispatch_result: :queued
      })

    supervisor =
      record(%{
        decision_id: "dec_2",
        actor: %{"type" => "supervising_agent", "id" => "supervisor-1"},
        change_kind: "revised",
        revision_of: 1,
        acknowledgement_result: "acknowledged"
      })

    human_entry = DecisionHistory.project_record(human)
    supervisor_entry = DecisionHistory.project_record(supervisor)

    assert human_entry.actor == %{type: :human_operator, id: "operator-1", label: "Kevin"}
    assert human_entry.choice == "ship"
    assert human_entry.rationale == "CI is green"
    assert human_entry.dispatch_result == :queued

    assert supervisor_entry.actor == %{
             type: :supervising_agent,
             id: "supervisor-1",
             label: "supervisor-1"
           }

    assert supervisor_entry.change == :revised
    assert supervisor_entry.revised?
    assert supervisor_entry.acknowledgement_result == "acknowledged"
  end

  test "does not infer actor type from a source-agent name" do
    entry = DecisionHistory.project_record(record(%{source: %{agent_id: "supervisor"}}))

    assert entry.actor == %{type: :ticket_agent, id: "supervisor", label: "supervisor"}
  end

  test "keeps absent lifecycle fields unavailable and honors the limit" do
    entries = DecisionHistory.from_histories(%{"dec_1" => [record(), record(%{version: 2})]}, limit: 1)

    assert [entry] = entries
    assert entry.source_version == 2
    assert is_nil(entry.choice)
    assert is_nil(entry.rationale)
    assert is_nil(entry.dispatch_result)
    assert is_nil(entry.acknowledgement_result)
    refute entry.revised?
  end

  test "exposes only canonical trusted provenance and keeps legacy records unknown" do
    provenance = %{
      "schema_version" => 1,
      "source" => "agent_runner",
      "captured_at" => "2026-07-13T12:00:00Z",
      "agent_family" => "codex",
      "backend" => "codex",
      "requested_model" => "gpt-5.6-terra",
      "session_id" => "thread-123",
      "attempt_id" => "attempt-456"
    }

    assert DecisionHistory.project_record(record(%{provenance: provenance})).provenance == provenance
    assert DecisionHistory.project_record(record()).provenance == nil

    unsafe = Map.put(provenance, "raw_session", %{"prompt" => "secret"})
    assert DecisionHistory.project_record(record(%{provenance: unsafe})).provenance == nil
  end

  test "projects provenance from a standalone requested event" do
    provenance = %{backend: "codex", session_id: "thread-123", source: "agent_runner"}

    assert {:ok, decision} =
             DecisionValidation.normalize(
               %{"question" => "Keep provenance?", "blocking" => true, "source_id" => "history-provenance"},
               ticket: %{identifier: "979", title: "OCC-1", url: "https://github.com/its-everdred/aiur/issues/979"},
               source: %{agent_id: "agent-1", session_id: "session-1", event_id: "evt-1"},
               provenance: provenance,
               now: ~U[2026-07-13 12:00:00Z]
             )

    assert {:ok, event} =
             DecisionEvent.new(:requested, decision.decision_id, decision.version, decision,
               event_id: 901,
               run_id: "run-history-provenance",
               now: ~U[2026-07-13 12:01:00Z]
             )

    entry = DecisionHistory.project_record(event)

    assert entry.provenance["backend"] == "codex"
    assert entry.provenance["session_id"] == "thread-123"
    assert entry.changed_at == "2026-07-13T12:01:00Z"
  end

  test "projects Executor notifications and acknowledgements as distinct history outcomes" do
    actor = %{kind: :operator, id: "dashboard"}

    assert {:ok, notified} =
             DecisionEvent.new(:decision_deferred, "dec_notified", 1, %{actor: actor},
               event_id: 902,
               run_id: "run-history-outcomes",
               now: ~U[2026-07-13 12:02:00Z]
             )

    assert {:ok, acknowledged} =
             DecisionEvent.new(:decision_dismissed, "dec_acknowledged", 1, %{actor: actor},
               event_id: 903,
               run_id: "run-history-outcomes",
               now: ~U[2026-07-13 12:03:00Z]
             )

    notified_entry = DecisionHistory.project_record(notified)
    acknowledged_entry = DecisionHistory.project_record(acknowledged)

    assert notified_entry.change == :executor_notified
    assert notified_entry.actor == %{type: :human_operator, id: "dashboard", label: "dashboard"}
    assert acknowledged_entry.change == :acknowledged
    assert acknowledged_entry.actor == %{type: :human_operator, id: "dashboard", label: "dashboard"}
  end

  test "retains the existing integer supervisor basis independently of provenance" do
    basis = %{
      confidence: 0,
      alternatives_considered: ["Wait"],
      reversibility_belief: :reversible,
      policy_basis: %{
        authority: :supervisor_allowed,
        kind: "architecture",
        reversibility: :reversible,
        checks: %{authority_delegable: true, kind_allowed: true, reversibility_allowed: true},
        allow_non_reversible: false
      }
    }

    entry =
      record(%{
        answer: %{supervisor_basis: basis},
        provenance: %{
          "schema_version" => 1,
          "source" => "agent_runner",
          "captured_at" => "2026-07-13T12:00:00Z",
          "backend" => "codex"
        }
      })
      |> DecisionHistory.project_record()

    assert entry.supervisor_basis["confidence"] == 0
    assert entry.provenance["backend"] == "codex"
  end

  test "returns the full history by default" do
    histories = %{
      "dec_1" => Enum.map(1..51, &record(%{version: &1}))
    }

    assert DecisionHistory.list(history_fun: fn -> histories end) |> length() == 51
    assert DecisionHistory.list(history_fun: fn -> histories end, limit: 50) |> length() == 50
  end

  test "lists only the bounded provider window and isolates malformed records" do
    parent = self()

    recent = %{
      records: [record(%{version: 2}), nil, record(%{version: 1})],
      contexts: %{},
      revisions: %{}
    }

    entries =
      DecisionHistory.list(
        limit: 2,
        recent_history_fun: fn ->
          send(parent, :bounded_history_read)
          recent
        end
      )

    assert_receive :bounded_history_read
    assert Enum.map(entries, & &1.source_version) == [2, 1]
  end

  test "drops unsafe ticket links from the presentation projection" do
    entry =
      record(%{ticket: %{identifier: "983", title: "OCC-6", url: "javascript:alert(1)"}})
      |> DecisionHistory.project_record()

    assert entry.ticket.identifier == "983"
    assert entry.ticket.url == nil
  end

  test "projects original answers and ordered revisions without inferring rollback" do
    answered =
      record(%{
        change_kind: :answered,
        answer: %{
          action_id: "action-original",
          option_id: "ship",
          rationale: "Proceed",
          accepted_at: ~U[2026-07-12 12:03:00Z],
          actor: %{type: :human_operator, id: "operator-1", label: "Operator"}
        }
      })

    revised =
      record(%{
        version: nil,
        created_at: nil,
        revision: %{
          decision_version: 2,
          action_id: "action-revision-1",
          prior_action_id: "action-original",
          sequence: 1,
          result: :recorded,
          reason: "New production evidence",
          recorded_at: ~U[2026-07-12 12:04:00Z],
          answer: %{
            actor: %{type: :supervising_agent, id: "supervisor-1"},
            custom_response: "Hold the rollout"
          }
        },
        dispatch_result: :delivered
      })

    answer_entry = DecisionHistory.project_record(answered)
    revision_entry = DecisionHistory.project_record(revised)

    assert answer_entry.change == :answered
    assert answer_entry.action_id == "action-original"
    assert answer_entry.choice == "ship"
    assert answer_entry.changed_at == "2026-07-12T12:03:00Z"
    assert answer_entry.actor.type == :human_operator

    assert revision_entry.change == :revised
    assert revision_entry.source_version == 2
    assert revision_entry.action_id == "action-revision-1"
    assert revision_entry.prior_action_id == "action-original"
    assert revision_entry.revision_sequence == 1
    assert revision_entry.revision_result == :recorded
    assert revision_entry.dispatch_result == :delivered
    assert revision_entry.choice == "Hold the rollout"
    assert revision_entry.rationale == "New production evidence"
    assert revision_entry.changed_at == "2026-07-12T12:04:00Z"
    assert revision_entry.actor.type == :supervising_agent
    refute inspect(revision_entry) =~ "rolled back"
  end

  test "projects canonical parent follow-up facts without fabricating a child Decision" do
    required =
      record(%{
        version: nil,
        change_kind: :follow_up_required,
        follow_up_required: true,
        follow_up_slug: "decision-revision-abc",
        follow_up_required_at: ~U[2026-07-12 12:05:00Z],
        prior_action_id: "action-original",
        sequence: 1
      })

    handled =
      record(%{
        version: nil,
        change_kind: :follow_up_handled,
        follow_up_required: true,
        follow_up_handled: true,
        follow_up_slug: "decision-revision-abc",
        follow_up_handled_at: ~U[2026-07-12 12:06:00Z],
        prior_action_id: "action-original",
        sequence: 1
      })

    required_entry = DecisionHistory.project_record(required)
    handled_entry = DecisionHistory.project_record(handled)

    assert required_entry.change == :follow_up_required
    assert required_entry.changed_at == "2026-07-12T12:05:00Z"
    assert required_entry.follow_up.required?
    refute required_entry.follow_up.handled?

    assert handled_entry.change == :follow_up_handled
    assert handled_entry.changed_at == "2026-07-12T12:06:00Z"
    assert handled_entry.follow_up.required?
    assert handled_entry.follow_up.handled?
    assert handled_entry.follow_up.slug == "decision-revision-abc"
    refute Map.has_key?(handled_entry, :child_decision_id)
  end

  defp record(overrides \\ %{}) do
    Map.merge(
      %{
        decision_id: "dec_1",
        version: 1,
        ticket: %{identifier: "983", title: "OCC-6", url: "https://github.com/its-everdred/aiur/issues/983"},
        source: %{agent_id: "agent-1", session_id: "session-1", event_id: nil},
        question: "Ship it?",
        created_at: ~U[2026-07-12 12:00:00Z]
      },
      overrides
    )
  end
end
