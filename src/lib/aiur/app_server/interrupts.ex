defmodule Aiur.AppServer.Interrupts do
  @moduledoc """
  Shared pause and Executor-queue interrupt state machine.
  """

  alias Aiur.AppServer.TurnState

  @spec handle_pause_request(map(), map(), integer() | map()) ::
          {:continue, map()} | {:error, term()}
  def handle_pause_request(_session, %{pause_request_id: request} = state, request)
      when not is_nil(request) do
    {:continue, state}
  end

  def handle_pause_request(_session, %{pause_request_id: existing_request} = state, _request)
      when not is_nil(existing_request) do
    {:continue, state}
  end

  def handle_pause_request(session, state, request_id) do
    case interrupt_turn(state.backend, session, state.current_turn_id) do
      {:ok, interrupt_request_id} ->
        {:continue,
         %{
           state
           | pause_request_id: request_id,
             pending_interrupt_request_id: interrupt_request_id,
             interrupt_action: :pause
         }}

      {:error, reason} ->
        {:error, {:turn_interrupt_failed, reason}}
    end
  end

  @spec handle_operator_queue_update(map(), map()) :: {:continue, map()} | {:error, term()}
  def handle_operator_queue_update(_session, %{pending_interrupt_request_id: request_id} = state)
      when is_integer(request_id) do
    {:continue, state}
  end

  def handle_operator_queue_update(session, state) do
    case interrupt_turn(state.backend, session, state.current_turn_id) do
      {:ok, interrupt_request_id} ->
        {:continue,
         %{
           state
           | pending_interrupt_request_id: interrupt_request_id,
             interrupt_action: :operator_message
         }}

      {:error, reason} ->
        {:error, {:turn_interrupt_failed, reason}}
    end
  end

  @doc false
  @spec handle_no_active_turn_error(map(), term()) ::
          {:ok, :turn_completed} | {:paused, map()} | {:ok, :turn_interrupted_for_operator_message} | {:error, term()}
  def handle_no_active_turn_error(state, error) do
    cond do
      completed_turn_already_retired?(state) and state.interrupt_action == :pause ->
        {:paused,
         TurnState.pause_result_payload(
           state.pause_request_id,
           state.current_turn_id,
           %{"error" => error, "status" => "interrupted"}
         )}

      completed_turn_already_retired?(state) and state.interrupt_action == :operator_message ->
        {:ok, :turn_interrupted_for_operator_message}

      completed_turn_already_retired?(state) ->
        TurnState.maybe_finish_after_pending_response(%{state | pending_interrupt_request_id: nil})

      state.interrupt_action in [:pause, :operator_message] ->
        TurnState.continue_after_turn_interrupted(
          %{state | pending_interrupt_request_id: nil},
          %{"error" => error, "status" => "interrupted"},
          :preserve
        )

      true ->
        state
        |> Map.put(:pending_interrupt_request_id, nil)
        |> TurnState.complete_all_provider_turns()
    end
  end

  @spec interrupt_turn(module(), map(), String.t()) :: {:ok, integer()} | {:error, term()}
  def interrupt_turn(backend, %{port: port, thread_id: thread_id}, turn_id)
      when is_port(port) and is_binary(thread_id) and is_binary(turn_id) do
    request_id = :erlang.unique_integer([:positive])

    frame = %{
      "method" => "turn/interrupt",
      "id" => request_id,
      "params" => %{
        "threadId" => thread_id,
        "turnId" => turn_id
      }
    }

    case backend.send_frame(port, frame) do
      :ok -> {:ok, request_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def interrupt_turn(_backend, _session, _turn_id), do: {:error, :invalid_session}

  defp completed_turn_already_retired?(%{retired_turn_ids: retired_turn_ids, current_turn_id: turn_id})
       when is_struct(retired_turn_ids, MapSet) and is_binary(turn_id) do
    MapSet.member?(retired_turn_ids, turn_id)
  end

  defp completed_turn_already_retired?(_state), do: false
end
