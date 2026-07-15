defmodule Aiur.AppServer.Interrupts do
  @moduledoc """
  Shared pause and Executor-queue interrupt state machine.
  """

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
end
