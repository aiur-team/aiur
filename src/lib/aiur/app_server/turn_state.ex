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

  @spec continue_after_turn_completion(map()) ::
          {:ok, :turn_completed} | {:continue, map()}
  def continue_after_turn_completion(state) do
    next_state = %{state | outstanding_turns: max(state.outstanding_turns - 1, 0)}

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
      not is_nil(state.pause_request_id) ->
        fail_pending_operator_requests(next_state.pending_operator_requests, {:turn_interrupted, payload})

        {:paused,
         %{
           control: state.pause_request_id,
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
