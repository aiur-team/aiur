defmodule Aiur.Commands.ConflictSummary do
  @moduledoc "Pure winner attribution and replacement availability for answer conflicts."

  alias Aiur.Commands.Answering
  alias Aiur.{Decision, DecisionAnswer}

  @type t :: %{
          actor_kind: atom(),
          actor_id: String.t() | nil,
          actor_source: atom(),
          summary: String.t() | nil,
          accepted_at: DateTime.t(),
          delivery_status: Decision.delivery_status(),
          delivered?: boolean(),
          in_flight?: boolean(),
          replaceable: boolean()
        }

  @doc "Summarizes the active answer, or returns nil when no answer has been accepted."
  @spec for(Decision.t(), DecisionAnswer.actor()) :: t() | nil
  def for(%Decision{} = decision, caller) do
    case Decision.active_answer(decision) do
      nil -> nil
      answer -> summarize(decision, caller, answer)
    end
  end

  defp summarize(decision, caller, answer) do
    delivered? = Decision.delivered?(decision)
    in_flight? = Decision.send_in_flight?(decision)

    %{
      actor_kind: answer.actor.kind,
      actor_id: answer.actor.id,
      actor_source: Map.get(answer.actor, :source, :rpc),
      summary: answer_summary(decision, answer),
      accepted_at: answer.accepted_at,
      delivery_status: decision.delivery_status,
      delivered?: delivered?,
      in_flight?: in_flight?,
      replaceable: not delivered? and not in_flight? and Answering.precedence(caller) >= Answering.precedence(answer.actor)
    }
  end

  defp answer_summary(decision, %{selected_option_id: option_id, custom_response: custom_response}) do
    case Enum.find(decision.options, &(&1.id == option_id)) do
      %{label: label} -> label
      nil -> if is_binary(custom_response), do: String.slice(custom_response, 0, 120)
    end
  end
end
