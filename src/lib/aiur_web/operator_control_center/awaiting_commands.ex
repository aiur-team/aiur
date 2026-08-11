defmodule AiurWeb.OperatorControlCenter.AwaitingCommands do
  @moduledoc false

  alias Aiur.DecisionPubSub
  alias AiurWeb.Endpoint
  alias AiurWeb.OperatorControlCenter.DecisionProvider

  @spec subscribe() :: :ok
  def subscribe, do: DecisionPubSub.subscribe()

  @spec counts() :: map()
  def counts do
    decision_store = Endpoint.config(:decision_store) || Aiur.DecisionStore
    counts(decision_store)
  end

  @spec counts(GenServer.server()) :: map()
  def counts(decision_store) do
    {:ok, counts} = DecisionProvider.counts(decision_store: decision_store)
    counts
  rescue
    _error -> unavailable_counts()
  catch
    :exit, _reason -> unavailable_counts()
  end

  @spec nav_counts(map()) :: map()
  def nav_counts(retained_counts) do
    case Map.get(retained_counts, :open) do
      count when is_integer(count) and count > 0 -> %{commands: count}
      _count -> %{}
    end
  end

  defp unavailable_counts do
    %{
      open: nil,
      blocking: nil,
      total: nil,
      scope: %{kind: :retained, label: "All retained decisions"},
      health: %{
        status: :unavailable,
        partial?: true,
        reason: :retained_store_unavailable,
        label: "Retained Decision counts unavailable"
      }
    }
  end
end
