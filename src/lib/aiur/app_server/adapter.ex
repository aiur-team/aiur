defmodule Aiur.AppServer.Adapter do
  @moduledoc """
  Behaviour and shared run skeleton for app-server coding-agent backends.
  """

  require Logger

  alias Aiur.AppServer.{Messages, TurnLoop}
  alias Aiur.{AgentEnvironment, Config}
  alias Aiur.Claude.RemoteControl
  alias Aiur.Codex.DynamicTool

  @port_line_bytes 1_048_576

  @callback backend_label() :: String.t()
  @callback send_frame(port(), map()) :: :ok | {:error, :port_closed}
  @callback metadata_from_message(port(), term()) :: map()
  @callback start_turn(session :: map(), prompt :: String.t(), issue :: map()) ::
              {:ok, String.t()} | {:error, term()}
  @callback loop_state_extras(session :: map()) :: map()
  @callback handle_interrupt_error(state :: map(), error :: term()) ::
              {:continue, map()} | {:error, term()}
  @callback handle_method(
              session :: map(),
              state :: map(),
              payload :: map(),
              payload_string :: String.t(),
              method :: String.t()
            ) :: term()
  @callback handle_malformed(state :: map(), payload_string :: String.t(), port()) ::
              {:continue, map()}

  @spec run_turn(module(), map(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:paused, map()} | {:error, term()}
  def run_turn(backend, %{port: _port} = session, prompt, issue, opts) do
    on_message = Keyword.get(opts, :on_message, &Messages.default_on_message/1)
    on_safe_checkpoint = Keyword.get(opts, :on_safe_checkpoint, fn _checkpoint -> :noop end)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments)
      end)

    case pause_latched?(session) do
      true ->
        {:paused, %{request_id: :containment, turn_id: nil, details: :pause_latched_before_turn}}

      false ->
        run_started_turn(backend, session, prompt, issue, on_message, on_safe_checkpoint, tool_executor)
    end
  end

  defp run_started_turn(backend, session, prompt, issue, on_message, on_safe_checkpoint, tool_executor) do
    metadata = session.metadata
    thread_id = session.thread_id

    case backend.start_turn(session, prompt, issue) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("#{backend.backend_label()} session started for #{Messages.issue_context(issue)} session_id=#{session_id}")

        Messages.emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        state =
          Map.merge(
            %{
              backend: backend,
              on_message: on_message,
              on_safe_checkpoint: on_safe_checkpoint,
              tool_executor: tool_executor,
              timeout_ms: Config.agent_turn_timeout_ms(),
              pending_line: "",
              outstanding_turns: 1,
              pending_operator_requests: %{},
              current_turn_id: turn_id,
              issue_identifier: Messages.issue_identifier(issue),
              pause_request_id: nil,
              pending_interrupt_request_id: nil,
              interrupt_action: nil
            },
            backend.loop_state_extras(session)
          )

        loop_result = TurnLoop.receive_loop(session, state)
        handle_turn_result(backend, issue, session_id, thread_id, turn_id, metadata, on_message, loop_result)

      {:error, reason} ->
        Logger.warning("#{backend.backend_label()} turn start failed for #{Messages.issue_context(issue)}: #{inspect(reason)}")
        Messages.emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, {:turn_start_failed, reason}}
    end
  end

  defp pause_latched?(session), do: Aiur.PauseContainment.paused?(Map.get(session, :containment))

  @spec start_port(Path.t(), String.t()) :: {:ok, port()} | {:error, :bash_not_found}
  def start_port(workspace, command), do: start_port(workspace, command, fn _port -> :ok end)

  @doc false
  @spec start_port(Path.t(), String.t(), (port() -> term())) :: {:ok, port()} | {:error, :bash_not_found}
  def start_port(workspace, command, on_port_started) when is_function(on_port_started, 1) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      # The BEAM's port spawn already places each program in its own session and
      # process group (os_pid == pgid). That makes the app-server and its tool
      # descendants targetable as one recorded group after their immediate parent
      # exits, without ever selecting by workspace cwd. An explicit `setsid`
      # wrapper here would fork and leave os_pid a dead stub, orphaning the real
      # leader from both containment and the pgrep-anchored teardown walk.
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(AgentEnvironment.scrub_shell_command(command))],
            cd: String.to_charlist(workspace),
            env: AgentEnvironment.workspace_env(workspace),
            line: @port_line_bytes
          ]
        )

      # Invoke this while the spawn primitive still owns control. Callers use
      # it to record the local process-group lease before any handshake or
      # session setup can expose a live descendant to an abrupt runner death.
      case on_port_started.(port) do
        :ok ->
          {:ok, port}

        {:error, _reason} = error ->
          terminate_uncontained_port(port)
          error

        _other ->
          terminate_uncontained_port(port)
          {:error, :workspace_ownership_lost}
      end
    end
  end

  defp terminate_uncontained_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> RemoteControl.graceful_kill_tree(os_pid)
      _ -> :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  @doc false
  @spec port_line_bytes() :: pos_integer()
  def port_line_bytes, do: @port_line_bytes

  defp handle_turn_result(backend, issue, session_id, thread_id, turn_id, _metadata, _on_message, {:ok, result}) do
    Logger.info("#{backend.backend_label()} session completed for #{Messages.issue_context(issue)} session_id=#{session_id}")

    {:ok,
     %{
       result: result,
       session_id: session_id,
       thread_id: thread_id,
       turn_id: turn_id
     }}
  end

  defp handle_turn_result(backend, issue, session_id, _thread_id, _turn_id, _metadata, _on_message, {:paused, payload}) do
    Logger.info("#{backend.backend_label()} session paused for #{Messages.issue_context(issue)} session_id=#{session_id}")
    {:paused, Map.put(payload, :session_id, session_id)}
  end

  defp handle_turn_result(backend, issue, session_id, _thread_id, _turn_id, metadata, on_message, {:error, reason}) do
    Logger.warning("#{backend.backend_label()} session ended with error for #{Messages.issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

    Messages.emit_message(
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
end
