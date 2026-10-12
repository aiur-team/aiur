defmodule Aiur.CodexProber do
  @moduledoc """
  Probe Codex usage limits asynchronously and update the ledger.

  When a cached usage limit is stale, a probe runs in the background to fetch
  the current limit from the Codex provider. On success, the ledger is refreshed
  immediately. On failure, a retry is scheduled for 2 minutes later.
  """

  require Logger

  alias Aiur.AppServer.Transport
  alias Aiur.Codex.{AppServerPort, Handshake}
  alias Aiur.{Config, ModelAvailability, Workspace}

  @doc """
  Probe Codex for current usage limits and update the ledger.

  This runs asynchronously in a spawned process. On success, the ledger is
  refreshed with the new reading and the retry schedule is cleared. On failure,
  the cached reading is retained and a retry is scheduled.

  Returns `:ok` immediately (probe runs in the background).
  """
  @spec probe_async(String.t(), keyword()) :: :ok
  def probe_async(backend, opts \\ []) when is_binary(backend) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    path = Keyword.get(opts, :path, ModelAvailability.path())

    spawn(fn ->
      result = probe_sync(backend, now, Keyword.put(opts, :path, path))
      if callback = Keyword.get(opts, :on_complete_fun), do: callback.(result)
    end)

    :ok
  end

  @doc false
  @spec probe_sync(String.t(), DateTime.t(), keyword()) :: :ok | {:error, term()}
  def probe_sync(backend, now, opts \\ []) when is_binary(backend) do
    path = Keyword.get(opts, :path, ModelAvailability.path())

    case fetch_limits(backend, opts) do
      {:ok, limits} ->
        # Refresh ledger with new observation
        ModelAvailability.observe(backend, limits, path: path, now: now)
        # Clear retry schedule
        ModelAvailability.clear_retry_schedule(backend, path: path)
        :ok

      {:error, reason} ->
        Logger.warning("Codex probe failed for #{backend}: #{inspect(reason)}")
        # Retain cached reading and schedule retry
        ModelAvailability.schedule_retry(backend, now, path: path)
        {:error, reason}
    end
  end

  @doc false
  # Fetch current usage limits from Codex provider via app-server.
  # Returns {:ok, limits_map} or {:error, reason}.
  @spec fetch_limits(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_limits(backend, opts) do
    backend_key = ModelAvailability.backend_key(backend)

    # Only probe Codex for now
    if backend_key != "codex" do
      {:error, :unsupported_backend}
    else
      probe_codex_limits(opts)
    end
  end

  defp probe_codex_limits(opts) do
    case Keyword.get(opts, :fetch_limits_fun) do
      fun when is_function(fun, 0) ->
        case fun.() do
          {:ok, response} when is_map(response) -> normalize_codex_limits(response)
          {:error, _reason} = error -> error
          _ -> {:error, :invalid_response}
        end

      _ ->
        probe_codex_limits_from_app_server(opts)
    end
  end

  defp probe_codex_limits_from_app_server(opts) do
    with {:ok, workspace} <- probe_workspace(opts) do
      trapping_exits? = Process.flag(:trap_exit, true)

      try do
        with {:ok, port} <- start_probe_port(workspace, opts) do
          try_probe_port(port, opts)
        end
      after
        File.rm_rf(workspace)
        Process.flag(:trap_exit, trapping_exits?)
      end
    end
  end

  defp try_probe_port(port, opts) do
    os_pid =
      case (is_port(port) or is_pid(port)) && Transport.os_pid(port) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    try do
      with :ok <- initialize_probe_port(port, opts),
           {:ok, limits} <- read_probe_limits(port, opts) do
        normalize_codex_limits(limits)
      end
    after
      stop_probe_port(port, os_pid, opts)
      flush_probe_exit(port)
    end
  end

  defp flush_probe_exit(port) do
    receive do
      {:EXIT, ^port, _reason} -> :ok
      {:DOWN, _ref, :port, ^port, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  @doc false
  @spec probe_workspace(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def probe_workspace(opts \\ []) do
    workspace =
      case Keyword.get(opts, :workspace) do
        path when is_binary(path) -> path
        _ -> Workspace.workspace_path_under(Config.workspace_root(), "codex-usage-probe-#{:erlang.unique_integer([:positive])}")
      end

    case File.mkdir_p(workspace) do
      :ok -> {:ok, Path.expand(workspace)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :no_workspace_root}
  catch
    _kind, _reason -> {:error, :no_workspace_root}
  end

  defp start_probe_port(workspace, opts) do
    env =
      case Keyword.get(opts, :codex_home) do
        home when is_binary(home) -> [{"CODEX_HOME", home}]
        _ -> []
      end

    case Keyword.get(opts, :start_port_fun) do
      fun when is_function(fun, 4) -> fun.(workspace, nil, nil, nil)
      fun when is_function(fun, 5) -> fun.(workspace, nil, nil, nil, env)
      _ -> AppServerPort.start_port(workspace, nil, nil, nil, fn _pid -> :ok end, env)
    end
  end

  defp initialize_probe_port(port, opts),
    do: Keyword.get(opts, :initialize_fun, &Handshake.send_initialize/1).(port)

  defp read_probe_limits(port, opts),
    do: Keyword.get(opts, :read_rate_limits_fun, &Handshake.read_rate_limits/1).(port)

  defp stop_probe_port(port, os_pid, opts),
    do: Keyword.get(opts, :stop_port_fun, &AppServerPort.stop_port(&1, os_pid)).(port)

  @doc false
  @spec normalize_codex_limits(map()) :: {:ok, map()} | {:error, term()}
  def normalize_codex_limits(result) do
    # account/rateLimits/read returns the windows under `rateLimits`.
    limits =
      result
      |> Map.get("rateLimits", %{})
      |> Map.take(["primary", "secondary"])
      |> Enum.into(%{})

    # Return in a format ModelAvailability.observe expects
    if map_size(limits) > 0 do
      {:ok, limits}
    else
      {:error, :no_usage_data}
    end
  end
end
