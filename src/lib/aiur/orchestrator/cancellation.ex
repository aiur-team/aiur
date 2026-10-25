defmodule Aiur.Orchestrator.Cancellation do
  @moduledoc """
  Cancels one running ticket and confirms the selected agent process exited.

  Tracker I/O runs in the API caller between two short orchestrator calls. The
  second call fences the selected pid and monitor reference before it requests
  termination, so a replacement generation is never stopped by a stale cancel.
  """

  alias Aiur.Issue
  alias Aiur.Orchestrator.{AgentTeardown, PauseResume, State}
  alias Aiur.Orchestrator.Cancellation.{Client, Observation}

  @tracker_state "cancelled"

  @type result :: Observation.result()

  @spec cancel_agent(String.t()) :: {:ok, result()} | {:error, term()}
  def cancel_agent(identifier), do: cancel_agent(Aiur.Orchestrator, identifier)

  @spec cancel_agent(GenServer.server(), String.t()) :: {:ok, result()} | {:error, term()}
  defdelegate cancel_agent(server, identifier), to: Client

  @doc false
  @spec cancel_agent_call(State.t(), String.t()) :: {:reply, term(), State.t()}
  def cancel_agent_call(%State{} = state, identifier) when is_binary(identifier) do
    PauseResume.guard_control_call(state, :cancel, identifier, fn ->
      case unique_running_entry(state.running, identifier) do
        {:ok, issue_id, %{issue: %Issue{} = issue, pid: pid} = entry} when is_pid(pid) ->
          stage = %{
            issue_id: issue_id,
            pid: pid,
            ref: Map.get(entry, :ref),
            handle: process_handle(entry, identifier, pid)
          }

          {:reply, {:cancel_tracker_io, identifier, stage, issue}, state}

        {:ok, _issue_id, _entry} ->
          {:reply, {:error, :no_running_agent}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end)
  end

  @doc false
  @spec cancel_tracker_call(State.t(), String.t(), map(), term(), keyword()) ::
          {:reply,
           {:ok, result()}
           | {:error, term()}
           | {:cancel_observe, String.t(), map(), term()}, State.t()}
  def cancel_tracker_call(%State{} = state, identifier, stage, tracker_result, opts \\ []) do
    PauseResume.guard_control_call(state, :cancel, identifier, fn ->
      finish_tracker_cancel(state, identifier, stage, tracker_result, opts)
    end)
  end

  defp finish_tracker_cancel(state, _identifier, _stage, {:error, reason}, _opts),
    do: {:reply, {:error, {:tracker_cancel_failed, reason}}, state}

  defp finish_tracker_cancel(state, identifier, stage, :ok, opts) do
    case Map.get(state.running, stage.issue_id) do
      %{pid: pid, ref: ref} = entry when pid == stage.pid and ref == stage.ref ->
        request_selected_generation_stop(state, identifier, stage, entry, opts)

      _changed_or_missing ->
        result = result(identifier, stage.handle, :generation_changed, nil, Observation.now(opts))
        {:reply, {:ok, result}, state}
    end
  end

  defp finish_tracker_cancel(state, _identifier, _stage, other, _opts),
    do: {:reply, {:error, {:tracker_cancel_failed, other}}, state}

  defp request_selected_generation_stop(state, identifier, stage, _entry, opts) do
    stop_fun = Keyword.get(opts, :stop_fun, &AgentTeardown.request_task_stop/1)
    stop_result = Observation.request_stop(stop_fun, stage.pid)
    next = mark_cancel_requested(state, stage.issue_id)

    {:reply, {:cancel_observe, identifier, stage, stop_result}, next}
  end

  @doc false
  @spec cancel_observation_call(State.t(), map(), result()) ::
          {:reply, {:ok, result()}, State.t()}
  def cancel_observation_call(%State{} = state, stage, %{process: %{status: "exited"}} = outcome) do
    next =
      case Map.get(state.running, stage.issue_id) do
        %{pid: pid, ref: ref} when pid == stage.pid and ref == stage.ref ->
          AgentTeardown.terminate_cancelled_issue(state, stage.issue_id)

        _already_reconciled_or_replaced ->
          state
      end

    {:reply, {:ok, outcome}, next}
  end

  def cancel_observation_call(%State{} = state, _stage, outcome),
    do: {:reply, {:ok, outcome}, state}

  @doc false
  @spec result(String.t(), String.t(), Observation.process_status(), term(), DateTime.t()) :: result()
  defdelegate result(identifier, handle, status, exit_reason, observed_at), to: Observation

  defp unique_running_entry(running, identifier) do
    matches =
      Enum.flat_map(running, fn
        {issue_id, %{identifier: candidate} = entry} ->
          if to_string(candidate) == identifier, do: [{issue_id, entry}], else: []

        _other ->
          []
      end)

    case matches do
      [{issue_id, entry}] -> {:ok, issue_id, entry}
      [] -> {:error, :no_running_agent}
      _many -> {:error, :ambiguous_identifier}
    end
  end

  defp process_handle(entry, identifier, pid) do
    Map.get(entry, :telemetry_attempt_id) ||
      Map.get(entry, :session_id) ||
      "#{identifier}:#{inspect(pid)}"
  end

  defp mark_cancel_requested(state, issue_id) do
    update_in(state.running[issue_id], fn
      %{issue: %Issue{} = issue} = entry ->
        entry
        |> Map.put(:cancel_requested, true)
        |> Map.put(:issue, %{issue | state: @tracker_state})

      entry when is_map(entry) ->
        Map.put(entry, :cancel_requested, true)

      entry ->
        entry
    end)
  end
end
