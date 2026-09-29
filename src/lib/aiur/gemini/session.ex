defmodule Aiur.Gemini.Session do
  @moduledoc "Starts a ticket-scoped Gemini ACP session and owns its tool gateway."

  alias Aiur.AgentTools.MCP
  alias Aiur.Gemini.{Protocol, Transport}
  alias Aiur.{PauseContainment, ProcessReaper}

  @timeout 30_000

  def start(workspace, opts) do
    config = Keyword.get_lazy(opts, :config, fn -> Aiur.Config.backend_config("gemini") end)
    command = Keyword.get(opts, :command, Map.get(config, "command", "gemini --acp"))
    workspace = Path.expand(workspace)

    cond do
      Keyword.get(opts, :worker_host) ->
        {:error, :remote_worker_unsupported}

      Keyword.get(opts, :remote_control) ->
        {:error, :remote_control_unsupported}

      Keyword.get(opts, :effort) ->
        {:error, :gemini_effort_unsupported}

      command == "gemini --acp" and is_nil(System.find_executable("gemini")) ->
        {:error, :gemini_cli_not_installed}

      true ->
        launch(workspace, command, opts)
    end
  end

  def stop(%{port: port, gateway: gateway} = session) do
    Transport.stop(port)
    ProcessReaper.unregister({:os_pid, get_in(session, [:metadata, :provider_pid])})
    PauseContainment.unregister(Map.get(session, :containment))
    if Process.alive?(gateway), do: MCP.stop(gateway)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp launch(workspace, command, opts) do
    with {:ok, gateway} <- MCP.start_link(owner: self(), transport: :gemini_mcp) do
      case Transport.start(workspace, command, opts) do
        {:ok, port} ->
          establish(port, gateway, workspace, opts)

        {:error, _} = error ->
          MCP.stop(gateway)
          error
      end
    end
  end

  defp establish(port, gateway, workspace, opts) do
    metadata = Transport.metadata(port)
    ProcessReaper.register(:agent, {:os_pid, metadata[:provider_pid]}, comm: "gemini", ticket: Keyword.get(opts, :identifier), backend: "gemini")
    containment = register_containment(metadata, workspace, opts)
    timeout = Keyword.get(opts, :timeout_ms, @timeout)
    version = Application.spec(:aiur, :vsn) |> to_string()
    server = Protocol.mcp_server(MCP.connection(gateway))

    outcome =
      with {:ok, init} <- Transport.request(port, Protocol.initialize(1, version), timeout),
           {:ok, _capabilities} <- Protocol.validate_initialize(init),
           {:ok, session_id, resumed, result} <- establish_session(port, workspace, server, opts, timeout),
           {:ok, model} <- select_model(port, session_id, result, Keyword.get(opts, :model), timeout),
           :ok <- ensure_approval_mode(port, session_id, result, timeout) do
        {:ok,
         %{
           port: port,
           gateway: gateway,
           workspace: workspace,
           thread_id: session_id,
           resumed: resumed,
           metadata: metadata,
           containment: containment,
           model: model,
           model_catalog: get_in(result, ["models", "availableModels"]),
           cli_version: get_in(init, ["agentInfo", "version"]),
           usage: :unavailable
         }}
      end

    case outcome do
      {:ok, _} ->
        outcome

      {:error, _} = error ->
        stop(%{port: port, gateway: gateway, metadata: metadata, containment: containment})
        error
    end
  end

  defp establish_session(port, workspace, server, opts, timeout) do
    case Keyword.get(opts, :resume_thread_id) do
      id when is_binary(id) and id != "" ->
        frame = Protocol.session(2, "session/load", workspace, [server], id)

        case Transport.request(port, frame, timeout, fn _ -> :ok end) do
          {:ok, result} ->
            {:ok, id, true, result}

          {:error, {:acp_error, %{"message" => message}}} = error ->
            if confirmed_missing?(message, id), do: new_session(port, workspace, server, timeout), else: error

          {:error, _} = error ->
            error
        end

      _ ->
        new_session(port, workspace, server, timeout)
    end
  end

  defp confirmed_missing?(message, id) when is_binary(message) do
    message == "No previous sessions found for this project." or
      String.starts_with?(message, "Invalid session identifier \"#{id}\".")
  end

  defp confirmed_missing?(_, _), do: false

  defp new_session(port, workspace, server, timeout) do
    with {:ok, %{"sessionId" => id} = result} when is_binary(id) and id != "" <-
           Transport.request(port, Protocol.session(2, "session/new", workspace, [server]), timeout) do
      {:ok, id, false, result}
    else
      {:ok, _} -> {:error, :invalid_acp_session_id}
      {:error, _} = error -> error
    end
  end

  defp select_model(_port, _session_id, result, nil, _timeout),
    do: {:ok, get_in(result, ["models", "currentModelId"])}

  defp select_model(port, session_id, result, requested, timeout) when is_binary(requested) do
    available = get_in(result, ["models", "availableModels"]) || []

    if Enum.any?(available, &(&1["modelId"] == requested)) do
      frame = Protocol.request(3, "session/set_model", %{"sessionId" => session_id, "modelId" => requested})

      case Transport.request(port, frame, timeout) do
        {:ok, _} -> {:ok, requested}
        {:error, _} = error -> error
      end
    else
      {:error, {:gemini_model_unavailable, requested}}
    end
  end

  defp ensure_approval_mode(_port, _id, %{"modes" => %{"currentModeId" => "default"}}, _timeout),
    do: :ok

  defp ensure_approval_mode(port, id, %{"modes" => %{"currentModeId" => mode}}, timeout)
       when is_binary(mode) do
    frame = Protocol.request(4, "session/set_mode", %{"sessionId" => id, "modeId" => "default"})

    case Transport.request(port, frame, timeout) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp ensure_approval_mode(_, _, _, _), do: {:error, :gemini_approval_mode_unverified}

  defp register_containment(metadata, workspace, opts) do
    with identifier when is_binary(identifier) <- Keyword.get(opts, :identifier),
         pid when is_binary(pid) <- metadata[:provider_pid],
         group when is_integer(group) <- metadata[:agent_process_group_id],
         {root_pid, ""} <- Integer.parse(pid),
         {:ok, containment} <- PauseContainment.register(identifier, root_pid, group, workspace: workspace) do
      containment
    else
      _ -> nil
    end
  end
end
