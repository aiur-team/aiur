defmodule Aiur.AppServer.NativeSteer do
  @moduledoc "Non-cancelling input to the current provider turn, with boundary fallback."

  require Logger
  alias Aiur.AppServer.{Messages, TurnState}

  @spec steer_pending(map(), map()) :: map()
  def steer_pending(session, state) do
    busy? = Enum.any?(state.pending_operator_requests, fn {_, request} -> request[:kind] == :steer end)

    if is_nil(Map.get(state, :pause_request_id)) and is_nil(Map.get(state, :pending_interrupt_request_id)) and
         not Map.get(state, :steer_fallback?, false) and not busy? and is_binary(state.current_turn_id) and state.outstanding_turns > 0 and
         function_exported?(state.backend, :steer, 3) do
      claim(session, state)
    else
      state
    end
  end

  defp claim(session, state) do
    case Map.get(state, :on_steer_claim, fn -> :noop end).() do
      :noop -> state
      {:deliver_text, text, ok, fail} -> send_claim(session, state, text, ok, fail)
    end
  end

  defp send_claim(session, state, text, ok, fail) do
    case state.backend.steer(session, %{kind: :text, body: text}, state.current_turn_id) do
      {:ok, id} ->
        request = %{kind: :steer, on_success: ok, on_failure: fail}
        %{state | pending_operator_requests: Map.put(state.pending_operator_requests, id, request)}

      {:error, reason} ->
        fallback(session, state, fail, reason)
        Map.put(state, :steer_fallback?, true)
    end
  end

  @spec handle_response(map(), map(), map(), map()) :: {:continue, map()} | {:ok, :turn_completed}
  def handle_response(session, state, request, %{"result" => %{"turnId" => turn_id}} = payload) when is_binary(turn_id) do
    TurnState.safe_invoke_success_callback(request.on_success, %{turn_id: turn_id, payload: payload})
    Messages.emit_message(state.on_message, :operator_steered, %{turn_id: turn_id}, state.backend.metadata_from_message(session.port, payload))

    session
    |> steer_pending(state)
    |> TurnState.maybe_finish_after_pending_response()
  end

  def handle_response(session, state, request, payload) do
    reason =
      case payload do
        %{"error" => error} -> {:response_error, error}
        _ -> :invalid_steer_response
      end

    fallback(session, state, request.on_failure, reason)
    TurnState.maybe_finish_after_pending_response(Map.put(state, :steer_fallback?, true))
  end

  defp fallback(session, state, callback, reason) do
    # Error messages can echo user input; log only the protocol code or local reason.
    code =
      case reason do
        {:response_error, error} when is_map(error) -> Map.get(error, "code", :provider_error)
        reason when is_atom(reason) -> reason
        _ -> :unknown
      end

    Logger.info("steer_fallback #{Messages.issue_context(state.issue)} session_id=#{session.thread_id}-#{state.current_turn_id} reason=#{inspect(code)}")
    TurnState.safe_invoke_failure_callback(callback, reason)
  end
end
