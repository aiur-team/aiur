defmodule Aiur.Orchestrator.RetryEngine.WorkspaceWait do
  @moduledoc "Retry workspace ownership waits and release."

  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.{TicketTransition, TrackerTasks}
  alias Aiur.Workspace.Ownership
  require Logger

  @doc false
  @spec wait_for_workspace_ownership(State.t(), String.t(), String.t(), term(), term(), map()) :: State.t()
  def wait_for_workspace_ownership(state, issue_id, identifier, owner, wait, retry_defaults \\ %{})

  # `retry_defaults` fills the redispatch envelope for a caller that has no
  # running row or retry entry to read it from, such as a runner stopped
  # because it outlived the Orchestrator that dispatched it.
  def wait_for_workspace_ownership(%State{} = state, issue_id, identifier, owner, wait, retry_defaults)
      when is_binary(issue_id) and is_binary(identifier) and is_map(retry_defaults) do
    context = workspace_wait_context(state, issue_id)
    context = %{context | retry: Map.merge(retry_defaults, context.retry)}
    demonitor_workspace_runner(context.running)
    waiting_state = install_workspace_wait(state, issue_id, identifier, owner, context)
    waiting_state = sync_handoff_modifier(waiting_state, identifier, :add)
    synchronize_workspace_wait(waiting_state, identifier, wait)
  end

  def wait_for_workspace_ownership(state, _issue_id, _identifier, _owner, _wait, _retry_defaults), do: state

  defp workspace_wait_context(state, issue_id) do
    %{running: Map.get(state.running, issue_id), retry: Map.get(state.retry_attempts, issue_id, %{})}
  end

  defp demonitor_workspace_runner(%{ref: ref}) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp demonitor_workspace_runner(_running), do: :ok

  defp install_workspace_wait(state, issue_id, identifier, owner, context) do
    workspace_ownership = state.dispatch_recovery.workspace_ownership
    envelope = workspace_wait_envelope(issue_id, identifier, owner, context)
    workspace_ownership = %{workspace_ownership | waits: Map.put(workspace_ownership.waits, identifier, envelope)}

    state
    |> cancel_pending_retry(issue_id)
    |> Map.put(:running, Map.delete(state.running, issue_id))
    |> Map.put(:claimed, MapSet.put(state.claimed, issue_id))
    |> Map.put(:completed, MapSet.delete(state.completed, issue_id))
    |> put_in([Access.key(:dispatch_recovery), Access.key(:workspace_ownership)], workspace_ownership)
  end

  # A contention report can arrive after the runner's :DOWN. Retain the whole
  # redispatch envelope from either source so a wakeup does not drop the SSH
  # host, retry attempt, tracker identity, or prior-work status.
  defp workspace_wait_envelope(issue_id, identifier, owner, %{running: running, retry: retry}) do
    %{
      issue_id: issue_id,
      identifier: identifier,
      owner: owner,
      since: DateTime.utc_now(),
      worker_host: value_from(running, retry, :worker_host),
      retry_attempt: Map.get(running || %{}, :retry_attempt) || Map.get(retry, :attempt),
      prior_work: value_from(running, retry, :prior_work) == true,
      workspace_path: value_from(running, retry, :workspace_path),
      tracker_identity: value_from(running, retry, :tracker_identity)
    }
  end

  defp value_from(running, retry, key), do: Map.get(running || %{}, key) || Map.get(retry, key)

  # Subscribe after installing the row to catch releases racing the initial contention notice.
  defp synchronize_workspace_wait(state, identifier, :available), do: release_workspace_wait(state, identifier)

  # The caller already knows the exact generation and subscribes on its own,
  # so the Orchestrator never blocks on a guardian that is slow to answer.
  defp synchronize_workspace_wait(state, identifier, {:bound, guardian, generation})
       when is_pid(guardian) and is_integer(generation),
       do: bind_workspace_wait(state, identifier, guardian, generation)

  defp synchronize_workspace_wait(state, identifier, _wait) do
    case Ownership.wait_for_release(identifier, self()) do
      :available -> release_workspace_wait(state, identifier)
      {:waiting, guardian, generation} -> bind_workspace_wait(state, identifier, guardian, generation)
    end
  end

  defp bind_workspace_wait(state, identifier, guardian, generation) do
    update_in(state.dispatch_recovery.workspace_ownership.waits, fn waits ->
      Map.update(waits, identifier, nil, &Map.merge(&1, %{guardian: guardian, generation: generation}))
    end)
  end

  defp cancel_pending_retry(state, issue_id) do
    case Map.pop(state.retry_attempts, issue_id) do
      {nil, _retry_attempts} ->
        %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}

      {%{timer_ref: timer_ref}, retry_attempts} when is_reference(timer_ref) ->
        Process.cancel_timer(timer_ref)
        %{state | retry_attempts: retry_attempts}

      {_retry, retry_attempts} ->
        %{state | retry_attempts: retry_attempts}
    end
  end

  @doc false
  @spec release_workspace_wait(State.t(), String.t()) :: State.t()
  def release_workspace_wait(%State{} = state, identifier) when is_binary(identifier) do
    workspace_ownership = state.dispatch_recovery.workspace_ownership

    case Map.pop(workspace_ownership.waits, identifier) do
      {nil, _workspace_waits} ->
        state

      {%{issue_id: issue_id} = envelope, workspace_waits} ->
        workspace_ownership = %{
          workspace_ownership
          | waits: workspace_waits,
            ready: Map.put(workspace_ownership.ready, issue_id, envelope)
        }

        state = %{
          state
          | claimed: MapSet.delete(state.claimed, issue_id),
            dispatch_recovery: %{state.dispatch_recovery | workspace_ownership: workspace_ownership}
        }

        sync_handoff_modifier(state, identifier, :remove)
    end
  end

  defp sync_handoff_modifier(state, identifier, action) do
    TrackerTasks.chain(
      state,
      {:runtime_reason_labels, identifier},
      fn -> TicketTransition.write_reason_modifier(identifier, action, "handed-off", writer: :workspace_wait) end,
      fn current, result ->
        case result do
          :ok ->
            current

          {:error, reason} ->
            Logger.warning("workspace ownership label update failed: issue=#{identifier} reason=#{inspect(reason)}")
            current
        end
      end
    )
  end

  @doc false
  @spec release_workspace_wait(State.t(), String.t(), pid(), pos_integer()) :: State.t()
  def release_workspace_wait(%State{} = state, identifier, guardian, generation)
      when is_binary(identifier) and is_pid(guardian) and is_integer(generation) and generation > 0 do
    waits = state.dispatch_recovery.workspace_ownership.waits

    case Map.get(waits, identifier) do
      %{guardian: ^guardian, generation: ^generation} -> release_workspace_wait(state, identifier)
      _ -> state
    end
  end
end
