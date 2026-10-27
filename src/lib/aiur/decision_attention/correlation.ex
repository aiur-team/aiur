defmodule Aiur.DecisionAttention.Correlation do
  @moduledoc false

  @spec attention_topic(map()) :: String.t()
  def attention_topic(attention),
    do: "ticket.#{issue_identifier!(attention.issue)}.agent.attention.#{attention.slug}"

  @spec resolution_topic(map()) :: String.t()
  def resolution_topic(attention), do: attention_topic(attention) <> ".resolved"

  @spec attention_key(map()) :: {String.t(), String.t()}
  def attention_key(attention), do: {issue_identifier!(attention.issue), attention.slug}

  @spec decision_id(term()) :: String.t() | nil
  def decision_id(%{decision: %{decision_id: id}}) when is_binary(id), do: id
  def decision_id(%{decision: %{"decision_id" => id}}) when is_binary(id), do: id
  def decision_id(_result), do: nil

  @spec alert_reason(map()) :: String.t()
  def alert_reason(%{decision_id: id, question: question}) when is_binary(id),
    do: "Executor decision required (Decision #{id}): #{question}"

  def alert_reason(%{question: question}), do: "Decision attention: #{question}"

  defp issue_identifier!(%{id: id}) when is_binary(id) and id != "", do: id
  defp issue_identifier!(%{identifier: identifier}) when is_binary(identifier) and identifier != "", do: identifier
end
