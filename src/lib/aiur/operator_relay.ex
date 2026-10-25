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

  @doc false
  @spec config_changed(map() | nil, map()) :: :ok
  def config_changed(previous, current) do
    if enabled?(current) and not enabled?(previous) do
      Aiur.Signal.alert("system.config.operator_relay.enabled",
        message: "executor.relay_operator_answers enabled: Executors may record quoted operator answers",
        reason: "The operator-answer relay gate changed from disabled to enabled.",
        needs_attention: false,
        severity: "info"
      )
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp enabled?(%{workflow: %{config: %{"executor" => %{"relay_operator_answers" => true}}}}), do: true
  defp enabled?(_state), do: false
end
