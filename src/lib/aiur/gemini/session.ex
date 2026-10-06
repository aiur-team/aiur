defmodule Aiur.Gemini.Session do
  @moduledoc "Starts a ticket-scoped Gemini ACP session and owns its tool gateway."

  alias Aiur.AgentTools.MCP
  alias Aiur.Config.Paths
  alias Aiur.Gemini.{Protocol, Transport}
  alias Aiur.{PauseContainment, ProcessReaper}

  @timeout 30_000
  @json_comment_tokens ~r{"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/}

  @spec start(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
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

  @spec stop(map()) :: :ok
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
    with :ok <- reject_workspace_auth_override(workspace),
         {:ok, auth} <- supported_auth(opts),
         {:ok, home} <- isolated_home(workspace, opts),
         {:ok, gateway} <- MCP.start_link(owner: self(), transport: :gemini_mcp) do
      command = command <> " --approval-mode default --allowed-mcp-server-names aiur"
      vertex? = auth.method == "vertex-ai"

      launch_opts =
        Keyword.put(opts, :env, [
          {"GEMINI_CLI_HOME", home},
          {"GOOGLE_GENAI_USE_GCA", "false"},
          {"GOOGLE_GENAI_USE_VERTEXAI", to_string(vertex?)}
        ])

      case Transport.start(workspace, command, launch_opts) do
        {:ok, port} ->
          establish(port, gateway, workspace, auth, opts)

        {:error, _} = error ->
          MCP.stop(gateway)
          error
      end
    end
  end

  defp establish(port, gateway, workspace, auth, opts) do
    metadata = Transport.metadata(port)
    ProcessReaper.register(:agent, {:os_pid, metadata[:provider_pid]}, comm: "gemini", ticket: Keyword.get(opts, :identifier), backend: "gemini")
    containment = register_containment(metadata, workspace, opts)
    timeout = Keyword.get(opts, :timeout_ms, @timeout)
    version = Application.spec(:aiur, :vsn) |> to_string()
    server = Protocol.mcp_server(MCP.connection(gateway))

    outcome =
      with {:ok, init} <- Transport.request(port, Protocol.initialize(1, version), timeout),
           {:ok, _capabilities} <- Protocol.validate_initialize(init),
           {:ok, _} <- Transport.request(port, Protocol.authenticate(5, auth), timeout),
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

  defp supported_auth(opts) do
    resolve_auth(System.get_env(), opts)
  end

  @doc false
  @spec resolve_auth(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_auth(environment, opts \\ []) do
    case Keyword.get(opts, :auth) do
      nil -> auth_from_environment(environment)
      auth -> validate_auth(auth)
    end
  end

  defp auth_from_environment(environment) do
    gemini_key = Map.get(environment, "GEMINI_API_KEY")
    vertex_key = Map.get(environment, "GOOGLE_API_KEY")
    gemini? = is_binary(gemini_key) and gemini_key != ""
    vertex? = is_binary(vertex_key) and vertex_key != ""

    cond do
      gemini? and vertex? -> {:error, {:gemini_auth_ambiguous, "Set only one of GEMINI_API_KEY or GOOGLE_API_KEY"}}
      gemini? -> validate_auth(%{method: "gemini-api-key", api_key: gemini_key})
      vertex? -> validate_auth(%{method: "vertex-ai", api_key: vertex_key})
      true -> {:error, {:gemini_auth_required, "Set GEMINI_API_KEY or GOOGLE_API_KEY in the Aiur daemon environment"}}
    end
  end

  defp validate_auth(%{method: method, api_key: key})
       when method in ["gemini-api-key", "vertex-ai"] and is_binary(key) and key != "",
       do: {:ok, %{method: method, api_key: key}}

  defp validate_auth(_), do: {:error, :gemini_supported_auth_required}

  # Trusted workspace settings outrank the isolated user home in Gemini CLI.
  # A repository must not replace Aiur's API-key choice with personal OAuth.
  defp reject_workspace_auth_override(workspace) do
    path = Path.join([workspace, ".gemini", "settings.json"])

    case File.read(path) do
      {:ok, content} ->
        validate_workspace_auth_settings(content)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:gemini_workspace_settings_unreadable, reason}}
    end
  end

  defp validate_workspace_auth_settings(content) do
    case content |> strip_json_comments() |> Jason.decode() do
      {:ok, %{"security" => %{"auth" => auth}}} when is_map(auth) ->
        if Map.has_key?(auth, "selectedType") or Map.has_key?(auth, "enforcedType"),
          do: {:error, :gemini_workspace_auth_override},
          else: :ok

      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error, :gemini_workspace_settings_invalid_json}
    end
  end

  # Gemini CLI parses settings with JSON.parse(stripJsonComments(content)).
  # Preserve strings so URLs and comment-shaped text remain data, while Jason
  # enforces the same JSON grammar after comments are replaced with whitespace.
  defp strip_json_comments(content) do
    Regex.replace(@json_comment_tokens, content, fn token ->
      if String.starts_with?(token, "\"") do
        token
      else
        String.replace(token, ~r/[^\r\n]/, " ")
      end
    end)
  end

  defp isolated_home(workspace, opts) do
    root = Keyword.get_lazy(opts, :gemini_home_root, fn -> Paths.runtime_state_dir() end)

    with {:ok, root} <- normalize_home_root(root),
         digest = :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower),
         home = Path.join([root, "gemini", digest]),
         :ok <- File.mkdir_p(home),
         :ok <- File.chmod(home, 0o700) do
      {:ok, home}
    end
  end

  defp normalize_home_root({:ok, root}), do: {:ok, root}
  defp normalize_home_root({:error, _} = error), do: error
  defp normalize_home_root(root) when is_binary(root), do: {:ok, root}

  defp establish_session(port, workspace, server, opts, timeout) do
    case Keyword.get(opts, :resume_thread_id) do
      id when is_binary(id) and id != "" ->
        load_session(port, workspace, server, id, timeout)

      _ ->
        new_session(port, workspace, server, timeout)
    end
  end

  defp load_session(port, workspace, server, id, timeout) do
    frame = Protocol.session(2, "session/load", workspace, [server], id)

    case Transport.request(port, frame, timeout, fn _ -> :ok end) do
      {:ok, result} ->
        {:ok, id, true, result}

      {:error, {:acp_error, %{"message" => message}}} = error ->
        if confirmed_missing?(message, id), do: new_session(port, workspace, server, timeout), else: error

      {:error, _} = error ->
        error
    end
  end

  defp confirmed_missing?(message, id) when is_binary(message) do
    message == "No previous sessions found for this project." or
      String.starts_with?(message, "Invalid session identifier \"#{id}\".")
  end

  defp confirmed_missing?(_, _), do: false

  defp new_session(port, workspace, server, timeout) do
    case Transport.request(port, Protocol.session(2, "session/new", workspace, [server]), timeout) do
      {:ok, %{"sessionId" => id} = result} when is_binary(id) and id != "" -> {:ok, id, false, result}
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
