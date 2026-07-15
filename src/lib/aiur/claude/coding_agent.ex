defmodule Aiur.Claude.CodingAgent do
  @moduledoc """
  Claude Code app-server backend implementing the CodingAgent behaviour.

  Simplified variant of Codex.CodingAgent without approval request handling.
  Communicates via the same JSON-RPC 2.0 stdio protocol used by the Codex
  app-server and advertises the same Aiur DynamicTool surface.
  """

  @behaviour Aiur.CodingAgent.Backend
  @behaviour Aiur.AppServer.Adapter

  require Logger
  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.AppServer.{Adapter, Messages, OperatorDelivery, Rpc, TurnState}
  alias Aiur.Claude.NotificationPolicy
  alias Aiur.Claude.RemoteControl
  alias Aiur.Codex.AppServerPort
  alias Aiur.Codex.DynamicTool
  alias Aiur.Config

  @thread_start_id 2
  @turn_start_id 3

  @type session :: %{
          port: port(),
          metadata: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          model: String.t() | nil
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @impl Aiur.CodingAgent.Backend
  def start_session(workspace, opts \\ []) do
    model = Keyword.get(opts, :model)
    identifier = Keyword.get(opts, :identifier)
    on_provider_started = Keyword.get(opts, :on_provider_started, fn _provider -> :ok end)

    with :ok <- validate_workspace_cwd(workspace),
         {:ok, port} <- start_port(workspace, on_provider_started) do
      metadata = port_metadata(port)

      Aiur.ProcessReaper.register(:agent, {:os_pid, metadata[:claude_app_server_pid]},
        comm: "claude",
        ticket: identifier,
        backend: "claude",
        worker_host: nil,
        remote: false
      )

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
  @impl Aiur.CodingAgent.Backend
  def run_turn(
        %{
          thread_id: thread_id,
          workspace: workspace
        } = session,
        prompt,
        issue,
        opts \\ []
      )
      when is_binary(thread_id) and is_binary(workspace) do
    Adapter.run_turn(__MODULE__, session, prompt, issue, opts)
  end

  @spec stop_session(session()) :: :ok
  @impl Aiur.CodingAgent.Backend
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  @spec send_operator_message(session(), Aiur.CodingAgent.operator_payload()) ::
          {:ok, integer()} | {:error, term()}
  @impl Aiur.CodingAgent.Backend
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

    case send_frame(port, frame) do
      :ok -> {:ok, request_id}
      {:error, reason} -> {:error, reason}
    end
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

  defp start_port(workspace, on_provider_started) do
    Adapter.start_port(workspace, Aiur.Claude.Config.command(), fn port ->
      on_provider_started.(provider_metadata(port))
    end)
  end

  defp provider_metadata(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} ->
        %{root_pid: os_pid}
        |> maybe_put_process_group(AppServerPort.process_group_for_pid(os_pid))
        |> Map.put(:descendant_pids, RemoteControl.process_tree(os_pid))

      _ ->
        %{}
    end
  end

  defp maybe_put_process_group(provider, group) when is_integer(group) and group > 0,
    do: Map.put(provider, :process_group_id, group)

  defp maybe_put_process_group(provider, _group), do: provider

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} ->
        %{claude_app_server_pid: to_string(os_pid)}

      _ ->
        %{}
    end
  end

  defp send_initialize(port) do
    send_frame(port, Messages.initialize_frame())

    with {:ok, _} <- await_response(port, Messages.initialize_id()) do
      send_frame(port, Messages.initialized_frame())
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
    send_frame(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "permissionMode" => Aiur.Claude.Config.permission_mode(),
        "cwd" => Path.expand(workspace),
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

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec start_turn(session(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def start_turn(%{port: port, thread_id: thread_id, workspace: workspace} = session, prompt, issue) do
    model = Map.get(session, :model)

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

    send_frame(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => params
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec backend_label() :: String.t()
  def backend_label, do: "Claude"

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec loop_state_extras(session()) :: map()
  def loop_state_extras(_session), do: %{}

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec handle_interrupt_error(map(), term()) :: {:error, term()}
  def handle_interrupt_error(_state, error), do: {:error, {:turn_interrupt_failed, error}}

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec handle_method(map(), map(), map(), String.t(), String.t()) :: term()
  def handle_method(session, state, %{"method" => "turn/completed"} = payload, payload_string, _method) do
    Messages.emit_message(
      state.on_message,
      :turn_completed,
      %{payload: payload, raw: payload_string},
      metadata_from_message(session.port, payload)
    )

    case TurnState.turn_completion_status(payload) do
      "interrupted" -> TurnState.continue_after_turn_interrupted(state, payload)
      _ -> TurnState.continue_after_turn_completion(state)
    end
  end

  def handle_method(session, state, %{"method" => "turn/failed", "params" => params} = payload, payload_string, _method) do
    Messages.emit_message(
      state.on_message,
      :turn_failed,
      %{payload: payload, raw: payload_string, details: params},
      metadata_from_message(session.port, payload)
    )

    TurnState.fail_pending_operator_requests(state.pending_operator_requests, {:turn_failed, params})

    if NotificationPolicy.usage_limit_exhausted?(params) do
      {:paused, NotificationPolicy.usage_limit_pause(params)}
    else
      {:error, {:turn_failed, params}}
    end
  end

  def handle_method(
        session,
        state,
        %{"method" => "item/tool/call", "id" => id, "params" => params} = payload,
        payload_string,
        _method
      ) do
    metadata = metadata_from_message(session.port, payload)
    tool_name = Messages.tool_call_name(params)
    arguments = Messages.tool_call_arguments(params)

    result =
      state.tool_executor
      |> ToolExecutor.execute(tool_name, arguments, Messages.tool_call_id(params, id))
      |> Messages.normalize_tool_result(%{workspace: session.workspace, response_id: id})

    send_frame(session.port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    Messages.emit_message(state.on_message, event, %{payload: payload, raw: payload_string}, metadata)

    {:continue, OperatorDelivery.maybe_process_safe_checkpoint(session, state, %{kind: :tool_result, method: "item/tool/call"})}
  end

  def handle_method(session, state, %{"method" => method} = payload, payload_string, _method)
      when is_binary(method) do
    Messages.emit_message(
      state.on_message,
      :notification,
      %{payload: payload, raw: payload_string},
      metadata_from_message(session.port, payload)
    )

    Logger.debug("Claude notification: #{inspect(method)}")
    {:continue, OperatorDelivery.maybe_process_safe_checkpoint(session, state, %{kind: :notification, method: method})}
  end

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec handle_malformed(map(), String.t(), port()) :: {:continue, map()}
  def handle_malformed(state, payload_string, port) do
    Rpc.log_non_json_stream_line(payload_string, "turn stream", "Claude")

    Messages.emit_message(
      state.on_message,
      :malformed,
      %{payload: payload_string, raw: payload_string},
      metadata_from_message(port, %{raw: payload_string})
    )

    {:continue, state}
  end

  defp await_response(port, request_id) do
    Rpc.with_timeout_response(port, request_id, Config.agent_read_timeout_ms(), "", "Claude")
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
  @impl Aiur.CodingAgent.Backend
  def normalize_event(event) when is_map(event) do
    event
    |> normalize_usage()
    |> normalize_rate_limits()
  end

  defp normalize_usage(event) do
    raw = event[:usage] || Map.get(event, "usage")
    Map.put(event, :usage, Aiur.TokenUsage.canonicalize(raw))
  end

  defp normalize_rate_limits(event) do
    raw = event[:rate_limits] || Map.get(event, "rate_limits")
    Map.put(event, :rate_limits, raw)
  end

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec metadata_from_message(port(), term()) :: map()
  def metadata_from_message(port, payload) do
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

  defp maybe_put_model(params, override) do
    case override || Aiur.Claude.Config.model() do
      model when is_binary(model) -> Map.put(params, "model", model)
      _ -> params
    end
  end

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec send_frame(port(), map()) :: :ok | {:error, :port_closed}
  def send_frame(port, message) do
    line = message |> Map.put("jsonrpc", "2.0") |> Jason.encode!()
    Port.command(port, line <> "\n")
    :ok
  rescue
    # The port (the agent backend's stdin/stdout) has already closed — the
    # backend exited or the peer tore the transport down. Swallow the write so
    # a transport teardown never crashes the turn with an unhandled
    # ArgumentError; the `{:exit_status, ...}` message already queued for this
    # port drives the clean `{:error, {:port_exit, N}}` result.
    ArgumentError -> {:error, :port_closed}
  end
end
