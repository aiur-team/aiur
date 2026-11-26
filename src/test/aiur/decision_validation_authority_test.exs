defmodule Aiur.DecisionValidationAuthorityTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionValidation

  @opts [ticket: %{identifier: "979", title: "OCC-1", url: nil}, source: %{agent_id: "agent-1", session_id: "session-1"}]

  test "human_required authority requires a recognized explicit basis" do
    assert normalize(%{"question" => "Who owns this product choice?", "blocking" => true, "authority" => "human_required"}) ==
             {:error, {:decision_invalid, {:authority, :human_required_basis_required}}}
  end

  test "human_required authority rejects an unknown basis" do
    assert normalize(%{
             "question" => "Who owns this choice?",
             "blocking" => true,
             "authority" => "human_required",
             "context" => %{"authority_basis" => "engineering"}
           }) == {:error, {:decision_invalid, {:context_authority_basis, :invalid_enum}}}
  end

  defp normalize(payload), do: DecisionValidation.normalize(payload, @opts)
end
