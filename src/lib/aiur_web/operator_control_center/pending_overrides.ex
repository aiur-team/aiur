defmodule AiurWeb.OperatorControlCenter.PendingOverrides do
  @moduledoc false
  alias Aiur.Commands
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.DecisionPath

  @spec load(keyword()) :: {:ok, [map()]} | :unavailable
  def load(opts \\ []) do
    store = Keyword.get(opts, :store, EndpointConfig.get(:decision_store) || Commands.default_store())

    with {:ok, %{health: %{status: :available}}} <- Commands.query_counts(store: store),
         decisions when is_list(decisions) <- Commands.list_decisions(store, 1_000) do
      {:ok, rows(decisions)}
    else
      _unknown -> :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end

  @spec rows([map()]) :: [map()]
  def rows(decisions) do
    decisions
    |> Enum.flat_map(fn decision ->
      case Commands.pending_override_status(decision) do
        nil -> []
        override -> [%{decision_id: decision.decision_id, ticket: Commands.override_target_ticket(decision).identifier, label: override.label, href: DecisionPath.detail(decision.decision_id, :all)}]
      end
    end)
    |> Enum.sort_by(&{&1.ticket, &1.decision_id})
  end
end
