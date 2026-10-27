defmodule Aiur.ControlCLI.Settings do
  @moduledoc false

  import Aiur.ControlCLI.Protocol

  alias Aiur.Config
  alias Aiur.Config.Overrides
  alias Aiur.Orchestrator.Client
  alias Aiur.PathSafety
  alias Aiur.Workspace.Ownership.Store, as: WorkspaceOwnershipStore

  @spec set(String.t(), String.t()) :: :ok
  def set(key, json_value) when is_binary(key) and is_binary(json_value) do
    set(key, json_value, [])
  end

  @spec set(String.t(), String.t(), keyword()) :: :ok
  def set(key, json_value, opts) when is_binary(key) and is_binary(json_value) and is_list(opts) do
    guarded("set #{key}", fn ->
      case allow_mutation(opts) do
        :ok -> set_result(key, json_value)
        {:error, reason} -> report_error(key, reason)
      end
    end)
  end

  @spec list(keyword()) :: :ok
  def list(opts \\ []) do
    guarded("set --list", fn -> list_result(Keyword.get(opts, :json, false)) end)
  end

  @spec unset(String.t()) :: :ok
  def unset(key) when is_binary(key) do
    unset(key, [])
  end

  @spec unset(String.t(), keyword()) :: :ok
  def unset(key, opts) when is_binary(key) and is_list(opts) do
    guarded("set --unset #{key}", fn ->
      case allow_mutation(opts) do
        :ok -> unset_result(key)
        {:error, reason} -> report_error(key, reason)
      end
    end)
  end

  defp set_result(key, json_value) do
    with {:ok, value} <- decode_value(json_value),
         {:ok, entry} <- Overrides.set(key, value, actor()) do
      IO.puts("aiur: #{entry.key} set to #{Jason.encode!(entry.value)} (#{entry.applies}; revision #{entry.revision})")
      exit_marker(0)
    else
      {:error, reason} -> report_error(key, reason)
    end
  end

  defp list_result(json?) do
    case Overrides.list() do
      {:ok, entries} ->
        print_entries(entries, json?)
        exit_marker(0)

      {:error, reason} ->
        report_error(nil, reason)
    end
  end

  defp unset_result(key) do
    case Overrides.unset(key, actor()) do
      {:ok, :removed} ->
        IO.puts("aiur: #{key} override removed; YAML value will apply live")
        exit_marker(0)

      {:ok, :not_set} ->
        IO.puts("aiur: #{key} has no runtime override")
        exit_marker(0)

      {:error, reason} ->
        report_error(key, reason)
    end
  end

  defp print_entries(entries, true), do: IO.puts(Jason.encode!(entries))

  defp print_entries([], false), do: IO.puts("No runtime settings are overridden.")

  defp print_entries(entries, false) do
    Enum.each(entries, fn entry ->
      IO.puts(
        "#{entry.key}=#{Jason.encode!(entry.value)} source=#{entry.source} revision=#{entry.revision} " <>
          "actor=#{entry.actor} set_at=#{entry.set_at} build=#{entry.build} applies=#{entry.applies}"
      )
    end)
  end

  defp decode_value(json_value) do
    case Jason.decode(json_value) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp allow_mutation(opts) do
    with {:ok, caller_cwd} <- caller_evidence(opts, :caller_cwd),
         {:ok, caller_agent_workspace} <- caller_evidence(opts, :caller_agent_workspace_env) do
      workspace_paths = daemon_workspace_paths()

      if agent_workspace?(caller_cwd, workspace_paths) or
           agent_workspace?(caller_agent_workspace, workspace_paths) do
        {:error, :agent_workspace}
      else
        :ok
      end
    end
  end

  defp caller_evidence(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when key == :caller_cwd and is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} when key == :caller_agent_workspace_env and is_binary(value) -> {:ok, value}
      _missing_or_invalid -> {:error, :caller_context_missing}
    end
  end

  defp agent_workspace?("", _workspace_paths), do: false

  defp agent_workspace?(path, workspace_paths) do
    Enum.any?(workspace_paths, fn workspace ->
      match?({:ok, _paths}, PathSafety.contained?(workspace, path))
    end)
  end

  defp daemon_workspace_paths do
    [Config.workspace_root() | live_agent_workspaces()]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp live_agent_workspaces do
    snapshot_workspaces() ++ ownership_workspaces()
  end

  defp snapshot_workspaces do
    case Client.snapshot(Aiur.Orchestrator, 500) do
      %{running: running, retrying: retrying} ->
        Enum.flat_map(running ++ retrying, &workspace_path/1)

      _unavailable ->
        []
    end
  end

  defp ownership_workspaces do
    case WorkspaceOwnershipStore.all() do
      {:ok, receipts} ->
        receipts
        |> Map.values()
        |> Enum.flat_map(fn receipt -> workspace_path(Map.get(receipt, :host_lock, %{})) end)

      {:error, _reason} ->
        []
    end
  end

  defp workspace_path(%{workspace_path: path}) when is_binary(path), do: [path]
  defp workspace_path(%{workspace: path}) when is_binary(path), do: [path]
  defp workspace_path(_entry), do: []

  defp report_error(_key, :agent_workspace) do
    control_error("aiur: runtime setting changes are blocked inside agent workspaces")
    exit_marker(1)
  end

  defp report_error(_key, :caller_context_missing) do
    control_error("aiur: runtime setting changes require caller context from the aiur CLI")
    exit_marker(1)
  end

  defp report_error(key, {:unknown_setting, version}) do
    control_error("aiur: unknown setting on this build (#{version}): #{key}")
    exit_marker(1)
  end

  defp report_error(_key, reason) when reason in [:instance_key_missing, :instance_key_invalid] do
    control_error("aiur: runtime settings require a valid AIUR_INSTANCE_KEY (#{reason})")
    exit_marker(1)
  end

  defp report_error(_key, {:invalid_json, message}) do
    control_error("aiur: setting value must be JSON (#{message})")
    exit_marker(1)
  end

  defp report_error(_key, {:invalid_workflow_config, _message} = reason) do
    control_error("aiur: #{Config.format_config_error(reason)}")
    exit_marker(1)
  end

  defp report_error(_key, reason) do
    control_error("aiur: runtime setting failed (#{inspect(reason)})")
    exit_marker(1)
  end

  # MIC-001 supplies the authenticated actor through process-local control-call
  # context. Runtime settings also work on builds where that ticket has not yet
  # landed, using the local shell identity promised by this command's contract.
  defp actor do
    control_call = Module.concat(Aiur, ControlCall)

    if Code.ensure_loaded?(control_call) and function_exported?(control_call, :actor, 0) do
      case control_call.actor() do
        actor when is_binary(actor) and actor != "" -> actor
        _missing -> local_actor()
      end
    else
      local_actor()
    end
  end

  defp local_actor, do: "local:" <> (System.get_env("USER") || "unknown")
end
