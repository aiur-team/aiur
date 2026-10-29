defmodule Aiur.Commands.OverrideLegacyHashTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionAnswer, DecisionEvent, DecisionRevision, DecisionValidation}

  test "revision journal events written before overrides retain their historical hash" do
    now = DateTime.utc_now()

    payload = %{
      idempotency_key: "legacy-revision",
      expected_version: 1,
      expected_action_id: "original",
      expected_revision_sequence: 0,
      custom_response: "New direction",
      rationale: "Changed requirements"
    }

    assert {:ok, revision} =
             DecisionRevision.normalize(payload,
               decision_id: "legacy-command",
               decision_version: 1,
               current_action_id: "original",
               current_revision_sequence: 0,
               actor: %{kind: :operator, id: "operator"},
               now: now,
               answer_normalizer: &DecisionAnswer.normalize/2
             )

    assert {:ok, event} = DecisionEvent.new(:revision_recorded, "legacy-command", 1, revision, event_id: 1, run_id: "run", now: now)
    raw = event |> DecisionEvent.to_json_safe() |> Jason.encode!() |> Jason.decode!()
    historical = historical_event(raw, Map.delete(raw["data"], "override"), :revision_recorded)
    assert {:ok, decoded} = DecisionEvent.from_json_safe(historical)
    assert decoded.data.override == nil
    assert decoded.content_hash == historical["content_hash"]
    refute Map.has_key?(DecisionEvent.to_json_safe(decoded)["data"], "override")
  end

  test "request journal events written before overrides retain their historical hash" do
    now = DateTime.utc_now()

    assert {:ok, decision} =
             DecisionValidation.normalize(%{question: "Proceed?", blocking: false},
               ticket: %{identifier: "6908", title: "Override", url: "https://github.com/aiur-team/aiur/issues/6908"},
               source: %{agent_id: "worker", session_id: "session", event_id: "request"},
               now: now
             )

    assert {:ok, event} = DecisionEvent.new(:requested, decision.decision_id, 1, decision, event_id: 2, run_id: "run", now: now)
    raw = event |> DecisionEvent.to_json_safe() |> Jason.encode!() |> Jason.decode!()
    data = Map.drop(raw["data"], ["overrides", "pending_for_session", "ticket_comment_status"])
    historical = historical_event(raw, data, :requested)
    assert {:ok, decoded} = DecisionEvent.from_json_safe(historical)
    assert decoded.data.overrides == []
    assert decoded.content_hash == historical["content_hash"]
  end

  defp historical_event(raw, data, type) do
    hashed_data = if type == :requested, do: Map.drop(data, ["provenance", "provenance_hash", "provenance_state"]), else: data

    hash =
      DecisionValidation.content_hash(%{
        schema_version: 1,
        event_type: type,
        event_id: raw["event_id"],
        run_id: raw["run_id"],
        decision_id: raw["decision_id"],
        decision_version: raw["decision_version"],
        occurred_at: raw["occurred_at"],
        data: hashed_data
      })

    raw |> Map.put("data", data) |> Map.put("content_hash", hash)
  end
end
