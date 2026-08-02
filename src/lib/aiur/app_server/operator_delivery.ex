defmodule Aiur.AppServer.OperatorDelivery do
  @moduledoc """
  Shared safe-checkpoint delivery and Executor response tracking.
  """

  alias Aiur.AppServer.{Messages, TurnState}

  @spec handle_pending_operator_response(map(), map(), map(), String.t(), integer()) ::
          {:continue, map()} | {:ok, :turn_completed}
  def handle_pending_operator_response(session, state, payload, payload_string, request_id) do
    on_message = state.on_message

    case Map.pop(state.pending_operator_requests, request_id) do
      {nil, _pending_operator_requests} ->
        Messages.emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          state.backend.metadata_from_message(session.port, payload)
        )

        {:continue, state}

      {%{on_success: on_success, on_failure: on_failure}, pending_operator_requests} ->
        handle_claimed_operator_response(
          session,
          state,
          payload,
          payload_string,
          request_id,
          on_success,
          on_failure,
          pending_operator_requests
        )
    end
  end

  @spec maybe_process_safe_checkpoint(map(), map(), map()) :: map()
  # Single-writer lock. While a parent provider turn is live, sending another
  # `turn/start` on the same thread makes aiur-claude spawn a second concurrent
  # CLI writer in the shared workspace. Never claim or deliver a checkpoint item
  # while `outstanding_turns > 0`; the item stays pending and the turn-boundary
  # drain delivers it after the parent turn ends. Blocker-critical urgency is
  # carried by the acknowledged `turn/interrupt` steering primitive instead.
  def maybe_process_safe_checkpoint(_session, %{outstanding_turns: outstanding} = state, _checkpoint)
      when is_integer(outstanding) and outstanding > 0 do
    state
  end

  def maybe_process_safe_checkpoint(session, state, checkpoint) do
    case state.on_safe_checkpoint.(checkpoint) do
      :noop ->
        state

      {:deliver_text, text, on_success, on_failure}
      when is_binary(text) and is_function(on_success, 1) and is_function(on_failure, 1) ->
        case state.backend.send_operator_message(session, %{kind: :text, body: text}) do
          {:ok, request_id} ->
            pending_operator_requests =
              Map.put(state.pending_operator_requests, request_id, %{
                on_success: on_success,
                on_failure: on_failure,
                text: text
              })

            %{state | pending_operator_requests: pending_operator_requests}

          {:error, reason} ->
            TurnState.safe_invoke_failure_callback(on_failure, reason)
            state
        end
    end
  end

  defp handle_claimed_operator_response(
         session,
         state,
         %{"result" => %{"turn" => %{"id" => turn_id} = turn}} = payload,
         payload_string,
         request_id,
         on_success,
         on_failure,
         pending_operator_requests
       ) do
    next_state = %{state | pending_operator_requests: pending_operator_requests}

    if TurnState.provider_turn_retired?(state, turn_id) do
      TurnState.safe_invoke_failure_callback(on_failure, {:provider_turn_retired, turn_id})
      TurnState.maybe_finish_after_pending_response(next_state)
    else
      TurnState.safe_invoke_success_callback(on_success, %{
        request_id: request_id,
        turn_id: turn_id,
        payload: payload
      })

      Messages.emit_message(
        state.on_message,
        :operator_turn_started,
        %{payload: payload, raw: payload_string},
        state.backend.metadata_from_message(session.port, payload)
      )

      next_state
      |> TurnState.record_accepted_provider_turn(turn)
      |> TurnState.maybe_finish_after_pending_response()
    end
  end

  defp handle_claimed_operator_response(
         _session,
         state,
         %{"error" => error},
         _payload_string,
         _request_id,
         _on_success,
         on_failure,
         pending_operator_requests
       ) do
    TurnState.safe_invoke_failure_callback(on_failure, {:response_error, error})
    TurnState.maybe_finish_after_pending_response(%{state | pending_operator_requests: pending_operator_requests})
  end

  defp handle_claimed_operator_response(
         _session,
         state,
         _payload,
         _payload_string,
         _request_id,
         _on_success,
         _on_failure,
         pending_operator_requests
       ) do
    {:continue, %{state | pending_operator_requests: pending_operator_requests}}
  end
end
