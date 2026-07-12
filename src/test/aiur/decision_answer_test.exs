defmodule Aiur.DecisionAnswerTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionAnswer

  @decision_id "dec_abc123"
  @actor %{kind: :operator, id: "operator-1"}
  @options [%{id: "ship", label: "Ship it"}, %{id: "wait", label: "Wait"}]

  defp normalize(payload, opts \\ []) do
    DecisionAnswer.normalize(
      payload,
      Keyword.merge(
        [decision_id: @decision_id, decision_version: 2, options: @options, actor: @actor],
        opts
      )
    )
  end

  test "normalizes an option answer into a decision-scoped stable action" do
    payload = %{
      "idempotency_key" => "operator-submit-42",
      "expected_version" => 2,
      "option_id" => "ship",
      "rationale" => "The checks are green."
    }

    assert {:ok, answer} = normalize(payload, now: ~U[2026-07-12 10:00:00Z])
    assert answer.decision_id == @decision_id
    assert answer.decision_version == 2
    assert answer.selected_option_id == "ship"
    assert answer.custom_response == nil
    assert answer.actor == @actor
    assert String.starts_with?(answer.action_id, "act_")

    assert {:ok, replay} = normalize(payload, now: ~U[2026-07-12 11:00:00Z])
    assert replay.action_id == answer.action_id
    assert replay.content_hash == answer.content_hash
    refute replay.accepted_at == answer.accepted_at
  end

  test "the same caller token is scoped by decision id" do
    payload = %{"idempotency_key" => "operator-submit-42", "expected_version" => 2, "custom_response" => "Proceed"}

    assert {:ok, first} = normalize(payload)
    assert {:ok, second} = normalize(payload, decision_id: "dec_other")
    refute first.action_id == second.action_id
  end

  test "requires exactly one selected option or custom response" do
    base = %{"idempotency_key" => "answer-1", "expected_version" => 2}

    assert {:error, {:answer_invalid, {:response, :missing}}} = normalize(base)

    assert {:error, {:answer_invalid, {:response, :ambiguous}}} =
             normalize(Map.merge(base, %{"option_id" => "ship", "custom_response" => "Actually wait"}))
  end

  test "rejects an option that is not on the addressed request version" do
    payload = %{"idempotency_key" => "answer-1", "expected_version" => 2, "option_id" => "unknown"}

    assert {:error, {:answer_invalid, {:option_id, :unknown}}} = normalize(payload)
  end

  test "rejects a stale expected version before producing an action" do
    payload = %{"idempotency_key" => "answer-1", "expected_version" => 1, "custom_response" => "Proceed"}

    assert {:error, {:answer_invalid, {:stale_version, 1, 2}}} = normalize(payload)
  end

  test "round trips the persisted shape through the same validator" do
    payload = %{"idempotency_key" => "answer-1", "expected_version" => 2, "custom_response" => "Proceed carefully"}
    assert {:ok, answer} = normalize(payload, now: ~U[2026-07-12 10:00:00Z])

    raw = answer |> DecisionAnswer.to_json_safe() |> Jason.encode!() |> Jason.decode!()

    assert {:ok, replayed} = DecisionAnswer.from_json_safe(raw)
    assert replayed == answer
    refute Map.has_key?(raw, "supervisor_basis")
  end

  test "requires and round trips a validated basis for supervisor answers" do
    payload = %{
      "idempotency_key" => "supervisor-submit-1",
      "expected_version" => 2,
      "option_id" => "ship",
      "rationale" => "The policy permits this choice."
    }

    basis = supervisor_basis()
    opts = [actor: %{kind: :supervisor, id: "supervising-agent"}, supervisor_basis: basis]

    assert {:ok, answer} = normalize(payload, opts)
    assert answer.supervisor_basis == basis

    raw = answer |> DecisionAnswer.to_json_safe() |> Jason.encode!() |> Jason.decode!()
    assert raw["supervisor_basis"]["policy_basis"]["authority"] == "supervisor_allowed"
    assert {:ok, ^answer} = DecisionAnswer.from_json_safe(raw)

    assert {:error, {:answer_invalid, {:supervisor_basis, :missing}}} =
             normalize(payload, actor: %{kind: :supervisor, id: "supervising-agent"})

    assert {:error, {:answer_invalid, {:supervisor_basis, :unexpected}}} =
             normalize(payload, supervisor_basis: basis)
  end

  test "supervisor basis participates in answer idempotency content" do
    payload = %{
      "idempotency_key" => "supervisor-submit-1",
      "expected_version" => 2,
      "option_id" => "ship",
      "rationale" => "Proceed"
    }

    opts = [actor: %{kind: :supervisor, id: "supervising-agent"}, supervisor_basis: supervisor_basis()]
    assert {:ok, first} = normalize(payload, opts)

    changed_basis = put_in(supervisor_basis(), [:confidence], 50)
    assert {:ok, changed} = normalize(payload, Keyword.put(opts, :supervisor_basis, changed_basis))

    assert first.action_id == changed.action_id
    refute first.content_hash == changed.content_hash
  end

  test "redacts secrets from answer content and trusted actor metadata" do
    secret = "ghp_" <> String.duplicate("A", 36)

    payload = %{
      "idempotency_key" => "answer-1",
      "expected_version" => 2,
      "custom_response" => "Use #{secret}",
      "rationale" => "Credential #{secret} was supplied"
    }

    assert {:ok, answer} = normalize(payload, actor: %{kind: :operator, id: "operator-#{secret}"})
    persisted = answer |> DecisionAnswer.to_json_safe() |> Jason.encode!()

    refute persisted =~ secret
    assert persisted =~ "[REDACTED:ghp]"
  end

  defp supervisor_basis do
    %{
      confidence: 87,
      alternatives_considered: ["Wait"],
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
end
