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

  @spec scrub_shell_command(String.t()) :: String.t()
  def scrub_shell_command(command) when is_binary(command) do
    "#{scrub_shell_prefix()}; exec #{command}"
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
end
