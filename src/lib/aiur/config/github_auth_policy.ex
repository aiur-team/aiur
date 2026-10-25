defmodule Aiur.GitHub.AuthPolicy do
  @moduledoc false

  @doc false
  @spec hosted_auth_required?(term(), map()) :: boolean()
  def hosted_auth_required?(settings, env \\ System.get_env()) do
    instance = if is_map(settings), do: Map.get(settings, :instance), else: nil
    instance_mode = if is_map(instance), do: Map.get(instance, :mode)

    instance_mode == "hosted" or Aiur.Secrets.secrets_from_env?(env) or
      Aiur.Secrets.truthy?(env["AIUR_STATE_PERSISTENT"])
  end

  @doc false
  @spec auth_policy_error(term(), map()) :: {:error, String.t()} | :ok
  def auth_policy_error(settings, env) do
    if hosted_auth_required?(settings, env) and not app_credentials_configured?(env) do
      if Aiur.Secrets.truthy?(env["AIUR_GITHUB_ALLOW_PAT"]) and nonblank?(env["GITHUB_TOKEN"]) do
        :ok
      else
        {:error,
         "hosted GitHub auth requires GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and " <>
           "GITHUB_APP_PRIVATE_KEY or GITHUB_APP_PRIVATE_KEY_PATH; to opt into the GITHUB_TOKEN PAT, " <>
           "set AIUR_GITHUB_ALLOW_PAT=1"}
      end
    else
      :ok
    end
  end

  @doc false
  @spec app_credentials_configured?(map()) :: boolean()
  def app_credentials_configured?(env) do
    nonblank?(env["GITHUB_APP_ID"]) and nonblank?(env["GITHUB_APP_INSTALLATION_ID"]) and
      (nonblank?(env["GITHUB_APP_PRIVATE_KEY"]) or nonblank?(env["GITHUB_APP_PRIVATE_KEY_PATH"]))
  end

  @spec validate_tracker(term(), map(), (-> term()), (-> term())) :: :ok | {:error, String.t()}
  def validate_tracker(settings, env, token_fun, repo_fun) do
    case auth_policy_error(settings, env) do
      {:error, _message} = error ->
        error

      :ok ->
        cond do
          app_credentials_configured?(env) and not is_binary(token_fun.()) ->
            {:error, "GitHub App installation token unavailable — check GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and the App private key"}

          not app_credentials_configured?(env) and not is_binary(token_fun.()) ->
            {:error, "GitHub token missing — set GITHUB_TOKEN env var"}

          not is_binary(repo_fun.()) ->
            {:error, "GitHub repo missing — set github.repo in .aiur/config"}

          true ->
            :ok
        end
    end
  end

  defp nonblank?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank?(_value), do: false
end
