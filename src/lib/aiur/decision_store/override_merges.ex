defmodule Aiur.DecisionStore.OverrideMerges do
  @moduledoc false
  alias Aiur.DecisionStore.{CommandFacts, CorrectiveOverrides}

  @spec notify(String.t() | integer()) :: :ok
  def notify(identifier) do
    case GenServer.whereis(Aiur.Commands.default_store()) do
      nil ->
        :ok

      pid ->
        send(pid, {:override_ticket_merged, to_string(identifier)})
        :ok
    end
  end

  @spec settle(map(), list(), map()) :: map()
  def settle(state, candidates, %{merged?: true, number: number} = pr) do
    Enum.reduce(candidates, state, fn {id, action, version}, acc ->
      data = %{action_id: action, expected_version: version, pr_number: number, head_sha: Map.get(pr, :head_sha), committed_at: Map.get(pr, :committed_at)}

      case CommandFacts.record(acc, id, :override_merge_settled, data, []) do
        {:reply, {:ok, _}, next} -> CorrectiveOverrides.reconcile(next)
        {:reply, {:error, _}, next} -> next
      end
    end)
  end

  @spec before_delivery(map(), map()) :: {:ok, map()} | {:merged, map()}
  def before_delivery(state, item) do
    correlation = Map.get(item, :correlation) || %{}
    id = Map.get(correlation, :decision_id, Map.get(correlation, "decision_id"))
    decision = Map.get(state.current, id)
    record = if decision, do: Enum.find(decision.overrides, &(&1.action_id == Map.get(item, :action_id)))

    if record && record.route != :corrective_ticket && is_nil(record.corrective_ticket) do
      case state.override_pr_reader.(record.ticket.identifier) do
        {:ok, %{merged?: true} = pr} ->
          {:merged, settle(state, [{id, record.action_id, Map.get(record, :merge_version, 1)}], pr)}

        _ ->
          {:ok, state}
      end
    else
      {:ok, state}
    end
  end
end
