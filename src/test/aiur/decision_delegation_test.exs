defmodule Aiur.DecisionDelegationTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionDelegation, DecisionValidation}

  @ticket %{identifier: "984", title: "OCC-7", url: "https://github.com/its-everdred/aiur/issues/984"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @policy %{allowed_kinds: ["architecture"], allow_non_reversible: false}

  test "normalizes complete supervisor reasoning and snapshots the evaluated policy" do
    decision = decision()

    assert {:ok, delegation} = DecisionDelegation.normalize(decision, valid_payload(), @policy)

    assert delegation.answer_payload == %{
             "custom_response" => nil,
             "expected_version" => 1,
             "idempotency_key" => "supervisor-action-1",
             "option_id" => "ship",
             "rationale" => "The canonical path preserves one audit."
           }

    assert delegation.basis == %{
             confidence: 87,
             alternatives_considered: ["Wait for another review", "Build a parallel queue"],
             reversibility_belief: :reversible,
             policy_basis: %{
               authority: :supervisor_allowed,
               kind: "architecture",
               reversibility: :reversible,
               checks: %{
                 authority_delegable: true,
                 kind_allowed: true,
                 reversibility_allowed: true
               },
               allow_non_reversible: false
             }
           }
  end

  test "denies human-required, unallowlisted, and non-reversible decisions before normalization" do
    cases = [
      {decision(authority: :human_required), @policy, [:human_required]},
      {decision(kind: "product"), @policy, [:kind_not_allowed]},
      {decision(reversibility: :irreversible), @policy, [:non_reversible_not_allowed]}
    ]

    for {decision, policy, reasons} <- cases do
      assert {:error, {:delegation_forbidden, %{reasons: ^reasons}}} =
               DecisionDelegation.normalize(decision, valid_payload(), policy)
    end
  end

  test "requires bounded reasoning fields and rejects payload authority or actor claims" do
    decision = decision()

    invalid = [
      {Map.delete(valid_payload(), "rationale"), {:rationale, :missing}},
      {Map.put(valid_payload(), "confidence", 101), {:confidence, :invalid}},
      {Map.put(valid_payload(), "alternatives_considered", "none"), {:alternatives_considered, :invalid_type}},
      {Map.put(valid_payload(), "reversibility_belief", "unknown"), {:reversibility_belief, :invalid}},
      {Map.put(valid_payload(), "actor", %{"kind" => "operator"}), {:forbidden_fields, ["actor"]}},
      {Map.put(valid_payload(), "policy_basis", %{}), {:forbidden_fields, ["policy_basis"]}},
      {%{valid_payload() | "confidence" => 87} |> Map.put(:confidence, 86), {:duplicate_fields, ["confidence"]}}
    ]

    for {payload, reason} <- invalid do
      assert {:error, {:delegation_invalid, ^reason}} =
               DecisionDelegation.normalize(decision, payload, @policy)
    end
  end

  test "redacts and bounds rationale and alternatives" do
    decision = decision()
    secret = "ghp_" <> String.duplicate("A", 36)

    payload =
      valid_payload()
      |> Map.put("rationale", "Use #{secret}")
      |> Map.put("alternatives_considered", ["Expose #{secret}"])

    assert {:ok, delegation} = DecisionDelegation.normalize(decision, payload, @policy)
    refute delegation.answer_payload["rationale"] =~ secret
    refute hd(delegation.basis.alternatives_considered) =~ secret

    too_many = Map.put(valid_payload(), "alternatives_considered", List.duplicate("one", 21))

    assert {:error, {:delegation_invalid, {:alternatives_considered, :too_many}}} =
             DecisionDelegation.normalize(decision, too_many, @policy)
  end

  defp valid_payload do
    %{
      "idempotency_key" => "supervisor-action-1",
      "expected_version" => 1,
      "option_id" => "ship",
      "custom_response" => nil,
      "rationale" => "The canonical path preserves one audit.",
      "confidence" => 87,
      "alternatives_considered" => ["Wait for another review", "Build a parallel queue"],
      "reversibility_belief" => "reversible"
    }
  end

  defp decision(overrides \\ []) do
    payload = %{
      "source_id" => "delegation",
      "question" => "Which path?",
      "blocking" => true,
      "kind" => Keyword.get(overrides, :kind, "architecture"),
      "authority" => overrides |> Keyword.get(:authority, :supervisor_allowed) |> Atom.to_string(),
      "reversibility" => overrides |> Keyword.get(:reversibility, :reversible) |> Atom.to_string(),
      "options" => [%{"id" => "ship", "label" => "Ship"}]
    }

    {:ok, decision} =
      DecisionValidation.normalize(payload,
        ticket: @ticket,
        source: @source,
        now: ~U[2026-07-12 10:00:00Z]
      )

    decision
  end
end
