defmodule Aiur.Muse.Session do
  @moduledoc "Session startup and teardown for Muse's native MSP process."

  alias Aiur.AgentTools.MCP
  alias Aiur.Config
  alias Aiur.Muse.Defaults
  alias Aiur.Muse.Meters
  alias Aiur.Muse.{Protocol, Transport}
  alias Aiur.{PauseContainment, ProcessReaper}

  @default_timeout_ms 30_000

  @spec start(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(workspace, opts \\ []) do
    if Keyword.get(opts, :worker_host) do
      {:error, :remote_worker_unsupported}
    else
      config = Keyword.get_lazy(opts, :config, fn -> Config.backend_config("muse") end)
      opts = with_config_defaults(opts, config)
      workspace = Path.expand(workspace)

      with {:ok, gateway} <- MCP.start_link(owner: self()) do
        try do
          start_port(workspace, gateway, opts)
        rescue
          error ->
            stop_gateway(gateway)
            {:error, {:startup_exception, error}}
        catch
          kind, reason ->
            stop_gateway(gateway)
            {:error, {:startup_exit, kind, reason}}
        end
      end
    end
  end

  @spec stop(map()) :: :ok
  def stop(%{port: port, gateway: gateway} = session) do
    Meters.retire(session)
    cleanup(port, gateway, Map.get(session, :containment), session.metadata)
    :ok
  end

  defp start_port(workspace, gateway, opts) do
    command = Keyword.fetch!(opts, :command)
    command = if Keyword.fetch!(opts, :trust_workspace), do: command <> " --trust-workspace", else: command
    opts = safe_callbacks(opts)

    case Transport.start(workspace, command, opts) do
      {:ok, port} ->
        try do
          metadata = Transport.metadata(port)
          ProcessReaper.register(:agent, {:os_pid, metadata[:provider_pid]}, comm: "muse", ticket: Keyword.get(opts, :identifier), backend: "muse")
          containment = register_containment(opts, metadata, workspace)
          establish(port, gateway, containment, metadata, workspace, opts)
        rescue
          error ->
            cleanup(port, gateway, nil, Transport.metadata(port))
            {:error, {:startup_exception, error}}
        catch
          kind, reason ->
            cleanup(port, gateway, nil, Transport.metadata(port))
            {:error, {:startup_exit, kind, reason}}
        end

      {:error, _} = error ->
        stop_gateway(gateway)
        error
    end
  end

  defp establish(port, gateway, containment, metadata, workspace, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    mcp_config = %{"mcpServers" => %{"aiur" => MCP.connection(gateway)}}
    version = Application.spec(:aiur, :vsn) |> to_string()

    outcome =
      with {:ok, initialized} <- Transport.request(port, Protocol.initialize_frame(1, version), timeout),
           {:ok, _} <- Protocol.initialize_result(initialized),
           :ok <- Transport.send_frame(port, Protocol.initialized_frame()),
           {:ok, result, resumed?} <- start_or_resume(port, workspace, mcp_config, timeout, opts) do
        {:ok,
         %{
           port: port,
           gateway: gateway,
           thread_id: get_in(result, ["session", "sessionId"]),
           view_cursor: result["viewCursor"],
           resumed: resumed?,
           workspace: workspace,
           metadata: metadata,
           containment: containment,
           model: get_in(result, ["session", "modelId"]),
           provider_id: get_in(result, ["session", "providerId"]),
           effort: Keyword.get(opts, :effort),
           approval_mode: get_in(result, ["session", "approvalMode", "mode"])
         }}
      end

    case outcome do
      {:ok, session} ->
        session = Meters.attach(session)
        Meters.refresh(session)
        {:ok, session}

      {:error, _} = error ->
        cleanup(port, gateway, containment, metadata)
        error
    end
  end

  defp start_or_resume(port, workspace, mcp_config, timeout, opts) do
    case Keyword.get(opts, :resume_thread_id) do
      session_id when is_binary(session_id) and session_id != "" ->
        frame = Protocol.session_resume_frame(2, session_id, config: mcp_config, exclude_items: true)

        with {:ok, result} <- Transport.request(port, frame, timeout),
             {:ok, %{"session" => %{"sessionId" => ^session_id}}} <- Protocol.session_result(result) do
          {:ok, result, true}
        else
          {:error, {:msp_error, %{"code" => -32_020}}} ->
            fresh_start(port, workspace, mcp_config, timeout, opts)

          {:error, _} = error ->
            error

          {:ok, _} ->
            {:error, :resume_session_mismatch}
        end

      _ ->
        fresh_start(port, workspace, mcp_config, timeout, opts)
    end
  end

  defp fresh_start(port, workspace, mcp_config, timeout, opts) do
    frame_opts = [config: mcp_config, approval_mode: Keyword.get(opts, :approval_mode, Defaults.approval_mode())]
    frame_opts = if Keyword.get(opts, :model), do: Keyword.put(frame_opts, :model_id, Keyword.fetch!(opts, :model)), else: frame_opts
    frame_opts = if Keyword.get(opts, :provider_id), do: Keyword.put(frame_opts, :provider_id, Keyword.fetch!(opts, :provider_id)), else: frame_opts

    with {:ok, result} <- Transport.request(port, Protocol.session_start_frame(3, workspace, frame_opts), timeout),
         {:ok, result} <- Protocol.session_result(result) do
      {:ok, result, false}
    end
  end

  defp register_containment(opts, metadata, workspace) do
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

  defp cleanup(port, gateway, containment, metadata) do
    Transport.stop(port)
  after
    ProcessReaper.unregister({:os_pid, metadata[:provider_pid]})
    PauseContainment.unregister(containment)
    stop_gateway(gateway)
  end

  defp with_config_defaults(opts, config) do
    Enum.reduce(
      [
        command: {"command", Defaults.command()},
        trust_workspace: {"trust_workspace", false},
        approval_mode: {"approval_mode", Defaults.approval_mode()},
        model: {"model", nil},
        provider_id: {"provider_id", nil}
      ],
      opts,
      fn {key, {config_key, default}}, acc -> Keyword.put_new(acc, key, Map.get(config, config_key, default)) end
    )
  end

  defp safe_callbacks(opts) do
    Enum.reduce([:on_provider_started, :on_process_group_started], opts, fn key, acc ->
      callback = Keyword.get(opts, key, fn _ -> :ok end)
      Keyword.put(acc, key, fn value -> safe_callback(callback, value) end)
    end)
  end

  defp safe_callback(callback, value) do
    callback.(value)
  rescue
    error -> {:error, {:callback_exception, error}}
  catch
    kind, reason -> {:error, {:callback_exit, kind, reason}}
  end

  defp stop_gateway(gateway) do
    if Process.alive?(gateway), do: MCP.stop(gateway)
  catch
    :exit, _ -> :ok
  end
end
