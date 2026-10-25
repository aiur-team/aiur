defmodule Aiur.AgentEnvironment.CredentialScrub do
  @moduledoc false

  @app_credential_env_pattern ~r/\AGITHUB_APP_/
  @remote_instance_token_env_pattern ~r/\AAIUR_TOKEN_/

  @spec inherited_env_names(Regex.t()) :: [String.t()]
  def inherited_env_names(pattern) do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&Regex.match?(pattern, &1))
  end

  @spec remote_instance_token_env_names() :: [String.t()]
  def remote_instance_token_env_names, do: inherited_env_names(@remote_instance_token_env_pattern)

  @spec contributed_credential_name?(String.t() | charlist()) :: boolean()
  def contributed_credential_name?(name) do
    name = to_string(name)
    Regex.match?(@app_credential_env_pattern, name) or Regex.match?(@remote_instance_token_env_pattern, name)
  end
end
