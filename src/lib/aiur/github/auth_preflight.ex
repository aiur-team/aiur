defmodule Aiur.GitHub.AuthPreflight do
  @moduledoc """
  Startup GitHub authentication preflight diagnostics.
  """

  alias Aiur.GitHub.Errors
  alias Aiur.GitHub.Transport

  @spec preflight_auth(keyword()) :: :ok | {:error, term()}
  def preflight_auth(opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      gh_auth_status_fun = Keyword.get(opts, :gh_auth_status_fun, &default_gh_auth_status_fun/0)

      owner
      |> preflight_checks(repo)
      |> run_preflight_checks(request_fun, token, owner, repo)
      |> finalize_preflight_result(gh_auth_status_fun)
    end
  end

  defp finalize_preflight_result(result, gh_auth_status_fun) do
    case result do
      :ok ->
        :ok

      {:error, diagnostic} ->
        {:error, {:github_auth_preflight_failed, enrich_auth_diagnostic(diagnostic, gh_auth_status_fun)}}
    end
  end

  @spec format_auth_preflight_error(term()) :: String.t()
  def format_auth_preflight_error({:github_auth_preflight_failed, diagnostic})
      when is_map(diagnostic) do
    Map.get(diagnostic, :message) || Map.get(diagnostic, "message") || inspect(diagnostic)
  end

  def format_auth_preflight_error(reason), do: inspect(reason)

  defp preflight_checks(owner, repo) do
    [
      %{endpoint: :rate_limit, url: "#{Transport.base_url()}/rate_limit"},
      %{endpoint: :repository, url: "#{Transport.base_url()}/repos/#{owner}/#{repo}"},
      %{
        endpoint: :issues,
        url: "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?state=open&per_page=1"
      }
    ]
  end

  defp run_preflight_checks(checks, request_fun, token, owner, repo) do
    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case run_preflight_check(check, request_fun, token, owner, repo) do
        :ok -> {:cont, :ok}
        {:error, diagnostic} -> {:halt, {:error, diagnostic}}
      end
    end)
  end

  defp run_preflight_check(%{endpoint: endpoint, url: url}, request_fun, token, owner, repo) do
    request = %{method: :get, url: url, token: token, preflight?: true}

    case request_fun.(request) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        if Errors.rate_limited_response?(response, endpoint) do
          {:error, auth_diagnostic(:rate_limited, endpoint, status, response, owner, repo)}
        else
          :ok
        end

      {:ok, %{status: status} = response} ->
        {:error,
         auth_diagnostic(
           auth_failure_reason(status, response),
           endpoint,
           status,
           response,
           owner,
           repo
         )}

      {:error, reason} ->
        {:github, classification, detail} = Errors.classify_error({:error, reason})

        {:error,
         %{
           reason: classification,
           classification: classification,
           detail: detail,
           endpoint: endpoint,
           repo: "#{owner}/#{repo}",
           token_source: "GITHUB_TOKEN",
           request_error: inspect(reason)
         }}
    end
  end

  defp auth_diagnostic(reason, endpoint, status, response, owner, repo) do
    %{
      reason: reason,
      endpoint: endpoint,
      repo: "#{owner}/#{repo}",
      token_source: "GITHUB_TOKEN",
      status: status,
      rate_limit_remaining: Errors.rate_limit_remaining(response),
      rate_limit_reset: Errors.rate_limit_reset(response)
    }
  end

  defp auth_failure_reason(401, _response), do: :invalid_or_expired_token
  defp auth_failure_reason(404, _response), do: :repo_not_accessible

  defp auth_failure_reason(403, response) do
    if Errors.rate_limited_response?(response, :unknown), do: :rate_limited, else: :forbidden
  end

  defp auth_failure_reason(_status, _response), do: :http_status

  defp enrich_auth_diagnostic(diagnostic, gh_auth_status_fun) do
    gh_status = safe_gh_auth_status(gh_auth_status_fun)

    diagnostic
    |> Map.put(:gh_keyring_status, gh_status)
    |> Map.put(:message, diagnostic_message(diagnostic, gh_status))
  end

  defp safe_gh_auth_status(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, status} -> status
      status when status in [:available, :unavailable, :not_installed] -> status
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp diagnostic_message(diagnostic, gh_status) do
    repo = diagnostic.repo
    endpoint = diagnostic.endpoint
    source = diagnostic.token_source
    reason = human_auth_reason(diagnostic)
    keyring = human_gh_keyring_status(gh_status)

    [
      "GitHub auth preflight failed for #{source} while validating #{repo} #{endpoint} access: #{reason}.",
      "Aiur uses GITHUB_TOKEN for GitHub tracker/API calls, and that environment token takes precedence over `gh` keyring auth.",
      keyring,
      "Recovery: refresh or unset GITHUB_TOKEN in the shell or .env used to launch aiur, restart aiur so the daemon inherits the fixed environment, then verify `gh api rate_limit` and `gh api repos/#{repo}/issues?per_page=1` without printing token material."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp human_auth_reason(%{reason: :invalid_or_expired_token, status: status}),
    do: "GitHub returned HTTP #{status}, which usually means the token is invalid or expired"

  defp human_auth_reason(%{reason: :rate_limited, status: status, rate_limit_remaining: 0, rate_limit_reset: reset}),
    do: "GitHub returned HTTP #{status} and the REST rate limit is exhausted#{reset_suffix(reset)}"

  defp human_auth_reason(%{reason: :rate_limited, status: status}),
    do: "GitHub returned HTTP #{status} with a rate-limit response"

  defp human_auth_reason(%{reason: :forbidden, status: status}),
    do: "GitHub returned HTTP #{status}, which usually means missing repository permissions or a secondary rate limit"

  defp human_auth_reason(%{reason: :repo_not_accessible, status: status}),
    do: "GitHub returned HTTP #{status}, so the token cannot access the configured repository or github.repo is wrong"

  defp human_auth_reason(%{classification: :dns}), do: "DNS resolution failed while connecting to api.github.com"
  defp human_auth_reason(%{classification: :timeout}), do: "the request timed out or the connection was closed before GitHub returned a status"
  defp human_auth_reason(%{classification: :tls}), do: "TLS negotiation failed before GitHub returned a status"

  defp human_auth_reason(%{classification: :transport, request_error: error}),
    do: "the request failed before GitHub returned a status (#{error})"

  defp human_auth_reason(%{reason: :request_failed, request_error: error}),
    do: "the request failed before GitHub returned a status (#{error})"

  defp human_auth_reason(%{status: status}), do: "GitHub returned HTTP #{status}"
  defp human_auth_reason(_diagnostic), do: "GitHub auth check failed"

  defp reset_suffix(nil), do: ""
  defp reset_suffix(reset), do: " until #{reset}"

  defp human_gh_keyring_status(:available),
    do: "`gh` keyring auth appears usable when GITHUB_TOKEN is removed, but Aiur will not use it while GITHUB_TOKEN is set."

  defp human_gh_keyring_status(:unavailable), do: "`gh` keyring auth was not usable when checked without GITHUB_TOKEN."
  defp human_gh_keyring_status(:not_installed), do: "`gh` is not installed or not on PATH, so only GITHUB_TOKEN can be validated."
  defp human_gh_keyring_status(_), do: "`gh` keyring auth status could not be determined."

  defp default_gh_auth_status_fun do
    case System.find_executable("gh") do
      nil ->
        {:ok, :not_installed}

      gh ->
        case System.cmd(gh, ["auth", "status"],
               env: [{"GITHUB_TOKEN", nil}],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> {:ok, :available}
          {_output, _status} -> {:ok, :unavailable}
        end
    end
  rescue
    _ -> {:ok, :unknown}
  end
end
