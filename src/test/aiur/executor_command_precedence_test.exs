defmodule Aiur.ExecutorCommandPrecedenceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.ExecutorCommandCLI

  for {reason, message} <- [
        {:human_answer, "a human answered this Command; the Executor cannot replace it"},
        {:direct_operator_answer, "the operator answered this Command directly; a relayed answer cannot replace it"}
      ] do
    test "supersede refusal explains #{reason}" do
      reason = unquote(reason)

      output =
        capture_io(:stderr, fn ->
          assert ExecutorCommandCLI.answer(
                   [decision_id: "decision-1", expected_version: 1, custom_response: "Replacement", rationale: "New evidence", idempotency_key: "replacement", supersede: true],
                   supersede_fun: fn _, _, _, _ -> {:error, {:conflict, {reason, "action-1"}}} end
                 ) == 1
        end)

      assert output =~ unquote(message)
    end
  end
end
