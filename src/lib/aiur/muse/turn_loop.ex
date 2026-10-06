defmodule Aiur.Muse.TurnLoop do
  @moduledoc "Bounded runner-owner receive loop for one admitted native Muse turn."

  alias Aiur.AgentTools.MCP
  alias Aiur.AppServer.Messages
  alias Aiur.Muse.{Approvals, Meters, Protocol, Transport, TurnControl, View}

  @spec await(map(), String.t(), map(), reference(), keyword(), pos_integer()) ::
          {:ok, map()} | {:paused, map()} | {:error, term()}
  def await(session, turn_id, issue, binding, opts, timeout_ms) do
    state = %{
      session: session,
      turn_id: turn_id,
      issue_id: Messages.issue_identifier(issue),
      binding: binding,
      approvals: Approvals.new(session),
      operator_response: Keyword.get(opts, :on_operator_response, fn _command -> :noop end),
      on_message: Keyword.get(opts, :on_message, &Messages.default_on_message/1),
      executor: Keyword.get(opts, :tool_executor, &unavailable_tool/2),
      deadline: System.monotonic_time(:millisecond) + timeout_ms,
      pending: "",
      view: View.new(session.thread_id),
      interrupt: nil,
      interrupt_accepted: false,
      pending_terminal: nil
    }

    loop(state)
  end

  defp loop(%{session: %{port: port, gateway: gateway}} = state) do
    remaining = state.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close(state, {:error, :native_turn_timeout})
    else
      receive do
        {^port, {:data, chunk}} ->
          case Transport.decode_chunk(state.pending, chunk) do
            {:more, pending} -> loop(%{state | pending: pending})
            {:ok, frame} -> continue(state, handle_frame(%{state | pending: ""}, frame))
            {:error, reason} -> close(state, {:error, reason})
          end

        {^port, {:exit_status, status}} ->
          close(state, {:error, {:native_port_exit, status}})

        {:muse_prestart, frame} ->
          continue(state, handle_frame(state, frame))

        {:aiur_mcp_call, ^gateway, _, _, _, _, _, _} = request ->
          case MCP.execute_request(gateway, request, state.executor) do
            :ok -> loop(state)
            {:error, reason} -> close(state, {:error, {:native_mcp_dispatch_failed, reason}})
          end

        {:pause_agent, request_id, generation} when is_integer(request_id) and is_integer(generation) ->
          continue(state, TurnControl.interrupt(state, {:pause, %{request_id: request_id, generation: generation}}))

        {:pause_agent, request_id} when is_integer(request_id) ->
          continue(state, TurnControl.interrupt(state, {:pause, request_id}))

        {:agent_queue_updated, issue_id, _item_id, urgent} when issue_id == state.issue_id ->
          continue(state, operator_wake(state, urgent))

        {:agent_queue_updated, _, _, _} ->
          loop(state)

        {:agent_queue_updated, _, _} ->
          loop(state)
      after
        remaining -> close(state, {:error, :native_turn_timeout})
      end
    end
  end

  defp continue(_prior, {:continue, state}), do: loop(state)
  defp continue(prior, result), do: close(prior, result)

  defp close(state, result) do
    Approvals.close(state.approvals)
    result
  end

  defp operator_wake(state, urgent) do
    if Approvals.pending?(state.approvals) do
      case state.operator_response.("/approve") do
        {:deliver_text, text, success, failure} ->
          {:continue, %{state | approvals: Approvals.deliver(state.approvals, text, success, failure)}}

        :noop ->
          {:continue, state}
      end
    else
      if urgent, do: TurnControl.interrupt(state, :operator_message), else: {:continue, state}
    end
  end

  defp handle_frame(
         %{interrupt: %{request_id: id, command_id: command_id}} = state,
         %{"id" => id, "result" => result}
       ) do
    case Protocol.turn_interrupt_result(result, command_id) do
      {:accepted, _} ->
        state = %{state | interrupt_accepted: true}
        if state.pending_terminal, do: TurnControl.finish(state, state.pending_terminal), else: {:continue, state}

      {:error, reason} ->
        {:error, {:native_interrupt_rejected, reason}}
    end
  end

  defp handle_frame(%{interrupt: %{request_id: id}}, %{"id" => id, "error" => error}),
    do: {:error, {:native_interrupt_rejected, error}}

  defp handle_frame(state, %{"method" => method} = frame)
       when method == "userInput/request" do
    if get_in(frame, ["params", "sessionId"]) == state.session.thread_id do
      reason = :native_user_input_required
      emit(state, :notification, frame, %{reason: reason})

      if Map.has_key?(frame, "id") do
        Transport.send_frame(state.session.port, %{"jsonrpc" => "2.0", "id" => frame["id"], "error" => %{"code" => -32_603, "message" => "Aiur cannot present this native request"}})
      end

      TurnControl.interrupt(state, {:error, reason})
    else
      {:continue, state}
    end
  end

  defp handle_frame(state, %{"method" => "turn/completed"} = frame) do
    case Protocol.turn_completed(frame, state.session.thread_id, state.turn_id) do
      {:terminal, outcome, params} ->
        with {:continue, state} <- ingest(state, frame) do
          finish_or_wait_for_interrupt(state, {outcome, params})
        end

      {:error, reason} ->
        if get_in(frame, ["params", "sessionId"]) == state.session.thread_id and
             get_in(frame, ["params", "turnId"]) == state.turn_id,
           do: {:error, reason},
           else: {:continue, state}
    end
  end

  defp handle_frame(state, %{"method" => "turn/unqueued", "params" => %{"sessionId" => session_id, "turnId" => turn_id}})
       when session_id == state.session.thread_id and turn_id == state.turn_id,
       do: {:error, :native_turn_unqueued}

  defp handle_frame(state, %{"method" => "usage/changed"} = frame) do
    Meters.observe(state.session, frame)
    ingest(state, frame)
  end

  defp handle_frame(state, %{"method" => _} = frame) do
    ingest(state, frame)
  end

  defp handle_frame(state, frame), do: {:continue, %{state | approvals: Approvals.observe(state.approvals, frame)}}

  defp finish_or_wait_for_interrupt(%{interrupt: interrupt, interrupt_accepted: false} = state, terminal)
       when not is_nil(interrupt), do: {:continue, %{state | pending_terminal: terminal}}

  defp finish_or_wait_for_interrupt(state, terminal), do: TurnControl.finish(state, terminal)

  defp ingest(state, frame) do
    case View.ingest(state.view, frame) do
      {:emit, details, view} ->
        emit(state, :notification, frame, Map.delete(details, :payload))
        {:continue, %{state | view: view, approvals: Approvals.observe(state.approvals, frame)}}

      {:ignore, view} ->
        {:continue, %{state | view: view}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit(state, event, frame, extras) do
    metadata = Map.get(state.session, :metadata, %{})
    params = Map.get(frame, "params", %{})

    details =
      Map.merge(
        %{payload: frame, raw: Jason.encode!(frame), muse_session_id: state.session.thread_id, muse_turn_id: state.turn_id, muse_view_cursor: params["viewCursor"]},
        extras
      )

    Messages.emit_message(state.on_message, event, details, metadata)
  end

  defp unavailable_tool(_name, _args), do: %{"isError" => true, "content" => [%{"type" => "text", "text" => "Aiur tool executor unavailable"}]}
end
