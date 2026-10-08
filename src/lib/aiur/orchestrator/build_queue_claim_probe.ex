defmodule Aiur.Orchestrator.BuildQueueClaimProbe do
  @moduledoc "Reads ownership in the orchestrator's serialized dispatch process."

  @behaviour Aiur.BuildQueue.ClaimProbe

  alias Aiur.BuildQueue.ClaimProbe
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{IssueSync, State}

  @impl true
  def status(ids), do: status(Orchestrator, ids)

  @doc false
  @spec status(GenServer.server(), [String.t()]) :: ClaimProbe.result()
  def status(server, ids) when is_list(ids) do
    try do
      GenServer.call(server, {:build_queue_claim_status, ids}, 1_000)
    catch
      :exit, _ -> :unavailable
    end
  end

  @impl true
  def notify_demand(ids), do: notify_demand(Orchestrator, ids)

  @doc false
  @spec notify_demand(GenServer.server(), [String.t()]) :: :ok | :unavailable
  def notify_demand(server, ids) when is_list(ids) do
    case Orchestrator.note_queued_demand(server, ids) do
      :unavailable -> :unavailable
      receipt when is_map(receipt) -> :ok
    end
  end

  @doc false
  @spec classify(State.t(), String.t()) :: ClaimProbe.claim_status()
  def classify(%State{} = state, id) do
    if IssueSync.owned_or_scheduled?(state, id) do
      :claimed
    else
      case Map.get(state.dispatch_declines, id) do
        nil -> :unclaimed
        reason -> {:declined, reason}
      end
    end
  end
end
