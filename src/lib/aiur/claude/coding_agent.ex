defmodule Aiur.Claude.CodingAgent do
  @moduledoc """
  Claude Code app-server backend implementing the CodingAgent behaviour.

  Simplified variant of Codex.CodingAgent without approval request handling
  or DynamicTool integration. Communicates via the same JSON-RPC 2.0 stdio
  protocol used by the Codex app-server.
  """

  @version Mix.Project.config()[:version]

  @behaviour Aiur.CodingAgent

  require Logger
  alias Aiur.{AgentEnvironment, Config}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          port: port(),
          metadata: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          model: String.t() | nil
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    model = Keyword.get(opts, :model)

    with :ok <- validate_workspace_cwd(workspace),
         {:ok, port} <- start_port(workspace) do
      metadata = port_metadata(port)
      Aiur.ProcessReaper.register(:agent, {:os_pid, metadata[:claude_app_server_pid]}, comm: "claude")
      expanded_workspace = Path.expand(workspace)

      case do_start_session(port, expanded_workspace) do
        {:ok, thread_id} ->
          {:ok,
           %{
             port: port,
             metadata: metadata,
             thread_id: thread_id,
             workspace: expanded_workspace,
             model: model
           }}

        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:paused, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          thread_id: thread_id,
          workspace: workspace
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    on_safe_checkpoint = Keyword.get(opts, :on_safe_checkpoint, fn _checkpoint -> :noop end)
    model = Map.get(session, :model)

    case start_turn(port, thread_id, prompt, issue, workspace, model) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Claude session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(session, on_message, on_safe_checkpoint, turn_id) do
          {:ok, result} ->
            Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:paused, payload} ->
            Logger.info("Claude session paused for #{issue_context(issue)} session_id=#{session_id}")
            {:paused, Map.put(payload, :session_id, session_id)}

          {:error, reason} ->
            Logger.warning("Claude session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Claude session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  @spec send_operator_message(session(), Aiur.CodingAgent.operator_payload()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(
        %{port: port, thread_id: thread_id, workspace: workspace} = session,
        %{kind: :text, body: text}
      )
      when is_port(port) and is_binary(thread_id) and is_binary(text) do
    request_id = :erlang.unique_integer([:positive])

    frame = %{
      "method" => "turn/start",
      "id" => request_id,
      "params" =>
        maybe_put_model(
          %{
            "threadId" => thread_id,
            "input" => [%{"type" => "text", "text" => text}],
            "cwd" => workspace
          },
          Map.get(session, :model)
        )
    }

    send_message(port, frame)
    {:ok, request_id}
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  def send_operator_message(_session, _payload), do: {:error, :invalid_session}

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())

    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace_cwd, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  defp start_port(workspace) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(AgentEnvironment.scrub_shell_command(Aiur.Claude.Config.command()))],
            cd: String.to_charlist(workspace),
            env: AgentEnvironment.workspace_env(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} ->
        %{claude_app_server_pid: to_string(os_pid)}

      _ ->
        %{}
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "aiur-orchestrator",
          "title" => "Aiur Orchestrator",
          "version" => @version
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp do_start_session(port, workspace) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(port, workspace) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "permissionMode" => Aiur.Claude.Config.permission_mode(),
        "cwd" => Path.expand(workspace)
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(port, thread_id, prompt, issue, workspace, model) do
    params =
      maybe_put_model(
        %{
          "threadId" => thread_id,
          "input" => [
            %{
              "type" => "text",
              "text" => prompt
            }
          ],
          "cwd" => Path.expand(workspace),
          "title" => "#{issue.identifier}: #{issue.title}"
        },
        model
      )

    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => params
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(session, on_message, on_safe_checkpoint, turn_id) do
    receive_loop(session, %{
      on_message: on_message,
      on_safe_checkpoint: on_safe_checkpoint,
      timeout_ms: Config.agent_turn_timeout_ms(),
      pending_line: "",
      outstanding_turns: 1,
      pending_operator_requests: %{},
      current_turn_id: turn_id,
      pause_request_id: nil,
      pending_interrupt_request_id: nil,
      interrupt_action: nil
    })
  end

  defp receive_loop(%{port: port} = session, state) do
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
        {:error, {:port_exit, status}}

      {:pause_agent, request_id} when is_integer(request_id) ->
        case handle_pause_request(session, state, request_id) do
          {:continue, next_state} -> receive_loop(session, next_state)
          result -> result
        end

      {:agent_queue_updated, _issue_identifier, _item_id, true} ->
        case handle_operator_queue_update(session, state) do
          {:continue, next_state} -> receive_loop(session, next_state)
          result -> result
        end

      {:agent_queue_updated, _issue_identifier, _item_id, false} ->
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
        handle_malformed_incoming(state, payload_string, port, on_message)
    end
  end

  defp handle_decoded_incoming(_session, state, %{"id" => request_id, "result" => _}, _payload_string, _port, _on_message)
       when request_id == state.pending_interrupt_request_id do
    {:continue, %{state | pending_interrupt_request_id: nil}}
  end

  defp handle_decoded_incoming(_session, state, %{"id" => request_id, "error" => error}, _payload_string, _port, _on_message)
       when request_id == state.pending_interrupt_request_id do
    {:error, {:turn_interrupt_failed, error}}
  end

  defp handle_decoded_incoming(session, state, %{"id" => request_id, "result" => _} = payload, payload_string, _port, _on_message)
       when is_integer(request_id) do
    handle_pending_operator_response(session, state, payload, payload_string, request_id)
  end

  defp handle_decoded_incoming(session, state, %{"id" => request_id, "error" => _} = payload, payload_string, _port, _on_message)
       when is_integer(request_id) do
    handle_pending_operator_response(session, state, payload, payload_string, request_id)
  end

  defp handle_decoded_incoming(_session, state, %{"method" => "turn/completed"} = payload, payload_string, port, on_message) do
    emit_message(
      on_message,
      :turn_completed,
      %{payload: payload, raw: payload_string},
      metadata_from_message(port, payload)
    )

    case turn_completion_status(payload) do
      "interrupted" -> continue_after_turn_interrupted(state, payload)
      _ -> continue_after_turn_completion(state)
    end
  end

  defp handle_decoded_incoming(_session, state, %{"method" => "turn/failed", "params" => params} = payload, payload_string, port, on_message) do
    emit_message(
      on_message,
      :turn_failed,
      %{payload: payload, raw: payload_string, details: params},
      metadata_from_message(port, payload)
    )

    fail_pending_operator_requests(state.pending_operator_requests, {:turn_failed, params})
    {:error, {:turn_failed, params}}
  end

  defp handle_decoded_incoming(session, state, %{"method" => method} = payload, payload_string, port, on_message)
       when is_binary(method) do
    emit_message(
      on_message,
      :notification,
      %{payload: payload, raw: payload_string},
      metadata_from_message(port, payload)
    )

    Logger.debug("Claude notification: #{inspect(method)}")
    {:continue, maybe_process_safe_checkpoint(session, state, %{kind: :notification, method: method})}
  end

  defp handle_decoded_incoming(_session, state, payload, payload_string, port, on_message) do
    emit_message(
      on_message,
      :other_message,
      %{payload: payload, raw: payload_string},
      metadata_from_message(port, payload)
    )

    {:continue, state}
  end

  defp handle_malformed_incoming(state, payload_string, port, on_message) do
    log_non_json_stream_line(payload_string, "turn stream")

    emit_message(
      on_message,
      :malformed,
      %{payload: payload_string, raw: payload_string},
      metadata_from_message(port, %{raw: payload_string})
    )

    {:continue, state}
  end

  defp handle_pending_operator_response(session, state, payload, payload_string, request_id) do
    on_message = state.on_message

    case Map.pop(state.pending_operator_requests, request_id) do
      {nil, _pending_operator_requests} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(session.port, payload)
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

  defp maybe_process_safe_checkpoint(session, state, checkpoint) do
    case state.on_safe_checkpoint.(checkpoint) do
      :noop ->
        state

      {:deliver_text, text, on_success, on_failure}
      when is_binary(text) and is_function(on_success, 1) and is_function(on_failure, 1) ->
        case send_operator_message(session, %{kind: :text, body: text}) do
          {:ok, request_id} ->
            pending_operator_requests =
              Map.put(state.pending_operator_requests, request_id, %{
                on_success: on_success,
                on_failure: on_failure,
                text: text
              })

            %{state | pending_operator_requests: pending_operator_requests}

          {:error, reason} ->
            safe_invoke_failure_callback(on_failure, reason)
            state
        end
    end
  end

  defp fail_pending_operator_requests(pending_operator_requests, reason) do
    Enum.each(pending_operator_requests, fn {_request_id, pending_request} ->
      safe_invoke_failure_callback(pending_request.on_failure, reason)
    end)
  end

  defp continue_after_turn_completion(state) do
    next_state = %{state | outstanding_turns: max(state.outstanding_turns - 1, 0)}

    if next_state.outstanding_turns == 0 and map_size(next_state.pending_operator_requests) == 0 do
      {:ok, :turn_completed}
    else
      {:continue, next_state}
    end
  end

  defp continue_after_turn_interrupted(state, payload) do
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

  defp handle_claimed_operator_response(
         session,
         state,
         %{"result" => %{"turn" => %{"id" => turn_id}}} = payload,
         payload_string,
         request_id,
         on_success,
         _on_failure,
         pending_operator_requests
       ) do
    safe_invoke_success_callback(on_success, %{
      request_id: request_id,
      turn_id: turn_id,
      payload: payload
    })

    emit_message(
      state.on_message,
      :operator_turn_started,
      %{payload: payload, raw: payload_string},
      metadata_from_message(session.port, payload)
    )

    {:continue,
     %{
       state
       | pending_operator_requests: pending_operator_requests,
         outstanding_turns: state.outstanding_turns + 1
     }}
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
    safe_invoke_failure_callback(on_failure, {:response_error, error})
    maybe_finish_after_pending_response(%{state | pending_operator_requests: pending_operator_requests})
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

  defp maybe_finish_after_pending_response(state) do
    if state.outstanding_turns == 0 and map_size(state.pending_operator_requests) == 0 do
      {:ok, :turn_completed}
    else
      {:continue, state}
    end
  end

  defp handle_pause_request(_session, %{pause_request_id: request_id} = state, request_id)
       when is_integer(request_id) do
    {:continue, state}
  end

  defp handle_pause_request(_session, %{pause_request_id: existing_request_id} = state, _request_id)
       when is_integer(existing_request_id) do
    {:continue, state}
  end

  defp handle_pause_request(session, state, request_id) do
    case interrupt_turn(session, state.current_turn_id) do
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

  defp handle_operator_queue_update(_session, %{pending_interrupt_request_id: request_id} = state)
       when is_integer(request_id) do
    {:continue, state}
  end

  defp handle_operator_queue_update(session, state) do
    case interrupt_turn(session, state.current_turn_id) do
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

  defp interrupt_turn(%{port: port, thread_id: thread_id}, turn_id)
       when is_port(port) and is_binary(thread_id) and is_binary(turn_id) do
    request_id = :erlang.unique_integer([:positive])

    send_message(port, %{
      "method" => "turn/interrupt",
      "id" => request_id,
      "params" => %{
        "threadId" => thread_id,
        "turnId" => turn_id
      }
    })

    {:ok, request_id}
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  defp interrupt_turn(_session, _turn_id), do: {:error, :invalid_session}

  defp turn_completion_status(%{"params" => %{"turn" => %{"status" => status}}}) when is_binary(status),
    do: status

  defp turn_completion_status(%{"turn" => %{"status" => status}}) when is_binary(status), do: status
  defp turn_completion_status(_payload), do: "completed"

  defp safe_invoke_success_callback(callback, payload) when is_function(callback, 1) do
    callback.(payload)
  rescue
    _error -> :ok
  end

  defp safe_invoke_failure_callback(callback, reason) when is_function(callback, 1) do
    callback.(reason)
  rescue
    _error -> :ok
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.agent_read_timeout_ms(), "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude #{stream_label} output: #{text}")
      else
        Logger.debug("Claude #{stream_label} output: #{text}")
      end
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        case :erlang.port_info(port, :os_pid) do
          {:os_pid, os_pid} -> Aiur.ProcessReaper.unregister({:os_pid, os_pid})
          _ -> :ok
        end

        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  @spec normalize_event(map()) :: map()
  def normalize_event(event) when is_map(event) do
    event
    |> normalize_usage()
    |> normalize_rate_limits()
  end

  defp normalize_usage(event) do
    raw = event[:usage] || Map.get(event, "usage")

    usage =
      if is_map(raw) do
        input =
          token_value(
            raw,
            ~w(input_tokens prompt_tokens inputTokens promptTokens)a ++
              ~w(input_tokens prompt_tokens inputTokens promptTokens)
          )

        output =
          token_value(
            raw,
            ~w(output_tokens completion_tokens outputTokens completionTokens)a ++
              ~w(output_tokens completion_tokens outputTokens completionTokens)
          )

        total = token_value(raw, ~w(total_tokens total totalTokens)a ++ ~w(total_tokens total totalTokens))

        if input || output || total do
          %{input_tokens: input || 0, output_tokens: output || 0, total_tokens: total || 0}
        end
      end

    Map.put(event, :usage, usage)
  end

  defp normalize_rate_limits(event) do
    raw = event[:rate_limits] || Map.get(event, "rate_limits")
    Map.put(event, :rate_limits, raw)
  end

  defp token_value(map, keys) do
    Enum.find_value(keys, fn key ->
      map |> Map.get(key) |> parse_token_value()
    end)
  end

  defp parse_token_value(v) when is_integer(v) and v >= 0, do: v

  defp parse_token_value(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_token_value(_), do: nil

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata() |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    params = Map.get(payload, "params") || Map.get(payload, :params) || %{}

    metadata
    |> put_if_map(:usage, find_in(payload, params, "usage", :usage))
    |> put_if_number(:cost_usd, find_in(payload, params, "cost_usd", :cost_usd))
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp find_in(top, params, str_key, atom_key) do
    Map.get(top, str_key) || Map.get(top, atom_key) ||
      Map.get(params, str_key) || Map.get(params, atom_key)
  end

  defp put_if_map(metadata, key, value) when is_map(value), do: Map.put(metadata, key, value)
  defp put_if_map(metadata, _key, _value), do: metadata

  defp put_if_number(metadata, key, value) when is_number(value),
    do: Map.put(metadata, key, value)

  defp put_if_number(metadata, _key, _value), do: metadata

  defp default_on_message(_message), do: :ok

  defp maybe_put_model(params, override) do
    case override || Aiur.Claude.Config.model() do
      model when is_binary(model) -> Map.put(params, "model", model)
      _ -> params
    end
  end

  defp send_message(port, message) do
    line = message |> Map.put("jsonrpc", "2.0") |> Jason.encode!()
    Port.command(port, line <> "\n")
  end
end
