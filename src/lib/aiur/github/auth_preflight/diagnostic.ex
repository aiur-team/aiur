defmodule Aiur.GitHub.AuthPreflight.Diagnostic do
  @moduledoc false

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

  @doc false
  @spec diagnostic_message(map(), atom()) :: String.t()
  def diagnostic_message(diagnostic, gh_status) do
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
            "Recovery: verify the App is installed on #{repo} with only Contents: write, Issues: read/write, Pull requests: write, then restart aiur so the daemon re-acquires a fresh installation token.",
            app_over_token_line(diagnostic)
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

  defp local_hold_message(%{detail: %{reason: :github_budget_broker_timeout}} = diagnostic) do
    "GitHub preflight for #{diagnostic.repo} is waiting on the local budget broker. " <>
      "The broker deadline expired before GitHub was contacted. Recovery: reduce host load or SQLite contention; aiur retries without consuming worker attempts."
  end

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

  # A 404 under App auth while GITHUB_TOKEN is also set usually means the
  # operator configured a token for this repository but App credentials from
  # a shell export, the same .env file, or `~/.aiur/.env` under a launcher
  # that predates #2638 took precedence. "Install the App" is the wrong
  # recovery for that case.
  defp app_over_token_line(%{reason: :repo_not_accessible}) do
    if nonblank_env?("GITHUB_TOKEN") do
      "GITHUB_TOKEN is also set, but configured GitHub App credentials take precedence over it. " <>
        "If this repository should authenticate with that token, unset GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, " <>
        "GITHUB_APP_PRIVATE_KEY_PATH and GITHUB_APP_PRIVATE_KEY in the shell and .env files used to launch aiur " <>
        "(a repository .env that sets GITHUB_TOKEN does not inherit App credentials from ~/.aiur/.env), then restart aiur."
    end
  end

  defp app_over_token_line(_diagnostic), do: nil

  defp nonblank_env?(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
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
end
