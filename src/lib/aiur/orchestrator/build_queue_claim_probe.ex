defmodule Aiur.Orchestrator.BuildQueueClaimProbe do
  @moduledoc "Reads ownership in the orchestrator's serialized dispatch process."

  @behaviour Aiur.BuildQueue.ClaimProbe

  alias Aiur.BuildQueue.{ClaimProbe, Hints}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{DispatchCandidates, DispatchPolicy, IssueSync, OptimisticLedger, QueueSetSlots, State}

  @impl true
  def next_set, do: next_set(Orchestrator)

  @doc false
  @spec next_set(State.t() | GenServer.server()) :: ClaimProbe.next_set()
  def next_set(%State{} = state) do
    issues = Map.values(state.last_polled_issues)
    ordered = DispatchCandidates.order(issues, DispatchPolicy.terminal_state_set(), issues)
    candidate = Enum.find(ordered, &DispatchPolicy.should_dispatch_issue?(&1, state))
    snapshot = Hints.sets()
    member = candidate && snapshot && snapshot.members[candidate.id]
    {:ok, if(member, do: member.set_id)}
  end

  def next_set(server) do
    GenServer.call(server, :build_queue_next_set, 1_000)
  catch
    :exit, _ -> :unavailable
  end

  @impl true
  def status(ids), do: status(Orchestrator, ids)

  @impl true
  def optimistic_records, do: OptimisticLedger.open_records()

  @doc false
  @spec status(GenServer.server(), [String.t()]) :: ClaimProbe.result()
  def status(server, ids) when is_list(ids) do
    GenServer.call(server, {:build_queue_claim_status, ids}, 1_000)
  catch
    :exit, _ -> :unavailable
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
        :queue_set_order -> {:declined, {:queue_set_order, QueueSetSlots.waiting(id, state)}}
        nil -> :unclaimed
        reason -> {:declined, reason}
      end
    end
  end
end
