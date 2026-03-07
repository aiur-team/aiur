defmodule SymphonyElixir.Claude.CodingAgent do
  @moduledoc """
  Claude Code app-server backend implementing the CodingAgent behaviour.

  Simplified variant of Codex.CodingAgent without approval request handling
  or DynamicTool integration. Communicates via the same JSON-RPC 2.0 stdio
  protocol used by the Codex app-server.
  """

  @version Mix.Project.config()[:version]

  @behaviour SymphonyElixir.CodingAgent

  require Logger
  alias SymphonyElixir.Config

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          port: port(),
          metadata: map(),
          thread_id: String.t(),
          workspace: Path.t()
        }

  @spec start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace) do
    with :ok <- validate_workspace_cwd(workspace),
         {:ok, port} <- start_port(workspace) do
      metadata = port_metadata(port)
      expanded_workspace = Path.expand(workspace)

      case do_start_session(port, expanded_workspace) do
        {:ok, thread_id} ->
          {:ok,
           %{
             port: port,
             metadata: metadata,
             thread_id: thread_id,
             workspace: expanded_workspace
           }}

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
          thread_id: thread_id,
          workspace: workspace
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    case start_turn(port, thread_id, prompt, issue, workspace) do
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

        case await_turn_completion(port, on_message) do
          {:ok, result} ->
            Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

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
            args: [~c"-lc", String.to_charlist(SymphonyElixir.Claude.Config.command())],
            cd: String.to_charlist(workspace),
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
        "permissionMode" => "bypassPermissions",
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

  defp start_turn(port, thread_id, prompt, issue, workspace) do
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
        "cwd" => Path.expand(workspace),
        "title" => "#{issue.identifier}: #{issue.title}"
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message) do
    receive_loop(port, on_message, Config.agent_turn_timeout_ms(), "")
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk)
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_message(
          on_message,
          :turn_completed,
          %{payload: payload, raw: payload_string},
          metadata_from_message(port, payload)
        )

        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_message(
          on_message,
          :turn_failed,
          %{payload: payload, raw: payload_string, details: Map.get(payload, "params")},
          metadata_from_message(port, payload)
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload} when is_binary(method) ->
        emit_message(
          on_message,
          :notification,
          %{payload: payload, raw: payload_string},
          metadata_from_message(port, payload)
        )

        Logger.debug("Claude notification: #{inspect(method)}")
        receive_loop(port, on_message, timeout_ms, "")

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{payload: payload, raw: payload_string},
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "")

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        emit_message(
          on_message,
          :malformed,
          %{payload: payload_string, raw: payload_string},
          metadata_from_message(port, %{raw: payload_string})
        )

        receive_loop(port, on_message, timeout_ms, "")
    end
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

  defp send_message(port, message) do
    line = message |> Map.put("jsonrpc", "2.0") |> Jason.encode!()
    Port.command(port, line <> "\n")
  end
end
