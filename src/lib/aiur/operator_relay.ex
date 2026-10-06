defmodule Aiur.OperatorRelay do
  @moduledoc "Operator notification for an explicitly attributed answer relay."
  alias Aiur.{Alerts, DecisionAnswer}

  @doc false
  @spec notify(Aiur.Decision.t(), DecisionAnswer.t()) :: term()
  def notify(decision, answer) do
    Alerts.emit_custom(
      "executor.command.operator_relayed",
      "Command #{decision.decision_id}: answered by operator, relayed by #{answer.relayed_by}. Quote: «#{answer.operator_quote}»",
      issue: decision.ticket.identifier,
      reason: "An operator answer was recorded through an Executor relay.",
      severity: "info",
      needs_attention: false
    )
  end
end
