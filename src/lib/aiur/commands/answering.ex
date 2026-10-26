defmodule Aiur.Commands.Answering do
  @moduledoc "Actor attribution and replacement precedence for Command answers."

  alias Aiur.DecisionAnswer

  @spec direct_human?(DecisionAnswer.actor()) :: boolean()
  def direct_human?(%{kind: kind}), do: kind == :operator

  @spec human_attributed?(DecisionAnswer.actor()) :: boolean()
  def human_attributed?(%{kind: kind}), do: kind in [:operator, :operator_relayed]

  @spec precedence(DecisionAnswer.actor()) :: 1 | 2 | 3
  def precedence(%{kind: :operator}), do: 3
  def precedence(%{kind: :operator_relayed}), do: 2
  def precedence(%{kind: kind}) when kind in [:executor, :supervisor, :agent, :system], do: 1

  @spec require_actor_may_replace(DecisionAnswer.actor(), map()) :: :ok | {:error, {:conflict, {:human_answer | :direct_operator_answer, String.t()}}}
  def require_actor_may_replace(caller, %{actor: winner, action_id: action_id}) do
    cond do
      precedence(caller) >= precedence(winner) -> :ok
      winner.kind == :operator and caller.kind == :operator_relayed -> {:error, {:conflict, {:direct_operator_answer, action_id}}}
      true -> {:error, {:conflict, {:human_answer, action_id}}}
    end
  end
end
