defmodule Aiur.AgentEnvironment do
  @moduledoc """
  Helpers for preparing child agent process environments.
  """

  @erlang_distribution_env_names ~w(ERL_AFLAGS RELEASE_NODE RELEASE_COOKIE)
  @aiur_distribution_env_pattern ~r/\AAIUR(?:_.*)?_(?:NODE_NAME|COOKIE)\z/

  @spec erlang_distribution_env_name?(String.t()) :: boolean()
  def erlang_distribution_env_name?(name) when is_binary(name) do
    name in @erlang_distribution_env_names or Regex.match?(@aiur_distribution_env_pattern, name)
  end

  @spec scrub_shell_command(String.t(), keyword()) :: String.t()
  def scrub_shell_command(command, opts \\ []) when is_binary(command) do
    exec_prefix = if Keyword.get(opts, :exec, false), do: "exec ", else: ""
    "#{scrub_shell_prefix()}; #{exec_prefix}#{command}"
  end

  @spec scrub_shell_prefix() :: String.t()
  def scrub_shell_prefix do
    "unset ERL_AFLAGS RELEASE_NODE RELEASE_COOKIE; " <>
      "for aiur_env_name in $(env | sed 's/=.*//'); do " <>
      "case \"$aiur_env_name\" in " <>
      "AIUR_NODE_NAME|AIUR_*_NODE_NAME|AIUR_COOKIE|AIUR_*_COOKIE) unset \"$aiur_env_name\" ;; " <>
      "esac; " <>
      "done"
  end

  @doc """
  Return Port-compatible env tuples (`{charlist_name, charlist_value}`) for
  per-workspace `HEX_HOME` / `MIX_HOME` / `MISE_TRUSTED_CONFIG_PATHS`. The agent
  inherits these so it does not redeclare them as inline prefixes on every
  `mix`/`mise` invocation (logs showed 48+ instances of agents inventing
  variant paths like `/tmp/aiur-100-hex`, `/tmp/aiur-hex`, `/tmp/hex-100`
  across one session — wasting 20-30s per agent on env+trust setup).

  Returns an empty list when `workspace` is not a binary so callers can splat
  the result into Port.open env opts unconditionally.
  """
  @spec workspace_env(any()) :: [{charlist(), charlist()}]
  def workspace_env(workspace) when is_binary(workspace) do
    hex = Path.join(workspace, ".aiur-hex")
    mix = Path.join(workspace, ".aiur-mix")
    mise = Path.join([workspace, "elixir", "mise.toml"])

    [
      {~c"HEX_HOME", String.to_charlist(hex)},
      {~c"MIX_HOME", String.to_charlist(mix)},
      {~c"MISE_TRUSTED_CONFIG_PATHS", String.to_charlist(mise)}
    ]
  end

  def workspace_env(_), do: []

  @doc """
  Shell-export prefix for the same vars `workspace_env/1` injects into
  Port.open env. Used by the SSH-launch path which has no `env:` option
  available — exports are inlined into the remote bash command instead.
  """
  @spec workspace_env_export_prefix(any()) :: String.t()
  def workspace_env_export_prefix(workspace) when is_binary(workspace) do
    hex = Path.join(workspace, ".aiur-hex")
    mix = Path.join(workspace, ".aiur-mix")
    mise = Path.join([workspace, "elixir", "mise.toml"])

    "export HEX_HOME=#{shell_escape(hex)} MIX_HOME=#{shell_escape(mix)} MISE_TRUSTED_CONFIG_PATHS=#{shell_escape(mise)}"
  end

  def workspace_env_export_prefix(_), do: ""

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
