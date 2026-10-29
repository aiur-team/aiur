defmodule AiurWeb.Components.VoiceDelivery do
  @moduledoc "Adapters from the existing composer receipts and Command notices."
  alias AiurWeb.OperatorControlCenter.{DecisionOutcomes, DecisionReplacement}

  @spec receipt(list(), String.t(), map()) :: map() | nil
  def receipt(receipts, key, errors) do
    case Enum.find(receipts, &(&1[:target_key] == key)) do
      nil ->
        nil

      item ->
        state = if item[:receipt] in [:accepted, :held_async, :waiting_turn_end, :harness_queued, :in_context, :read, :failed, :outcome_unknown], do: item.receipt, else: :unknown
        delivery = %{state: state, message_id: item[:message_id]}
        if delivery.state in [:failed, :outcome_unknown] && errors[key], do: Map.put(delivery, :copy, errors[key]), else: delivery
    end
  end

  @spec command(map(), map()) :: map() | nil
  def command(decision, state) do
    {notice, _actions} = DecisionReplacement.notice(decision, state)
    outcome = state[:outcome] || DecisionOutcomes.canonical_notice(decision)

    case notice do
      nil ->
        nil

      {tone, copy, _actions} ->
        accepted = match?(%{status: status} when status in [:accepted, :duplicate], outcome)

        receipt =
          cond do
            tone == :error -> :failed
            accepted -> :accepted
            true -> :unknown
          end

        %{state: receipt, copy: copy}
    end
  end
end
