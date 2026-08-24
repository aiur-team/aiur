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
  2. **A `401` on the proven credential clears it.**
     `Aiur.GitHub.Transport` reports every non-preflight response to
     `note_response/2`. The next cycle therefore pays for the full
     three-request check and produces the ordinary
     `:github_auth_preflight_failed` diagnostic rather than letting a raw `401`
     surface downstream. See `note_response/2` for why `403` is deliberately
     not evidence.
  3. **`invalidate/1` clears it outright**, for anything else that decides the
     answer is suspect. It bumps an invalidation epoch *unconditionally*, which
     is what closes the window where a revocation arrives while a check is
     mid-flight and the memo is legitimately empty — see `prove/5`.

  Note that (1) covers config reloads without a hook: the owner, repo and token
  are re-read from config on every `ensure_preflight/1` call and folded into the
  key, so a reload that moves `github.repo` or the token source is a miss by
  construction. A GitHub App installation token rotates roughly hourly, so App
  deployments re-prove auth once per rotation — that is the intended behaviour,
  since the credential genuinely changed.

  Failures are never memoized, so a broken credential is re-checked every
  cycle exactly as it is today.
  """

  alias Aiur.GitHub.{Config, Errors, HostCommand, Transport}

  require Logger

  @memo_key {__MODULE__, :proven_identity}
  @epoch_key {__MODULE__, :invalidation_epoch}

  @spec preflight_auth(keyword()) :: :ok | {:error, term()}
  def preflight_auth(opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      # The diagnostic form still spends three requests every time, but a
      # success is evidence like any other: recording it means the poll cycle
      # that follows boot or workspace creation does not immediately re-prove
      # what was just proven.
      prove(identity_key(owner, repo, token), owner, repo, token, opts)
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

  # Only a success is remembered, and only if nothing invalidated while the
  # three requests were in flight. Without the epoch check there is a real
  # window: the memo is empty during the check, so a `401` arriving mid-flight
  # finds nothing to erase, and the `:ok` that was true when it was issued then
  # re-blesses a credential that has since died. A failure is never memoized,
  # so a broken credential is re-checked on the very next cycle.
  defp prove(key, owner, repo, token, opts) do
    observed_epoch = epoch()

    case run_full_preflight(owner, repo, token, opts) do
      :ok ->
        if epoch() == observed_epoch, do: memoize(key)
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
    # The epoch bump is unconditional and comes first. Guarding it on "is
    # anything memoized right now" would lose exactly the signal that matters:
    # an invalidation arriving while a preflight is mid-flight, when the memo
    # is legitimately empty.
    bump_epoch()

    if memoized_identity() do
      Logger.debug("GitHub auth preflight memo invalidated (#{inspect(reason)})")
      :persistent_term.erase(@memo_key)
    end

    :ok
  end

  @doc """
  Observes a GitHub response and invalidates the memo when the credential it
  was issued with stopped working.

  Called by `Aiur.GitHub.Transport` for every request it issues. Three things
  are deliberately *not* treated as evidence:

    * **A preflight's own response.** It reports its own result.
    * **Anything other than `401`.** A `403` is either a rate limit or a
      missing permission, and in both cases the preflight itself would still
      return `:ok` — so invalidating on one produces an endless
      erase/re-prove/erase loop that costs three requests per cycle forever and
      never converges. Revocation, expiry and a suspended App installation all
      surface as `401`.
    * **A `401` from some other credential.** The App JWT used to mint
      installation tokens is not the tracker token; a `401` on it says nothing
      about the one that was proven. A request with no token is treated as
      unknown and does invalidate, which fails safe.
  """
  @spec note_response(map(), term()) :: :ok
  def note_response(%{preflight?: true}, _result), do: :ok

  def note_response(request, {:ok, %{status: 401}}) do
    if same_credential?(request), do: invalidate(:unauthorized), else: :ok
  end

  def note_response(_request, _result), do: :ok

  defp same_credential?(request) do
    case {Map.get(request, :token), memoized_identity()} do
      {token, {_owner, _repo, digest}} when is_binary(token) -> :crypto.hash(:sha256, token) == digest
      _unknown -> true
    end
  end

  @doc false
  @spec memoized_identity() :: term() | nil
  def memoized_identity, do: :persistent_term.get(@memo_key, nil)

  # A counter rather than another `:persistent_term`: invalidation can be
  # frequent under a failing credential, and every `:persistent_term` write
  # scans each process heap in the VM.
  defp epoch, do: :counters.get(epoch_ref(), 1)
  defp bump_epoch, do: :counters.add(epoch_ref(), 1, 1)

  # Lazily seeded. Two processes racing the very first call could each build a
  # counter, and the loser's bump would be dropped — but the first call happens
  # at boot, before any preflight is in flight, so there is nothing to drop.
  defp epoch_ref do
    case :persistent_term.get(@epoch_key, nil) do
      nil ->
        ref = :counters.new(1, [:atomics])
        :persistent_term.put(@epoch_key, ref)
        :persistent_term.get(@epoch_key)

      ref ->
        ref
    end
  end

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

  @doc """
  True when a preflight failure is a local budget hold (`{:aiur, :locally_held,
  ...}`), i.e. a local counter trip rather than a connectivity or credential
  problem. Callers use this to avoid reporting a local hold as lost GitHub
  connectivity, which is exactly the misattribution #2429 removes.
  """
  @spec local_hold_reason?(term()) :: boolean()
  def local_hold_reason?({:github_auth_preflight_failed, diagnostic}) when is_map(diagnostic),
    do: local_hold_diagnostic?(diagnostic)

  def local_hold_reason?({:aiur, :locally_held, _hold}), do: true
  def local_hold_reason?(_reason), do: false

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

  # The token source follows the credential actually in use, resolved by
  # `Aiur.GitHub.Config.token_source/0` — GITHUB_APP for an App installation
  # token, GITHUB_TOKEN for an env var, or the `gh` keyring for a token from
  # `gh auth login`. Reporting "GITHUB_TOKEN" when the credential came from the
  # keyring sent a developer who never set that variable to refresh or unset it.
  defp token_source do
    case Config.token_source() do
      :github_app -> "GITHUB_APP"
      :env -> "GITHUB_TOKEN"
      :keyring -> "gh keyring"
      :none -> "no credential"
    end
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
    if local_hold_diagnostic?(diagnostic) do
      local_hold_message(diagnostic)
    else
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
            pat_source_line(source),
            keyring,
            pat_recovery_line(source, repo)
          ]
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.join(" ")
      end
    end
  end

  # A local GitHub budget hold is a local counter trip, not a GitHub or App
  # problem. The generic recovery text above sends the operator to reinstall
  # the App or rotate GITHUB_TOKEN, which can never fix a local hold and would
  # turn a working App into an unnecessary reinstall (#2429 F3). Recognize the
  # classification `Errors.classify_error` now assigns, plus the raw
  # `{:aiur, :locally_held, ...}` tuple in `request_error` for any path that
  # predates the classifier fix.
  defp local_hold_diagnostic?(diagnostic) do
    Map.get(diagnostic, :classification) == :local_hold or
      local_hold_request_error?(Map.get(diagnostic, :request_error))
  end

  defp local_hold_request_error?(error) when is_binary(error),
    do: String.contains?(error, "{:aiur, :locally_held,")

  defp local_hold_request_error?(_error), do: false

  defp local_hold_message(diagnostic) do
    repo = diagnostic.repo
    endpoint = diagnostic.endpoint
    source = diagnostic.token_source
    reason = human_auth_reason(diagnostic)

    [
      "GitHub auth preflight failed for #{source} while validating #{repo} #{endpoint} access: #{reason}.",
      "This is a local budget hold: aiur's request guard throttled a shared resource before the request reached GitHub, so no GitHub-side or App change can fix it.",
      "Recovery: wait for the hold to clear (it names its own reset), or raise the relevant tracker.github.*_limit_per_hour limit in .aiur/config, then restart aiur."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp pat_source_line("GITHUB_TOKEN"),
    do: "Aiur uses GITHUB_TOKEN for GitHub tracker/API calls, and that environment token takes precedence over `gh` keyring auth."

  defp pat_source_line(_source),
    do: "Aiur authenticates with the `gh` keyring token obtained by `gh auth login`."

  defp pat_recovery_line("GITHUB_TOKEN", repo),
    do:
      "Recovery: refresh or unset GITHUB_TOKEN in the shell or .env used to launch aiur, " <>
        "restart aiur so the daemon inherits the fixed environment, then verify `gh api rate_limit` " <>
        "and `gh api repos/#{repo}/issues?per_page=1` without printing token material."

  defp pat_recovery_line(_source, repo),
    do:
      "Recovery: verify `gh auth login` is logged in for github.com (`gh auth status`), restart aiur " <>
        "so the daemon re-resolves the keyring credential, then verify `gh api rate_limit` " <>
        "and `gh api repos/#{repo}/issues?per_page=1` without printing token material."

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

  defp human_auth_reason(%{classification: :local_hold, request_error: error}),
    do: "the request was locally held by aiur's budget guard before GitHub returned a status (#{error})"

  defp human_auth_reason(%{classification: :local_hold}),
    do: "the request was locally held by aiur's budget guard before GitHub returned a status"

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
    case HostCommand.find_executable() do
      nil ->
        {:ok, :not_installed}

      _gh ->
        # This check deliberately inspects the operator's keyring: GITHUB_TOKEN
        # is unset so `gh auth status` reports the keyring account, not the
        # daemon's credential. Routing it through the host guard means that
        # deliberate keyring check is admitted and recorded under the keyring
        # identity (#2353) instead of spending silently.
        case HostCommand.run(["auth", "status"], env: [{"GITHUB_TOKEN", nil}], stderr_to_stdout: true) do
          {_output, 0} -> {:ok, :available}
          {_output, _status} -> {:ok, :unavailable}
        end
    end
  rescue
    _ -> {:ok, :unknown}
  end
end
