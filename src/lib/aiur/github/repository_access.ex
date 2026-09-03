defmodule Aiur.GitHub.RepositoryAccess do
  @moduledoc false

  alias Aiur.GitHub.{Credential, Errors, Transport}

  @spec classify_not_found(function(), String.t(), String.t(), String.t(), map()) :: {:error, term()}
  def classify_not_found(request_fun, token, owner, repo, repository_response) do
    organization_url = "#{Transport.base_url()}/orgs/#{URI.encode(owner, &URI.char_unreserved?/1)}"

    case request_fun.(%{method: :get, url: organization_url, token: token, caller: "ci_readiness"}) do
      {:ok, %{status: status}} when status in 200..299 ->
        {:error, {:github_org_repository_not_accessible, %{organization: owner, repo: "#{owner}/#{repo}", token_type: Credential.token_type(token)}}}

      {:ok, %{status: 404}} ->
        {:error, Errors.github_status_error(repository_response)}

      {:ok, %{status: _} = response} ->
        organization_error = Errors.github_status_error(response)

        if Errors.retryable_github_error?(organization_error),
          do: {:error, organization_error},
          else: {:error, Errors.github_status_error(repository_response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}

      _ ->
        {:error, :invalid_organization_response}
    end
  end

  @spec error_message(term()) :: String.t() | nil
  def error_message({:github_org_repository_not_accessible, %{organization: organization, repo: repo, token_type: token_type}}) do
    "Cannot read #{repo} with the configured token. GitHub returns 404 (not 403) for inaccessible private organization resources, " <>
      "so this may be an authorization problem rather than a missing repository or branch. " <>
      token_authorization_guidance(token_type, organization)
  end

  def error_message({:github, :http, %{status: 404}}) do
    "Cannot read the configured GitHub repository. GitHub may return 404 when a repository is absent or when the configured token cannot access it. " <>
      "Verify the repository name and the configured token's repository access."
  end

  def error_message(_reason), do: nil

  defp token_authorization_guidance(:classic_pat, organization) do
    "Your token looks like a classic PAT (`ghp_…`). It needs the `repo` scope and SAML SSO authorization for #{organization}. " <>
      "In GitHub, open Settings → Developer settings → Personal access tokens → Tokens (classic) → Configure SSO → Authorize. " <>
      "If `gh api` succeeds, it may be using a different OAuth token (`gho_…`) from the `gh` keyring; that does not authorize this configured token."
  end

  defp token_authorization_guidance(:fine_grained_pat, organization) do
    "Your token looks like a fine-grained PAT (`github_pat_…`). It must be created with #{organization} as its resource owner, include this repository, " <>
      "and may require organization approval. A token owned by your personal account cannot be granted access to this organization repository. " <>
      "If `gh api` succeeds, it may be using a different OAuth token (`gho_…`) from the `gh` keyring."
  end

  defp token_authorization_guidance(:oauth, organization),
    do: "Your token looks like an OAuth token (`gho_…`). Verify that the OAuth app access is authorized for #{organization} and that the token's user can read this repository."

  defp token_authorization_guidance(:app_installation, organization),
    do: "Your token looks like a GitHub App installation token (`ghs_…`). Verify that the App is installed on this repository in #{organization} with Contents: Read access."

  defp token_authorization_guidance(:unknown, organization) do
    "The credential type is not recognized from its prefix. Verify its repository permissions and organization authorization for #{organization}; " <>
      "also verify whether `gh api` is using a different credential from the `gh` keyring."
  end
end
