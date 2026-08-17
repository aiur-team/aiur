defmodule Aiur.GitHub.AuthPreflight do
  @moduledoc """
  GitHub authentication preflight diagnostics.

  ## Two entry points, and why

  `preflight_auth/1` always spends three requests. It is the diagnostic form:
  daemon boot, workspace creation, anything an operator asked for directly.

  `ensure_preflight/1` is the form the orchestrator's poll cycle calls. It runs
  the same three requests, remembers a success, and then answers `:ok` from
  memory until something says the answer may have changed. Before this, the
  cycle re-proved credentials on every tick — 3 requests × 6 idle cycles = 18
  per hour, 12 of them billed, to re-derive a fact that had not moved since
  boot.

  ## What invalidates the memo — the whole safety argument

  The memo is *evidence-driven*, never time-driven. There is no TTL, because a
  TTL would both cost requests forever and still lag a revocation. Instead:

  1. **The credential itself is part of the key.** The entry is keyed by
     `{owner, repo, sha256(token)}`. A rotated `GITHUB_TOKEN`, a fresh
     `AppTokenRefresher` installation token, or a `github.repo` change all
     produce a different key, so the next call misses and re-runs the full
     check. Nothing has to remember to invalidate on rotation.
  2. **Any GitHub call that comes back unauthenticated clears it.**
     `Aiur.GitHub.Transport` reports every non-preflight response to
     `note_response/2`; a `401`, or a `403` that is not a rate-limit response,
     drops the entry. The next cycle therefore pays for the full three-request
     check and produces the ordinary `:github_auth_preflight_failed`
     diagnostic rather than letting a raw `401` surface downstream.
  3. **`invalidate/1` clears it outright**, for anything else that decides the
     answer is suspect.

  Note that (1) covers config reloads without a hook: the owner, repo and token
  are re-read from config on every `ensure_preflight/1` call and folded into the
  key, so a reload that moves `github.repo` or the token source is a miss by
  construction. A GitHub App installation token rotates roughly hourly, so App
  deployments re-prove auth once per rotation — that is the intended behaviour,
  since the credential genuinely changed.

  Failures are never memoized, so a broken credential is re-checked every
  cycle exactly as it is today.
  """

  alias Aiur.GitHub.{AppCredentials, Errors, Transport}

  require Logger

  @memo_key {__MODULE__, :proven_identity}

  @spec preflight_auth(keyword()) :: :ok | {:error, term()}
  def preflight_auth(opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      run_full_preflight(owner, repo, token, opts)
    end
  end

  @doc """
  Preflight that spends nothing once auth has been proven for this credential.

  Returns `:ok` immediately while a successful check for the current
  `{owner, repo, token}` identity is still held. On a miss it runs the full
  `preflight_auth/1` check and memoizes only a success.
  """
  @spec ensure_preflight(keyword()) :: :ok | {:error, term()}
  def ensure_preflight(opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      key = identity_key(owner, repo, token)

      if memoized?(key) do
        :ok
      else
        prove(key, owner, repo, token, opts)
      end
    end
  end

  # Only a success is remembered. A failure stays uncached so a broken
  # credential is re-checked on the very next cycle.
  defp prove(key, owner, repo, token, opts) do
    case run_full_preflight(owner, repo, token, opts) do
      :ok ->
        memoize(key)
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Drops any memoized preflight success, so the next `ensure_preflight/1` pays
  for the full three-request check again.
  """
  @spec invalidate(atom()) :: :ok
  def invalidate(reason \\ :manual) do
    if memoized_identity() do
      Logger.debug("GitHub auth preflight memo invalidated (#{inspect(reason)})")
      :persistent_term.erase(@memo_key)
    end

    :ok
  end

  @doc """
  Observes a GitHub response and invalidates the memo when it looks like the
  credential stopped working.

  Called by `Aiur.GitHub.Transport` for every request it issues. Preflight
  requests report their own result and are ignored here. A `403` that carries
  rate-limit headers is a quota problem, not an auth problem, and is ignored
  too — otherwise an exhausted budget would buy three more requests per cycle.
  """
  @spec note_response(map(), term()) :: :ok
  def note_response(%{preflight?: true}, _result), do: :ok

  def note_response(_request, {:ok, %{status: 401}}), do: invalidate(:unauthorized)

  def note_response(_request, {:ok, %{status: 403} = response}) do
    if Errors.rate_limited_response?(response, :unknown) do
      :ok
    else
      invalidate(:forbidden)
    end
  end

  def note_response(_request, _result), do: :ok

  @doc false
  @spec memoized_identity() :: term() | nil
  def memoized_identity, do: :persistent_term.get(@memo_key, nil)

  defp run_full_preflight(owner, repo, token, opts) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    gh_auth_status_fun = Keyword.get(opts, :gh_auth_status_fun, &default_gh_auth_status_fun/0)

    owner
    |> preflight_checks(repo)
    |> run_preflight_checks(request_fun, token, owner, repo)
    |> finalize_preflight_result(gh_auth_status_fun)
  end

  # The token never lands in the table; only a digest of it does.
  defp identity_key(owner, repo, token) do
    {owner, repo, :crypto.hash(:sha256, token)}
  end

  defp memoized?(key), do: memoized_identity() == key

  # `:persistent_term` rather than ETS: the memo must outlive whichever process
  # happened to prove auth first, and the write rate is one per credential
  # identity, not one per cycle.
  defp memoize(key) do
    unless memoized?(key) do
      :persistent_term.put(@memo_key, key)
    end

    :ok
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
           token_source: token_source(),
           request_error: inspect(reason)
         }}
    end
  end

  defp auth_diagnostic(reason, endpoint, status, response, owner, repo) do
    %{
      reason: reason,
      endpoint: endpoint,
      repo: "#{owner}/#{repo}",
      token_source: token_source(),
      status: status,
      rate_limit_remaining: Errors.rate_limit_remaining(response),
      rate_limit_reset: Errors.rate_limit_reset(response)
    }
  end

  defp token_source do
    if AppCredentials.configured?(), do: "GITHUB_APP", else: "GITHUB_TOKEN"
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

    case source do
      "GITHUB_APP" ->
        [
          "GitHub auth preflight failed for #{source} while validating #{repo} #{endpoint} access: #{reason}.",
          "Aiur authenticates with a GitHub App installation token when GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and the App private key are configured.",
          "Recovery: verify the App is installed on #{repo} with only Contents: write, Issues: read/write, Pull requests: write, then restart aiur so the daemon re-acquires a fresh installation token."
        ]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" ")

      _ ->
        [
          "GitHub auth preflight failed for #{source} while validating #{repo} #{endpoint} access: #{reason}.",
          "Aiur uses GITHUB_TOKEN for GitHub tracker/API calls, and that environment token takes precedence over `gh` keyring auth.",
          keyring,
          "Recovery: refresh or unset GITHUB_TOKEN in the shell or .env used to launch aiur, restart aiur so the daemon inherits the fixed environment, then verify `gh api rate_limit` and `gh api repos/#{repo}/issues?per_page=1` without printing token material."
        ]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" ")
    end
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
