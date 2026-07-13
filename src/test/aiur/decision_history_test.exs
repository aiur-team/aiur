defmodule Aiur.DecisionHistoryTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionHistory

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

  test "returns the full history by default" do
    histories = %{
      "dec_1" => Enum.map(1..51, &record(%{version: &1}))
    }

    assert DecisionHistory.list(history_fun: fn -> histories end) |> length() == 51
    assert DecisionHistory.list(history_fun: fn -> histories end, limit: 50) |> length() == 50
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
