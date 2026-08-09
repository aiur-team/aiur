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
          %{provider_pid: to_string(os_pid), codex_app_server_pid: to_string(os_pid)}

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

  @type stop_result :: :ok | {:error, :group_alive}

  @spec stop_port(port()) :: stop_result()
  def stop_port(port) when is_port(port), do: stop_port(port, %{})

  @spec stop_port(port(), map()) :: stop_result()
  def stop_port(port, metadata) when is_port(port) and is_map(metadata), do: stop_port(port, metadata, [])

  @doc false
  @spec stop_port(port(), map(), keyword()) :: stop_result()
  def stop_port(port, metadata, opts) when is_port(port) and is_map(metadata) and is_list(opts) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        # Reap the owned process group BEFORE closing the port. A detached tool
        # child can outlive and reparent away from the shell/app-server tree
        # while retaining both the recorded group and this port's stdio pipe.
        # Closing the port first destroys that child's Erlang standard_error
        # device; reaping only the dead parent tree misses it entirely.
        os_pid = port_os_pid(port)

        with :ok <- reap_owned_processes(os_pid, metadata, opts) do
          if is_integer(os_pid), do: ProcessReaper.unregister({:os_pid, os_pid})
          close_port(port, Keyword.get(opts, :port_closer, &Port.close/1))
        end
    end
  end

  defp port_os_pid(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _other -> nil
    end
  end

  defp reap_owned_processes(nil, _metadata, _opts), do: :ok

  defp reap_owned_processes(os_pid, %{agent_process_group_id: process_group_id}, opts) do
    tree_reaper = Keyword.get(opts, :tree_reaper, &RemoteControl.graceful_kill_tree/1)

    case positive_process_group_id(process_group_id) do
      ^os_pid ->
        group_reaper = Keyword.get(opts, :group_reaper, &RemoteControl.graceful_kill_process_group/1)

        case group_reaper.(os_pid) do
          {:ok, _outcome} -> :ok
          {:error, reason} -> reap_failed_group(os_pid, reason, tree_reaper, opts)
        end

      _other ->
        tree_reaper.(os_pid)
    end
  end

  defp reap_owned_processes(os_pid, _metadata, opts) do
    Keyword.get(opts, :tree_reaper, &RemoteControl.graceful_kill_tree/1).(os_pid)
  end

  defp reap_failed_group(os_pid, reason, tree_reaper, opts) do
    tree_reaper.(os_pid)
    group_alive? = Keyword.get(opts, :group_alive?, &RemoteControl.process_group_alive?/1)

    if group_alive?.(os_pid), do: {:error, reason}, else: :ok
  end

  defp close_port(port, port_closer) do
    port_closer.(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp positive_process_group_id(process_group_id) when is_integer(process_group_id) and process_group_id > 0,
    do: process_group_id

  defp positive_process_group_id(process_group_id) when is_binary(process_group_id) do
    case Integer.parse(process_group_id) do
      {value, ""} when value > 0 -> value
      _other -> nil
    end
  end

  defp positive_process_group_id(_process_group_id), do: nil

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
    case positive_process_group_id(port_metadata(port, worker_host)[:agent_process_group_id]) do
      process_group_id when is_integer(process_group_id) -> callback.(process_group_id)
      nil -> :ok
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

  defp maybe_put_provider_group(provider, pid) do
    case positive_process_group_id(pid) do
      process_group_id when is_integer(process_group_id) -> Map.put(provider, :process_group_id, process_group_id)
      nil -> provider
    end
  end

  defp maybe_put_remote(provider, worker_host) when is_binary(worker_host), do: Map.put(provider, :remote, true)
  defp maybe_put_remote(provider, _worker_host), do: provider

  defp maybe_put_provider_processes(provider, worker_host) when is_binary(worker_host), do: provider

  defp maybe_put_provider_processes(%{root_pid: root_pid} = provider, _worker_host),
    do: Map.put(provider, :descendant_pids, RemoteControl.process_tree(root_pid))

  defp maybe_put_provider_processes(provider, _worker_host), do: provider
end
