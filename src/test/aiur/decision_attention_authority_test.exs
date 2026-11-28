defmodule Aiur.DecisionAttentionAuthorityTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionValidation

  @opts [
    ticket: %{identifier: "123", title: "Attention authority", url: nil},
    source: %{agent_id: "worker", session_id: "session-1"},
    legacy_attention: %{slug: "scope-question", topic: "ticket.123.agent.attention.scope-question"}
  ]

  test "an attention-origin engineering question is Executor-answerable" do
    assert {:ok, decision} = DecisionValidation.normalize(request(), @opts)

    assert decision.authority == :supervisor_allowed
    assert decision.reversibility == :reversible
    assert decision.legacy_attention.slug == "scope-question"
  end

  test "attention-origin spend and publication choices stay human-required" do
    for basis <- ["spend", "external_publication"] do
      payload =
        request()
        |> Map.put("authority", "human_required")
        |> Map.put("reversibility", "irreversible")
        |> Map.put("context", %{"authority_basis" => basis})

      assert {:ok, decision} = DecisionValidation.normalize(payload, @opts)
      assert decision.authority == :human_required
      assert decision.context.authority_basis == basis
    end
  end

  defp request do
    %{"question" => "Can we use the established format?", "blocking" => false, "kind" => "legacy_attention"}
  end
end
