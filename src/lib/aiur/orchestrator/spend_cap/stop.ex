defmodule Aiur.Orchestrator.SpendCap.Stop do
  @moduledoc false

  alias Aiur.Orchestrator.AgentTeardown
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.State.RunningEntries
  alias Aiur.TrackerIdentity

  @spec request(TrackerIdentity.t(), GenServer.server()) :: :ok | {:error, term()}
  def request(%TrackerIdentity{} = identity, server \\ Aiur.Orchestrator) do
    GenServer.call(server, {:spend_cap_exhausted, identity}, 5_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @spec run(State.t(), TrackerIdentity.t(), function()) ::
          {:ok, :budget_exhausted, State.t()} | {:error, :ambiguous_identifier, State.t()}
  def run(%State{} = state, %TrackerIdentity{} = identity, teardown \\ &AgentTeardown.terminate_running_issue/4) do
    case RunningEntries.find_unique_running_key_by_identity(state.running, identity) do
      {:ok, issue_id, _entry} ->
        {:ok, :budget_exhausted, teardown.(state, issue_id, true, :budget_exhausted)}

      {:error, :no_running_agent} ->
        {:ok, :budget_exhausted, state}

      {:error, :ambiguous_identifier} ->
        {:error, :ambiguous_identifier, state}
    end
  end

  @spec handle_call(State.t(), TrackerIdentity.t()) ::
          {:reply, :ok | {:error, :ambiguous_identifier}, State.t()}
  def handle_call(%State{} = state, %TrackerIdentity{} = identity) do
    case run(state, identity) do
      {:ok, :budget_exhausted, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end
end
