defmodule Aiur.AgentEnvironment do
  @moduledoc """
  Helpers for preparing child agent process environments.

  The shell scrub lives in `Aiur.AgentEnvironment.ShellScrub`, the workspace
  environment in `Aiur.AgentEnvironment.WorkspaceEnv`, and the scrubbed
  credential names in `Aiur.AgentEnvironment.Names`.
  """

  alias Aiur.AgentEnvironment.{Names, ShellScrub, WorkspaceEnv}

  defdelegate erlang_distribution_env_name?(name), to: ShellScrub
  defdelegate scrub_shell_command(command, opts \\ []), to: ShellScrub
  defdelegate shell_startup_env, to: ShellScrub
  defdelegate shell_startup_env_name?(name), to: ShellScrub
  defdelegate system_shell_startup_env, to: ShellScrub
  defdelegate port_shell_startup_env, to: ShellScrub
  defdelegate shell_startup_prefix(opts \\ []), to: ShellScrub
  defdelegate scrub_shell_prefix(opts \\ []), to: ShellScrub

  defdelegate workspace_env(workspace, opts \\ []), to: WorkspaceEnv
  defdelegate workspace_env_export_prefix(workspace, opts \\ []), to: WorkspaceEnv
  defdelegate base_env(base_path), to: WorkspaceEnv
  defdelegate package_cache_paths(opts \\ []), to: WorkspaceEnv
  defdelegate neutral_repo_url, to: WorkspaceEnv

  @spec parent_log_env_name?(String.t()) :: boolean()
  def parent_log_env_name?(name) when is_binary(name), do: name in Names.parent_log()

  @doc false
  @spec provider_credential_env_names() :: [String.t()]
  def provider_credential_env_names do
    inherited = System.get_env() |> Map.keys() |> Enum.filter(&Regex.match?(Names.provider_api_key_pattern(), &1))
    Enum.uniq(Names.provider_credential() ++ inherited)
  end

  @doc """
  Every GitHub App credential variable to remove from an agent's environment:
  the known names plus anything the daemon inherited under the same
  `GITHUB_APP_` prefix. See `Aiur.AgentEnvironment.Names` for why agents must
  not hold these (#2266).
  """
  @spec app_credential_env_names() :: [String.t()]
  def app_credential_env_names do
    inherited = System.get_env() |> Map.keys() |> Enum.filter(&Regex.match?(Names.app_credential_pattern(), &1))
    Enum.uniq(Names.app_credential() ++ inherited)
  end
end
