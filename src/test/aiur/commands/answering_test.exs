defmodule Aiur.Commands.AnsweringTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.Answering

  test "direct and relayed actors retain distinct attribution" do
    assert Answering.direct_human?(%{kind: :operator})
    refute Answering.direct_human?(%{kind: :operator_relayed})
    assert Answering.human_attributed?(%{kind: :operator})
    assert Answering.human_attributed?(%{kind: :operator_relayed})
    refute Answering.human_attributed?(%{kind: :executor})
  end

  test "replacement compares every actor rank and reports the winning action" do
    ranked = [operator: 3, operator_relayed: 2, executor: 1, supervisor: 1, agent: 1, system: 1]

    for {caller_kind, caller_rank} <- ranked, {winner_kind, winner_rank} <- ranked do
      caller = %{kind: caller_kind, id: "caller"}
      answer = %{actor: %{kind: winner_kind, id: "winner"}, action_id: "winning-action"}

      expected =
        cond do
          caller_rank >= winner_rank -> :ok
          caller_kind == :operator_relayed -> {:error, {:conflict, {:direct_operator_answer, "winning-action"}}}
          true -> {:error, {:conflict, {:human_answer, "winning-action"}}}
        end

      assert Answering.precedence(caller) == caller_rank
      assert Answering.require_actor_may_replace(caller, answer) == expected
    end
  end
end
