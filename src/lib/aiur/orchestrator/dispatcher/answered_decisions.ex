defmodule Aiur.Orchestrator.Dispatcher.AnsweredDecisions do
  @moduledoc false

  require Logger

  alias Aiur.{Commands, Decision}

  @spec for_ticket(String.t() | nil, GenServer.server(), timeout()) :: [map()]
  def for_ticket(nil, _store, _timeout), do: []

  def for_ticket(identifier, store, timeout) when is_binary(identifier) do
    Commands.list_decisions(store, timeout)
    |> Enum.filter(fn decision ->
      decision.ticket.identifier == identifier and decision.decision_status == :decided and not is_nil(decision.answer) and
        decision.delivery_status not in [:delivered, :consumed]
    end)
    |> Enum.map(fn decision ->
      answer = Decision.active_answer(decision)

      %{
        action_id: decision.active_action_id,
        question: decision.question,
        answer: answer_text(decision, answer),
        actor: answer_actor(answer),
        accepted_at: answer.accepted_at
      }
    end)
  catch
    :exit, reason ->
      Logger.warning("Decision store unavailable while loading answered decisions for ticket #{identifier}: #{inspect(reason)}")
      []
  end

  defp answer_text(%{options: options}, %{selected_option_id: option_id}) when is_binary(option_id) do
    case Enum.find(options, &(&1.id == option_id)) do
      %{label: label} -> "#{option_id}: #{label}"
      _ -> option_id
    end
  end

  defp answer_text(_decision, %{custom_response: response}), do: response

  defp answer_actor(%{actor: %{kind: kind, id: id}}), do: "#{kind}: #{id || "unknown"}"
end
