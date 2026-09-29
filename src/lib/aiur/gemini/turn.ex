defmodule Aiur.Gemini.Turn do
  @moduledoc "One ACP prompt turn with scoped tools, explicit permissions and typed cancellation."

  alias Aiur.AgentTools.MCP
  alias Aiur.AppServer.Messages
  alias Aiur.Gemini.{Protocol, Transport}
  alias Aiur.PauseContainment

  def run(%{port: port, gateway: gateway, thread_id: session_id} = session, prompt, issue, opts)
      when is_binary(prompt) and byte_size(prompt) > 0 do
    if PauseContainment.paused?(Map.get(session, :containment)) do
      {:paused, %{request_id: :containment, turn_id: nil, details: :pause_latched_before_turn}}
    else
      attempt = Keyword.get(opts, :attempt_id, make_ref())

      with {:ok, binding} <- MCP.bind(gateway, attempt) do
        try do
          request_id = System.unique_integer([:positive])
          frame = Protocol.prompt(request_id, session_id, prompt)

          case Transport.send_frame(port, frame) do
            :ok ->
              start_loop(session, issue, request_id, binding, opts)

            {:error, reason} ->
              {:error, {:gemini_prompt_not_sent, reason}}
          end
        after
          MCP.unbind(gateway, binding)
        end
      end
    end
  end

  def run(_, _, _, _), do: {:error, :invalid_gemini_turn}

  defp start_loop(session, issue, request_id, binding, opts) do
    on_message = Keyword.get(opts, :on_message, &Messages.default_on_message/1)
    metadata = Map.get(session, :metadata, %{})
    Messages.emit_message(on_message, :session_started, %{session_id: "#{session.thread_id}-#{request_id}", thread_id: session.thread_id, turn_id: request_id}, metadata)

    delivery = notify_delivery(opts, request_id)

    state = %{
      session: session,
      issue_id: Messages.issue_identifier(issue),
      request_id: request_id,
      binding: binding,
      executor: Keyword.get(opts, :tool_executor, &unavailable_tool/2),
      operator_response: Keyword.get(opts, :on_operator_response, fn _ -> :noop end),
      on_message: on_message,
      pending: "",
      permissions: %{},
      deadline: System.monotonic_time(:millisecond) + Keyword.get(opts, :turn_timeout_ms, Aiur.Config.agent_turn_timeout_ms()),
      interrupted: nil,
      delivery: delivery
    }

    loop(state)
  end

  defp loop(%{session: %{port: port, gateway: gateway}} = state) do
    remaining = state.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      finish(state, {:error, :gemini_turn_outcome_unknown})
    else
      receive do
        {^port, {:data, chunk}} ->
          case Transport.decode_chunk(state.pending, chunk) do
            {:more, pending} -> loop(%{state | pending: pending})
            {:ok, frame} -> handle_frame(%{state | pending: ""}, frame)
            {:error, reason} -> finish(state, {:error, reason})
          end

        {^port, {:exit_status, status}} ->
          finish(state, {:error, {:gemini_turn_outcome_unknown, {:port_exit, status}}})

        {:aiur_mcp_call, ^gateway, _, _, _, _, _, _} = request ->
          case MCP.execute_request(gateway, request, state.executor) do
            :ok -> loop(state)
            {:error, reason} -> finish(state, {:error, {:gemini_mcp_dispatch_failed, reason}})
          end

        {:pause_agent, request_id, generation} when is_integer(request_id) and is_integer(generation) ->
          interrupt(state, {:pause, %{request_id: request_id, generation: generation}})

        {:pause_agent, request_id} when is_integer(request_id) ->
          interrupt(state, {:pause, request_id})

        {:agent_queue_updated, issue_id, _item_id, _urgent} when issue_id == state.issue_id and map_size(state.permissions) > 0 ->
          answer_permission(state)

        {:agent_queue_updated, issue_id, _item_id, true} when issue_id == state.issue_id ->
          interrupt(state, :operator_message)

        {:agent_queue_updated, _, _, _} ->
          loop(state)

        {:agent_queue_updated, issue_id, _item_id} when issue_id == state.issue_id and map_size(state.permissions) > 0 ->
          answer_permission(state)

        {:agent_queue_updated, _, _} ->
          loop(state)
      after
        remaining -> finish(state, {:error, :gemini_turn_outcome_unknown})
      end
    end
  end

  defp handle_frame(%{request_id: id} = state, %{"id" => id, "result" => %{"stopReason" => reason}} = frame) do
    emit(state, Map.merge(frame, %{"method" => "session/prompt", "aiurCliVersion" => state.session.cli_version, "aiurSessionId" => state.session.thread_id}), %{})

    base = %{session_id: "#{state.session.thread_id}-#{id}", thread_id: state.session.thread_id, turn_id: id, usage: :unavailable}

    outcome =
      case {state.interrupted, reason} do
        {{:pause, %{request_id: _, generation: _} = control}, stop}
        when stop in ["cancelled", "end_turn"] ->
          {:paused, Map.merge(base, %{control: control, native_terminal: terminal(stop)})}

        {{:pause, request_id}, stop} when stop in ["cancelled", "end_turn"] ->
          {:paused, Map.merge(base, %{request_id: request_id, native_terminal: terminal(stop)})}

        {:operator_message, "cancelled"} ->
          {:ok, Map.put(base, :result, :turn_interrupted_for_operator_message)}

        {_, "end_turn"} ->
          {:ok, Map.put(base, :result, :turn_completed)}

        {_, "cancelled"} ->
          {:error, :gemini_turn_cancelled}

        {_, other} ->
          {:error, {:gemini_stop_reason, other}}
      end

    finish(state, outcome)
  end

  defp handle_frame(%{request_id: id} = state, %{"id" => id, "error" => error}),
    do: finish(state, {:error, {:gemini_prompt_failed, error}})

  defp handle_frame(
         state,
         %{"method" => "session/request_permission", "id" => id, "params" => %{"sessionId" => session_id, "options" => options}} = frame
       )
       when session_id == state.session.thread_id and is_list(options) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    entry = %{id: id, options: options}
    emit(state, frame, %{gemini_permission_token: token})
    loop(%{state | permissions: Map.put(state.permissions, token, entry)})
  end

  defp handle_frame(state, %{"method" => "session/update", "params" => %{"sessionId" => id}} = frame)
       when id == state.session.thread_id do
    emit(state, frame, %{})
    loop(state)
  end

  defp handle_frame(state, %{"method" => method, "id" => id}) when is_binary(method) do
    Transport.send_frame(state.session.port, %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32601, "message" => "Aiur does not support #{method}"}})
    loop(state)
  end

  defp handle_frame(state, _), do: loop(state)

  defp answer_permission(state) do
    case state.operator_response.("/approve") do
      {:deliver_text, text, success, failure} ->
        case String.split(String.trim(text)) do
          ["/approve", token, choice] ->
            case Map.pop(state.permissions, token) do
              {%{id: id, options: options}, rest} ->
                if Enum.any?(options, &(&1["optionId"] == choice)) do
                  frame = %{"jsonrpc" => "2.0", "id" => id, "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => choice}}}

                  case Transport.send_frame(state.session.port, frame) do
                    :ok ->
                      success.(%{transport: :gemini_acp, approval_id: id, decision: choice, confirmation: :request_only})
                      loop(%{state | permissions: rest})

                    {:error, reason} ->
                      failure.(reason)
                      finish(state, {:error, reason})
                  end
                else
                  failure.({:invalid_native_response, :invalid_approval_choice})
                  loop(state)
                end

              {nil, _} ->
                failure.({:invalid_native_response, :stale_approval})
                loop(state)
            end

          _ ->
            failure.({:invalid_native_response, :invalid_approval_command})
            loop(state)
        end

      :noop ->
        loop(state)
    end
  end

  defp interrupt(%{interrupted: nil} = state, action) do
    case Transport.send_frame(state.session.port, Protocol.cancel(state.session.thread_id)) do
      :ok -> loop(%{state | interrupted: action})
      {:error, reason} -> finish(state, {:error, {:gemini_cancel_failed, reason}})
    end
  end

  defp interrupt(state, _action), do: loop(state)

  defp finish(state, result) do
    Enum.each(state.permissions, fn {_token, %{id: id}} ->
      Transport.send_frame(state.session.port, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"outcome" => %{"outcome" => "cancelled"}}})
    end)

    case state.delivery do
      {:error, reason} -> {:error, {:provider_delivery_ack_failed, %{turn_id: state.request_id, cause: reason, native_outcome: result}}}
      _ -> result
    end
  end

  defp notify_delivery(opts, request_id) do
    callback = Keyword.get(opts, :on_provider_delivery, fn _ -> :ok end)

    case callback.(%{transport: :gemini_acp, turn_id: request_id}) do
      {:error, reason} -> {:error, reason}
      _acknowledged -> :ok
    end
  rescue
    error -> {:error, {:callback_exception, error.__struct__}}
  catch
    kind, _reason -> {:error, {:callback_failure, kind}}
  end

  defp emit(state, frame, extras) do
    details =
      Map.merge(
        %{payload: frame, raw: Jason.encode!(frame), gemini_session_id: state.session.thread_id, gemini_turn_id: state.request_id},
        extras
      )

    Messages.emit_message(state.on_message, :notification, details, Map.get(state.session, :metadata, %{}))
  end

  defp terminal("cancelled"), do: :cancelled
  defp terminal("end_turn"), do: :completed

  defp unavailable_tool(_name, _args), do: %{"isError" => true, "content" => [%{"type" => "text", "text" => "Aiur tool executor unavailable"}]}
end
