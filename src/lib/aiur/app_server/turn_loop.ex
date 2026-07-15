defmodule Aiur.AppServer.TurnLoop do
  @moduledoc """
  Shared blocking receive loop for app-server turns.
  """

  alias Aiur.AppServer.{Interrupts, Messages, OperatorDelivery, TurnState}

  @spec receive_loop(map(), map()) :: term()
  def receive_loop(%{port: port} = session, state) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = state.pending_line <> to_string(chunk)

        case handle_incoming(session, %{state | pending_line: ""}, complete_line) do
          {:continue, next_state} -> receive_loop(session, next_state)
          result -> result
        end

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(session, %{state | pending_line: state.pending_line <> to_string(chunk)})

      {^port, {:exit_status, status}} ->
        handle_port_exit(state, status)

      {:pause_agent, request_id} when is_integer(request_id) ->
        case Interrupts.handle_pause_request(session, state, request_id) do
          {:continue, next_state} -> receive_loop(session, next_state)
          result -> result
        end

      {:agent_queue_updated, issue_identifier, _item_id, true}
      when issue_identifier == state.issue_identifier ->
        case Interrupts.handle_operator_queue_update(session, state) do
          {:continue, next_state} -> receive_loop(session, next_state)
          result -> result
        end

      {:agent_queue_updated, issue_identifier, _item_id, _deliver_now}
      when issue_identifier == state.issue_identifier ->
        receive_loop(session, state)

      {:agent_queue_updated, issue_identifier, _item_id}
      when issue_identifier == state.issue_identifier ->
        receive_loop(session, state)

      {:agent_queue_updated, _issue_identifier, _item_id, _deliver_now} ->
        receive_loop(session, state)

      {:agent_queue_updated, _issue_identifier, _item_id} ->
        receive_loop(session, state)
    after
      state.timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(%{port: port} = session, state, data) do
    on_message = state.on_message
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, payload} ->
        handle_decoded_incoming(session, state, payload, payload_string, port, on_message)

      {:error, _reason} ->
        state.backend.handle_malformed(state, payload_string, port)
    end
  end

  defp handle_decoded_incoming(_session, state, %{"id" => request_id, "result" => _} = payload, _payload_string, _port, _on_message)
       when request_id == state.pending_interrupt_request_id do
    TurnState.acknowledge_interrupt(state, payload)
  end

  defp handle_decoded_incoming(_session, state, %{"id" => request_id, "error" => error}, _payload_string, _port, _on_message)
       when request_id == state.pending_interrupt_request_id do
    state.backend.handle_interrupt_error(state, error)
  end

  defp handle_decoded_incoming(session, state, %{"id" => request_id, "result" => _} = payload, payload_string, _port, _on_message)
       when is_integer(request_id) do
    OperatorDelivery.handle_pending_operator_response(session, state, payload, payload_string, request_id)
  end

  defp handle_decoded_incoming(session, state, %{"id" => request_id, "error" => _} = payload, payload_string, _port, _on_message)
       when is_integer(request_id) do
    OperatorDelivery.handle_pending_operator_response(session, state, payload, payload_string, request_id)
  end

  defp handle_decoded_incoming(session, state, %{"method" => method} = payload, payload_string, _port, _on_message)
       when is_binary(method) do
    state.backend.handle_method(session, state, payload, payload_string, method)
  end

  defp handle_decoded_incoming(_session, state, payload, payload_string, port, on_message) do
    Messages.emit_message(
      on_message,
      :other_message,
      %{
        payload: payload,
        raw: payload_string
      },
      state.backend.metadata_from_message(port, payload)
    )

    {:continue, state}
  end

  defp resolve_pending_anonymous_completion(%{pending_anonymous_completion?: true} = state) do
    payload = %{
      "params" => %{
        "turn" => %{
          "id" => state.current_turn_id,
          "status" => "completed"
        }
      }
    }

    state
    |> Map.put(:pending_anonymous_completion?, false)
    |> TurnState.continue_after_turn_completion(payload)
  end

  defp resolve_pending_anonymous_completion(_state), do: :none

  defp handle_port_exit(state, 0) do
    case resolve_pending_anonymous_completion(state) do
      :none -> {:error, {:port_exit, 0}}
      {:continue, _next_state} -> {:error, {:port_exit, 0}}
      result -> result
    end
  end

  defp handle_port_exit(_state, status), do: {:error, {:port_exit, status}}
end
