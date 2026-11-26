defmodule Aiur.AgentRunner.TurnBudget do
  @moduledoc "Effective per-issue turn budgets."

  @doc """
  Effective turn cap for an issue: the `agent.max_turns_by_complexity` entry for
  the issue's `complexity:N` level when present, otherwise the flat
  `agent.max_turns`.
  """
  @spec max_turns_for(Aiur.Issue.t()) :: pos_integer() | nil
  def max_turns_for(%Aiur.Issue{} = issue) do
    with level when is_integer(level) <- Aiur.CodingAgent.complexity_level(issue),
         cap when is_integer(cap) <- Map.get(Aiur.Config.agent_max_turns_by_complexity(), level) do
      cap
    else
      _ -> Aiur.Config.agent_max_turns()
    end
  end
end
