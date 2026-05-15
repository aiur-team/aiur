defmodule SymphonyElixir.Codex.CodingAgent do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  @version Mix.Project.config()[:version]

  @behaviour SymphonyElixir.CodingAgent

  require Logger
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t()
        }

  @dialyzer {:nowarn_function, run: 4}
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    case start_session(workspace, opts) do
      {:ok, session} ->
        try do
          run_turn(session, prompt, issue, opts)
        after
          stop_session(session)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id} <- do_start_session(port, expanded_workspace, session_policies) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    on_safe_checkpoint = Keyword.get(opts, :on_safe_checkpoint, fn _checkpoint -> :noop end)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments)
      end)

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

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

        case await_turn_completion(
               session,
               on_message,
               tool_executor,
               auto_approve_requests,
               on_safe_checkpoint,
               turn_id
             ) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:paused, payload} ->
            Logger.info("Codex session paused for #{issue_context(issue)} session_id=#{session_id}")
            {:paused, Map.put(payload, :session_id, session_id)}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

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
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  @spec send_operator_message(session(), SymphonyElixir.CodingAgent.operator_payload()) ::
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
      "params" => %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => text}],
        "cwd" => workspace,
        "approvalPolicy" => Map.get(session, :approval_policy),
        "sandboxPolicy" => Map.get(session, :turn_sandbox_policy)
      }
    }

    send_message(port, frame)
    {:ok, request_id}
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  def send_operator_message(_session, _payload), do: {:error, :invalid_session}

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace_path),
         {:ok, canonical_root} <- PathSafety.canonicalize(workspace_root) do
      canonical_root_prefix = canonical_root <> "/"
      expanded_root_prefix = workspace_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(workspace_path <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, workspace_path, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil) do
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
            args: [~c"-lc", String.to_charlist(SymphonyElixir.Codex.Config.command())],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host) when is_binary(worker_host) do
    SSH.start_port(worker_host, remote_launch_command(workspace), line: @port_line_bytes)
  end

  defp remote_launch_command(workspace) do
    ["cd #{shell_escape(workspace)}", "exec #{SymphonyElixir.Codex.Config.command()}"]
    |> Enum.join(" && ")
  end

  defp port_metadata(port, worker_host \\ nil) when is_port(port) do
    metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(metadata, :worker_host, host)
      _ -> metadata
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
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
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

  defp session_policies(workspace, nil) do
    SymphonyElixir.Codex.Config.runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace, session_policies)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(port, workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => DynamicTool.tool_specs()
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

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(
         session,
         on_message,
         tool_executor,
         auto_approve_requests,
         on_safe_checkpoint,
         turn_id
       ) do
    receive_loop(session, %{
      on_message: on_message,
      on_safe_checkpoint: on_safe_checkpoint,
      timeout_ms: Config.agent_turn_timeout_ms(),
      pending_line: "",
      tool_executor: tool_executor,
      auto_approve_requests: auto_approve_requests,
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
    emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)

    case turn_completion_status(payload) do
      "interrupted" -> continue_after_turn_interrupted(state, payload)
      _ -> continue_after_turn_completion(state)
    end
  end

  defp handle_decoded_incoming(_session, state, %{"method" => "turn/failed", "params" => params} = payload, payload_string, port, on_message) do
    emit_turn_event(on_message, :turn_failed, payload, payload_string, port, params)
    fail_pending_operator_requests(state.pending_operator_requests, {:turn_failed, params})
    {:error, {:turn_failed, params}}
  end

  defp handle_decoded_incoming(_session, state, %{"method" => "turn/cancelled", "params" => params} = payload, payload_string, port, on_message) do
    emit_turn_event(on_message, :turn_cancelled, payload, payload_string, port, params)
    fail_pending_operator_requests(state.pending_operator_requests, {:turn_cancelled, params})

    if is_integer(state.pause_request_id) do
      {:paused,
       %{
         request_id: state.pause_request_id,
         turn_id: state.current_turn_id,
         details: params
       }}
    else
      {:error, {:turn_cancelled, params}}
    end
  end

  defp handle_decoded_incoming(session, state, %{"method" => method} = payload, payload_string, _port, _on_message)
       when is_binary(method) do
    handle_turn_method(session, state, payload, payload_string, method)
  end

  defp handle_decoded_incoming(_session, state, payload, payload_string, port, on_message) do
    emit_message(
      on_message,
      :other_message,
      %{
        payload: payload,
        raw: payload_string
      },
      metadata_from_message(port, payload)
    )

    {:continue, state}
  end

  defp handle_malformed_incoming(state, payload_string, port, on_message) do
    log_non_json_stream_line(payload_string, "turn stream")

    if protocol_message_candidate?(payload_string) do
      emit_message(
        on_message,
        :malformed,
        %{
          payload: payload_string,
          raw: payload_string
        },
        metadata_from_message(port, %{raw: payload_string})
      )
    end

    {:continue, state}
  end

  defp protocol_message_candidate?(payload_string) do
    payload_string
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?(["{", "["])
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(%{port: port} = session, state, payload, payload_string, method) do
    on_message = state.on_message
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           state.tool_executor,
           state.auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        {:continue, maybe_process_safe_checkpoint(session, state, checkpoint_for_method(method))}

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          {:continue, maybe_process_safe_checkpoint(session, state, checkpoint_for_method(method))}
        end
    end
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

  defp checkpoint_for_method("item/tool/call"), do: %{kind: :tool_result, method: "item/tool/call"}
  defp checkpoint_for_method(method), do: %{kind: :notification, method: method}

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

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result = normalize_tool_result(tool_executor.(tool_name, arguments))

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_tool_result(%{"output" => _output} = result), do: result

  defp normalize_tool_result(%{"contentItems" => [%{"text" => output} | _]} = result)
       when is_binary(output) do
    Map.put(result, "output", output)
  end

  defp normalize_tool_result(result), do: result

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
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
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
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
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  @spec normalize_event(map()) :: map()
  def normalize_event(event) when is_map(event) do
    event
    |> normalize_usage()
    |> normalize_rate_limits()
  end

  defp normalize_usage(event) do
    payloads = [
      event[:usage],
      Map.get(event, "usage"),
      event[:payload],
      Map.get(event, "payload"),
      event
    ]

    usage =
      Enum.find_value(payloads, &absolute_token_usage/1) ||
        Enum.find_value(payloads, &turn_completed_usage/1) ||
        Enum.find_value(payloads, &direct_token_map/1)

    Map.put(event, :usage, canonicalize_usage(usage))
  end

  defp normalize_rate_limits(event) do
    raw =
      find_rate_limits(event[:rate_limits]) ||
        find_rate_limits(Map.get(event, "rate_limits")) ||
        find_rate_limits(event[:payload]) ||
        find_rate_limits(Map.get(event, "payload")) ||
        find_rate_limits(event)

    Map.put(event, :rate_limits, raw)
  end

  defp absolute_token_usage(payload) when is_map(payload) do
    paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    Enum.find_value(paths, fn path ->
      value = dig(payload, path)
      if is_map(value) and has_token_field?(value), do: value
    end)
  end

  defp absolute_token_usage(_), do: nil

  defp turn_completed_usage(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") || Map.get(payload, :usage) ||
          dig(payload, ["params", "usage"]) || dig(payload, [:params, :usage])

      if is_map(direct) and has_token_field?(direct), do: direct
    end
  end

  defp turn_completed_usage(_), do: nil

  defp direct_token_map(payload) when is_map(payload) do
    if has_token_field?(payload), do: payload
  end

  defp direct_token_map(_), do: nil

  defp canonicalize_usage(nil), do: nil

  defp canonicalize_usage(raw) when is_map(raw) do
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

  defp has_token_field?(map) when is_map(map) do
    token_keys =
      ~w(input_tokens output_tokens total_tokens prompt_tokens completion_tokens
                    inputTokens outputTokens totalTokens promptTokens completionTokens)a ++
        ~w(input_tokens output_tokens total_tokens prompt_tokens completion_tokens
                    inputTokens outputTokens totalTokens promptTokens completionTokens)

    Enum.any?(token_keys, fn key ->
      map |> Map.get(key) |> token_like_value?()
    end)
  end

  defp has_token_field?(_), do: false

  defp token_like_value?(v) when is_integer(v) and v >= 0, do: true

  defp token_like_value?(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, _} when n >= 0 -> true
      _ -> false
    end
  end

  defp token_like_value?(_), do: false

  defp find_rate_limits(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) -> direct
      rate_limits_map?(payload) -> payload
      true -> search_rate_limits(payload)
    end
  end

  defp find_rate_limits(_), do: nil

  defp search_rate_limits(payload) when is_map(payload) do
    Enum.find_value(Map.values(payload), fn
      value when is_map(value) -> find_rate_limits(value)
      _ -> nil
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    has_id =
      !is_nil(
        Map.get(payload, "limit_id") || Map.get(payload, :limit_id) ||
          Map.get(payload, "limit_name") || Map.get(payload, :limit_name)
      )

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    has_id and has_buckets
  end

  defp rate_limits_map?(_), do: false

  defp dig(map, []), do: map

  defp dig(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nil -> nil
      value -> dig(value, rest)
    end
  end

  defp dig(_, _), do: nil

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata() |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
