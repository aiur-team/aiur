defmodule Aiur.AppServer.TurnState do
  @moduledoc """
  Shared completion and interrupt state transitions for app-server turns.
  """

  @spec fail_pending_operator_requests(map(), term()) :: :ok
  def fail_pending_operator_requests(pending_operator_requests, reason) do
    Enum.each(pending_operator_requests, fn {_request_id, pending_request} ->
      safe_invoke_failure_callback(pending_request.on_failure, reason)
    end)
  end

  @doc false
  @spec initialize_turn_tracking(map()) :: map()
  def initialize_turn_tracking(%{active_turn_ids: %MapSet{} = active_turn_ids, current_turn_id: turn_id} = state)
      when is_binary(turn_id) do
    put_active_turn_ids(state, MapSet.put(active_turn_ids, turn_id))
  end

  def initialize_turn_tracking(state), do: state

  @doc false
  @spec register_provider_turn(map(), map()) :: map()
  def register_provider_turn(%{active_turn_ids: %MapSet{} = active_turn_ids} = state, %{"id" => turn_id} = turn)
      when is_binary(turn_id) do
    if active_provider_turn?(turn) do
      put_active_turn_ids(state, MapSet.put(active_turn_ids, turn_id))
    else
      state
    end
  end

  def register_provider_turn(%{active_turn_ids: %MapSet{}} = state, _turn), do: state

  def register_provider_turn(state, _turn) do
    %{state | outstanding_turns: state.outstanding_turns + 1}
  end

  @spec continue_after_turn_completion(map()) ::
          {:ok, :turn_completed} | {:continue, map()}
  def continue_after_turn_completion(state) do
    next_state = %{state | outstanding_turns: max(state.outstanding_turns - 1, 0)}

    finish_or_continue(next_state)
  end

  @spec continue_after_turn_completion(map(), map()) ::
          {:ok, :turn_completed} | {:continue, map()}
  def continue_after_turn_completion(%{active_turn_ids: %MapSet{} = active_turn_ids} = state, payload) do
    next_active_turn_ids = retire_provider_turn(active_turn_ids, provider_turn_id(payload))
    state |> put_active_turn_ids(next_active_turn_ids) |> finish_or_continue()
  end

  def continue_after_turn_completion(state, _payload), do: continue_after_turn_completion(state)

  @doc false
  @spec complete_all_provider_turns(map()) :: {:ok, :turn_completed} | {:continue, map()}
  def complete_all_provider_turns(%{active_turn_ids: %MapSet{}} = state) do
    state |> put_active_turn_ids(MapSet.new()) |> finish_or_continue()
  end

  def complete_all_provider_turns(state), do: continue_after_turn_completion(state)

  defp finish_or_continue(next_state) do
    cond do
      next_state.outstanding_turns == 0 and map_size(next_state.pending_operator_requests) == 0 ->
        {:ok, :turn_completed}

      next_state.outstanding_turns == 0 ->
        fail_pending_operator_requests(next_state.pending_operator_requests, :parent_turn_completed)
        {:ok, :turn_completed}

      true ->
        {:continue, next_state}
    end
  end

  @spec continue_after_turn_interrupted(map(), map()) ::
          {:paused, map()} | {:ok, :turn_interrupted_for_operator_message} | {:error, term()}
  def continue_after_turn_interrupted(state, payload) do
    next_state = %{
      state
      | outstanding_turns: max(state.outstanding_turns - 1, 0),
        pending_interrupt_request_id: nil
    }

    cond do
      is_integer(state.pause_request_id) ->
        fail_pending_operator_requests(next_state.pending_operator_requests, {:turn_interrupted, payload})

        {:paused,
         %{
           request_id: state.pause_request_id,
           turn_id: state.current_turn_id,
           details: payload
         }}

      state.interrupt_action == :operator_message ->
        fail_pending_operator_requests(next_state.pending_operator_requests, {:turn_interrupted, payload})
        {:ok, :turn_interrupted_for_operator_message}

      true ->
        fail_pending_operator_requests(next_state.pending_operator_requests, {:turn_interrupted, payload})
        {:error, {:turn_interrupted, payload}}
    end
  end

  @spec maybe_finish_after_pending_response(map()) ::
          {:ok, :turn_completed} | {:continue, map()}
  def maybe_finish_after_pending_response(state) do
    if state.outstanding_turns == 0 and map_size(state.pending_operator_requests) == 0 do
      {:ok, :turn_completed}
    else
      {:continue, state}
    end
  end

  @spec turn_completion_status(map()) :: String.t()
  def turn_completion_status(%{"params" => %{"turn" => %{"status" => status}}}) when is_binary(status),
    do: status

  def turn_completion_status(%{"turn" => %{"status" => status}}) when is_binary(status), do: status
  def turn_completion_status(_payload), do: "completed"

  defp active_provider_turn?(%{"status" => status}) when is_binary(status), do: status == "inProgress"
  defp active_provider_turn?(_turn), do: true

  defp provider_turn_id(%{"params" => %{"turn" => %{"id" => turn_id}}}) when is_binary(turn_id), do: turn_id
  defp provider_turn_id(%{"turn" => %{"id" => turn_id}}) when is_binary(turn_id), do: turn_id
  defp provider_turn_id(_payload), do: nil

  defp retire_provider_turn(active_turn_ids, turn_id) when is_binary(turn_id) do
    MapSet.delete(active_turn_ids, turn_id)
  end

  defp retire_provider_turn(active_turn_ids, nil) do
    case Enum.take(active_turn_ids, 1) do
      [turn_id] -> MapSet.delete(active_turn_ids, turn_id)
      [] -> active_turn_ids
    end
  end

  defp put_active_turn_ids(state, active_turn_ids) do
    %{state | active_turn_ids: active_turn_ids, outstanding_turns: MapSet.size(active_turn_ids)}
  end

  @spec safe_invoke_success_callback((term() -> term()), term()) :: term() | :ok
  def safe_invoke_success_callback(callback, payload) when is_function(callback, 1) do
    callback.(payload)
  rescue
    _error -> :ok
  end

  @spec safe_invoke_failure_callback((term() -> term()), term()) :: term() | :ok
  def safe_invoke_failure_callback(callback, reason) when is_function(callback, 1) do
    callback.(reason)
  rescue
    _error -> :ok
  end
end
