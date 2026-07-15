defmodule Aiur.Codex.AppServerPort do
  @moduledoc """
  Codex app-server OS process lifecycle helpers.
  """

  alias Aiur.{AgentEnvironment, Config, PathSafety, ProcessReaper, SSH}
  alias Aiur.AppServer.Adapter
  alias Aiur.Claude.RemoteControl
  alias Aiur.Codex.Config, as: CodexConfig

  @spec validate_workspace_cwd(Path.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
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

  def validate_workspace_cwd(workspace, worker_host)
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

  @spec start_port(Path.t(), String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, port()} | {:error, term()}
  def start_port(workspace, worker_host, model, effort),
    do: start_port(workspace, worker_host, model, effort, fn _process_group_id -> :ok end)

  @doc false
  @spec start_port(
          Path.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          (integer() -> term()),
          (map() -> term())
        ) :: {:ok, port()} | {:error, term()}
  def start_port(workspace, worker_host, model, effort, on_process_group_started, on_provider_started)
      when is_function(on_process_group_started, 1) and is_function(on_provider_started, 1) do
    open_port(workspace, worker_host, model, effort, fn port ->
      with :ok <- notify_provider_started(port, worker_host, on_provider_started) do
        notify_process_group_started(port, worker_host, on_process_group_started)
      end
    end)
  end

  @spec start_port(Path.t(), String.t() | nil, String.t() | nil, String.t() | nil, (integer() -> term())) ::
          {:ok, port()} | {:error, term()}
  def start_port(workspace, nil, model, effort, on_process_group_started)
      when is_function(on_process_group_started, 1) do
    Adapter.start_port(workspace, codex_command(model, effort), fn port ->
      notify_process_group_started(port, nil, on_process_group_started)
    end)
  end

  def start_port(workspace, worker_host, model, effort, on_process_group_started)
      when is_binary(worker_host) and is_function(on_process_group_started, 1) do
    command = remote_launch_command(workspace, model, effort)

    with {:ok, port} <- SSH.start_port(worker_host, command, line: Adapter.port_line_bytes()) do
      notify_process_group_started(port, worker_host, on_process_group_started)
      {:ok, port}
    end
  end

  defp open_port(workspace, nil, model, effort, on_port_started) when is_function(on_port_started, 1) do
    Adapter.start_port(workspace, codex_command(model, effort), on_port_started)
  end

  defp open_port(workspace, worker_host, model, effort, on_port_started)
       when is_binary(worker_host) and is_function(on_port_started, 1) do
    command = remote_launch_command(workspace, model, effort)

    with {:ok, port} <- SSH.start_port(worker_host, command, line: Adapter.port_line_bytes()) do
      case on_port_started.(port) do
        :ok -> {:ok, port}
        {:error, _reason} = error -> close_uncontained_remote_port(port, error)
        _other -> close_uncontained_remote_port(port, {:error, :workspace_ownership_lost})
      end
    end
  end

  defp close_uncontained_remote_port(port, error) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    error
  end

  @spec port_metadata(port(), String.t() | nil) :: map()
  def port_metadata(port, worker_host \\ nil) when is_port(port) do
    metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    metadata
    |> maybe_put_local_process_group(worker_host)
    |> maybe_put_worker_host(worker_host)
  end

  @doc false
  @spec process_group_for_pid(integer() | String.t() | nil) :: integer() | nil
  defdelegate process_group_for_pid(pid), to: RemoteControl

  @spec stop_port(port()) :: :ok
  def stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        # Reap the descendant tree (node -> rust app-server) BEFORE closing the
        # port. `Port.close` only kills the shell wrapper; its children would
        # reparent to init and keep holding the global ~/.codex/state_5.sqlite
        # lock, poisoning every subsequent codex agent. Collecting descendants
        # must happen while the wrapper is still alive to anchor the pgrep walk.
        case :erlang.port_info(port, :os_pid) do
          {:os_pid, os_pid} ->
            ProcessReaper.unregister({:os_pid, os_pid})
            RemoteControl.graceful_kill_tree(os_pid)

          _ ->
            :ok
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

  @doc false
  @spec codex_command_for_test(String.t() | nil, String.t() | nil) :: String.t()
  def codex_command_for_test(model, effort \\ nil), do: codex_command(model, effort)

  defp remote_launch_command(workspace, model, effort) do
    [
      AgentEnvironment.workspace_env_export_prefix(workspace),
      "cd #{Aiur.Shell.escape(workspace)}",
      AgentEnvironment.scrub_shell_command(codex_command(model, effort), exec: true)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" && ")
  end

  # Codex pins its model and reasoning effort in the launch command. A
  # per-issue model override appends a trailing `--config model="<variant>"`,
  # and a per-complexity effort appends `--config model_reasoning_effort="<e>"`;
  # codex applies the last `--config` for a key, so these beat any value baked
  # into the configured command (e.g. an `--config model_reasoning_effort=high`
  # default). The appended values are shell-escaped as complete `--config`
  # arguments, and effort is validated against the backend's `efforts/1` set.
  defp codex_command(model, effort) do
    CodexConfig.command()
    |> append_config("model", model)
    |> append_config("model_reasoning_effort", effort)
  end

  defp append_config(command, _key, nil), do: command

  defp append_config(command, key, value) when is_binary(value) do
    command <> " --config " <> Aiur.Shell.escape(~s(#{key}="#{value}"))
  end

  # The BEAM spawns the local port as its own session/process-group leader, so
  # the port PID is safe to record only when `ps` confirms it is still that
  # leader (os_pid == pgid). A failed or mismatched inspection deliberately
  # produces no containment metadata; callers must never fall back to a cwd- or
  # host-wide kill.
  defp maybe_put_local_process_group(metadata, nil) do
    case metadata[:codex_app_server_pid] do
      pid when is_binary(pid) ->
        case process_group_for_pid(pid) do
          group when is_integer(group) -> Map.put(metadata, :agent_process_group_id, Integer.to_string(group))
          _ -> metadata
        end

      _ ->
        metadata
    end
  end

  defp maybe_put_local_process_group(metadata, _worker_host), do: metadata

  defp maybe_put_worker_host(metadata, host) when is_binary(host), do: Map.put(metadata, :worker_host, host)
  defp maybe_put_worker_host(metadata, _worker_host), do: metadata

  defp notify_process_group_started(port, worker_host, callback) do
    case port_metadata(port, worker_host)[:agent_process_group_id] do
      process_group_id when is_binary(process_group_id) ->
        case Integer.parse(process_group_id) do
          {value, ""} when value > 0 -> callback.(value)
          _ -> :ok
        end

      process_group_id when is_integer(process_group_id) and process_group_id > 0 ->
        callback.(process_group_id)

      _ ->
        :ok
    end
  end

  defp notify_provider_started(port, worker_host, callback) do
    metadata = port_metadata(port, worker_host)

    provider =
      %{}
      |> maybe_put_provider_pid(metadata[:codex_app_server_pid])
      |> maybe_put_provider_group(metadata[:agent_process_group_id])
      |> maybe_put_remote(worker_host)
      |> maybe_put_provider_processes(worker_host)

    callback.(provider)
  end

  defp maybe_put_provider_pid(provider, pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {value, ""} when value > 0 -> Map.put(provider, :root_pid, value)
      _ -> provider
    end
  end

  defp maybe_put_provider_pid(provider, pid) when is_integer(pid) and pid > 0, do: Map.put(provider, :root_pid, pid)
  defp maybe_put_provider_pid(provider, _pid), do: provider

  defp maybe_put_provider_group(provider, pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {value, ""} when value > 0 -> Map.put(provider, :process_group_id, value)
      _ -> provider
    end
  end

  defp maybe_put_provider_group(provider, pid) when is_integer(pid) and pid > 0, do: Map.put(provider, :process_group_id, pid)
  defp maybe_put_provider_group(provider, _pid), do: provider
  defp maybe_put_remote(provider, worker_host) when is_binary(worker_host), do: Map.put(provider, :remote, true)
  defp maybe_put_remote(provider, _worker_host), do: provider

  defp maybe_put_provider_processes(provider, worker_host) when is_binary(worker_host), do: provider

  defp maybe_put_provider_processes(%{root_pid: root_pid} = provider, _worker_host),
    do: Map.put(provider, :descendant_pids, RemoteControl.process_tree(root_pid))

  defp maybe_put_provider_processes(provider, _worker_host), do: provider
end
