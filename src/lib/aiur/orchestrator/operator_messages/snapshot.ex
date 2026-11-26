defmodule Aiur.Orchestrator.OperatorMessages.Snapshot do
  @moduledoc "Read a complete queue item without changing its delivery state."

  alias Aiur.AgentQueueStore
  alias Aiur.Orchestrator.State

  @spec read(GenServer.server(), integer(), timeout()) :: {:ok, Aiur.AgentQueueItem.t() | nil} | {:error, term()}
  def read(server, item_id, timeout) when is_integer(item_id) do
    GenServer.call(server, {:operator_message_snapshot, item_id}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, {:outcome_unknown, :timeout}}
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Operator messages queued for the Executor and not yet handed to a session, oldest first."
  @spec queued_executor_messages(GenServer.server(), timeout()) :: {:ok, [Aiur.AgentQueueItem.t()]} | {:error, term()}
  def queued_executor_messages(server, timeout) do
    GenServer.call(server, :queued_executor_messages, timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec handle_queued_executor_messages(State.t()) :: {:reply, {:ok, [Aiur.AgentQueueItem.t()]}, State.t()}
  def handle_queued_executor_messages(%State{} = state) do
    items =
      state.queue_store
      |> AgentQueueStore.list_pending("executor")
      |> Enum.filter(&(&1.category == :operator_message))
      |> Enum.sort_by(& &1.sequence)

    {:reply, {:ok, items}, state}
  end

  @spec handle_call(State.t(), integer()) :: {:reply, {:ok, Aiur.AgentQueueItem.t() | nil}, State.t()}
  def handle_call(%State{} = state, item_id) do
    {:reply, {:ok, AgentQueueStore.get(state.queue_store, item_id)}, state}
  end
end
