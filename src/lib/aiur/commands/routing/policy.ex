defmodule Aiur.Commands.Routing.Policy do
  @moduledoc "Pure responder selection and Executor escalation deadlines for Commands."

  alias Aiur.Commands.Requester
  alias Aiur.DecisionAuthority

  @type liveness :: :live | :stalled | :offline
  @type cause ::
          :executor_originated
          | :executor_offline
          | :executor_stalled
          | :authority_human_required
          | :executor_not_answerable
          | :executor_ack_timeout
          | :executor_answer_timeout
  @type route :: %{
          policy: :executor_first | :simultaneous | :human_only,
          state: :with_executor | :with_both | :with_human,
          cause: cause() | nil
        }
  @type config :: %{ack_ms: non_neg_integer(), answer_ms: non_neg_integer(), urgent_factor: number()}
  @type escalation :: :none | {:due, cause(), DateTime.t()} | {:next, DateTime.t()}

  @spec liveness(map()) :: liveness()
  def liveness(%{executors: executors}) do
    cond do
      Enum.any?(executors, &(&1.state in [:active, :idle])) -> :live
      Enum.any?(executors, &(&1.state != :expired)) -> :stalled
      true -> :offline
    end
  end

  @spec route(map(), liveness()) :: route()
  def route(decision, liveness) do
    cond do
      Requester.kind(decision) == :executor -> human_only(:executor_originated)
      liveness == :offline -> human_only(:executor_offline)
      liveness == :stalled -> human_only(:executor_stalled)
      Map.get(decision, :authority) == :human_required -> %{policy: :simultaneous, state: :with_both, cause: :authority_human_required}
      DecisionAuthority.executor_answerable?(decision) -> %{policy: :executor_first, state: :with_executor, cause: nil}
      true -> human_only(:executor_not_answerable)
    end
  end

  @spec escalation_due(map(), DateTime.t(), config()) :: escalation()
  def escalation_due(%{route_state: :with_executor, decision_status: status, answer: nil, routed_at: %DateTime{}} = decision, now, config)
      when status in [:open, :deferred] do
    deadlines = deadlines(decision, config)

    case Enum.find(deadlines, fn {_cause, at} -> DateTime.compare(at, now) != :gt end) do
      {cause, at} -> {:due, cause, at}
      nil -> {:next, deadlines |> Enum.min_by(fn {_cause, at} -> DateTime.to_unix(at, :microsecond) end) |> elem(1)}
    end
  end

  def escalation_due(_decision, _now, _config), do: :none

  @doc "Whether an Executor-only Command has an active finite escalation deadline."
  @spec armed?(map(), config()) :: boolean()
  def armed?(%{route_state: :with_executor} = decision, config) do
    case Map.get(decision, :routed_at) do
      %DateTime{} = at -> escalation_due(decision, at, config) != :none
      _missing -> false
    end
  end

  def armed?(_decision, _config), do: true

  defp deadlines(decision, config) do
    factor = if decision.blocking and decision.urgency in [:high, :critical], do: config.urgent_factor, else: 1.0
    answer = {:executor_answer_timeout, DateTime.add(decision.routed_at, round(config.answer_ms * factor), :millisecond)}

    if Map.get(decision, :executor_acknowledged_at) do
      [answer]
    else
      [{:executor_ack_timeout, DateTime.add(decision.routed_at, round(config.ack_ms * factor), :millisecond)}, answer]
    end
  end

  defp human_only(cause), do: %{policy: :human_only, state: :with_human, cause: cause}
end
