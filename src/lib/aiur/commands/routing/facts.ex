defmodule Aiur.Commands.Routing.Facts do
  @moduledoc false

  alias Aiur.DecisionEvent
  alias Aiur.DecisionProjection.TransitionValidation

  @fields [:route_policy, :route_state, :routed_at, :human_visible_at, :escalations, :executor_acknowledged_at, :human_needed_at]

  @spec inherit(map(), map()) :: map()
  def inherit(current, candidate), do: struct!(candidate, Map.take(current, @fields))

  @spec public(map()) :: map()
  def public(decision), do: Map.take(decision, @fields -- [:human_needed_at])

  @spec apply(map(), DecisionEvent.t()) :: {:ok, map()} | {:error, term()}
  def apply(decision, event) do
    with :ok <- TransitionValidation.require_current_version(decision, event.decision_version) do
      transition(decision, event)
    end
  end

  @spec duplicate?(map(), atom(), map()) :: boolean()
  def duplicate?(decision, :human_needed, _data), do: not is_nil(decision.human_needed_at)
  def duplicate?(decision, :executor_acknowledged, _data), do: not is_nil(decision.executor_acknowledged_at)

  def duplicate?(decision, :escalated, data) do
    Enum.any?(decision.escalations, &(&1.decision_version == decision.version and &1.cause == data.cause))
  end

  def duplicate?(_decision, _type, _data), do: false

  defp transition(decision, %{type: :routed, data: data}) do
    if decision.decision_status in [:open, :deferred] and is_nil(decision.answer) do
      visible = if data.state == :with_executor, do: decision.human_visible_at, else: decision.human_visible_at || data.at
      {:ok, %{decision | route_policy: data.policy, route_state: data.state, routed_at: data.at, human_visible_at: visible}}
    else
      {:error, :command_not_open}
    end
  end

  defp transition(decision, %{type: :escalated, data: data}) do
    cond do
      duplicate?(decision, :escalated, data) -> {:error, :duplicate}
      decision.route_state != :with_executor or decision.decision_status not in [:open, :deferred] or not is_nil(decision.answer) -> {:error, :command_not_with_executor}
      true -> escalate(decision, data)
    end
  end

  defp transition(decision, %{type: :human_needed, data: data}) do
    cond do
      duplicate?(decision, :human_needed, data) -> {:error, :duplicate}
      is_nil(decision.human_visible_at) -> {:error, :command_not_human_visible}
      true -> {:ok, %{decision | human_needed_at: data.at}}
    end
  end

  defp transition(decision, %{type: :executor_acknowledged, data: data}) do
    if duplicate?(decision, :executor_acknowledged, data),
      do: {:error, :duplicate},
      else: {:ok, %{decision | executor_acknowledged_at: data.at}}
  end

  defp escalate(decision, data) do
    escalation = data |> Map.take([:cause, :at, :detail]) |> Map.put(:decision_version, decision.version)
    {:ok, %{decision | route_state: :with_human, human_visible_at: decision.human_visible_at || data.at, escalations: decision.escalations ++ [escalation]}}
  end
end
