defmodule Aiur.Orchestrator.RetryEngine.PollFailure do
  @moduledoc "Retry tracker failures, budget holds and claim release."

  require Logger

  alias Aiur.Alerts
  alias Aiur.Config
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Orchestrator.AutoResume
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.RetryEngine.Exhaustion
  alias Aiur.Orchestrator.RetryEngine.Scheduling
  alias Aiur.Orchestrator.State

  @max_retry_poll_failures 3

  @doc false
  @spec record_claim_release(State.t(), String.t(), term()) :: State.t()
  def record_claim_release(%State{} = state, issue_id, reason) when is_binary(issue_id) do
    {cause, details} = claim_release_reason(reason)

    release = %{
      cause: cause,
      details: details,
      released_at_ms: System.monotonic_time(:millisecond)
    }

    %{state | released_claims: Map.put(state.released_claims || %{}, issue_id, release)}
  end

  @spec format_retry_preflight_error(term()) :: String.t()
  def format_retry_preflight_error({:github_auth_preflight_failed, _diagnostic} = reason),
    do: GitHubClient.format_auth_preflight_error(reason)

  def format_retry_preflight_error(reason), do: inspect(reason)

  @doc false
  @spec handle_retry_poll_failure(State.t(), String.t(), integer(), map(), term()) :: State.t()
  # A tracker poll failure can be a local GitHub budget hold in several shapes:
  # raw `{:aiur, :locally_held, hold}`, the `:local_hold` classification
  # `{:github, :local_hold, %{hold: hold}}` (#2429), the legacy
  # `{:github, :transport, %{reason: ...}}` wrapper old classifier versions
  # produced, the `{:github_auth_preflight_failed, %{classification:
  # :local_hold}}` diagnostic `ensure_tracker_preflight` surfaces when the
  # preflight probe itself is held, and any of those wrapped in
  # `{:workspace_github_connectivity_failed, workspace, inner}`. All must take
  # the non-consuming `:local_budget_hold` retry instead of counting against
  # the retry budget meant for genuine agent failures (#2409, #2339).
  # `local_budget_hold_reason/1` is the single extraction shared with agent-exit
  # retry metadata, so a seconds-long hold can never exhaust a budget or stamp
  # `agent:error` (#2429).
  def handle_retry_poll_failure(%State{} = state, issue_id, attempt, metadata, reason) do
    case local_budget_hold_reason(reason) do
      %{} = hold ->
        defer_retry_poll_for_budget_hold(state, issue_id, attempt, metadata, hold, reason)

      nil ->
        handle_generic_retry_poll_failure(state, issue_id, attempt, metadata, reason)
    end
  end

  defp handle_generic_retry_poll_failure(%State{} = state, issue_id, attempt, metadata, reason) do
    identifier = metadata[:identifier] || issue_id
    retry_poll_failures = Scheduling.normalize_retry_poll_failures(metadata[:retry_poll_failures]) + 1

    Logger.warning(
      "Retry poll failed for issue_id=#{issue_id} issue_identifier=#{identifier} retry_poll_failure=#{retry_poll_failures}/#{@max_retry_poll_failures} agent_attempt=#{attempt} tracker_error=#{inspect(reason)}"
    )

    if retry_poll_failures >= @max_retry_poll_failures and not metadata[:terminal_membership_pending?] do
      # A transient tracker failure (403 / rate limit / provider timeout) that
      # exhausted retry polling schedules a bounded automatic re-dispatch once
      # the cause clears, instead of parking until an operator notices (#1453).
      released =
        state
        |> RetryEngine.release_issue_claim(issue_id)
        |> record_claim_release(issue_id, reason)
        |> Exhaustion.maybe_schedule_transient_auto_resume(issue_id, reason)

      emit_claim_released_alert(released, issue_id, identifier, attempt, reason, metadata)
      released
    else
      Scheduling.schedule_issue_retry(
        state,
        issue_id,
        attempt,
        Map.merge(metadata, %{
          delay_type: :precondition,
          error: "retry poll failed: #{inspect(reason)}",
          retry_poll_failures: retry_poll_failures,
          terminal_membership_pending?: metadata[:terminal_membership_pending?] == true
        })
      )
    end
  end

  defp defer_retry_poll_for_budget_hold(state, issue_id, attempt, metadata, hold, reason) do
    identifier = metadata[:identifier] || issue_id

    Logger.warning(
      "Retry poll deferred by local GitHub budget for issue_id=#{issue_id} issue_identifier=#{identifier} " <>
        "agent_attempt=#{attempt} hold=#{inspect(hold)}"
    )

    Scheduling.schedule_issue_retry(
      state,
      issue_id,
      attempt,
      Map.merge(metadata, %{
        delay_type: :local_budget_hold,
        local_budget_hold: hold,
        error: "retry poll locally held: #{inspect(reason)}",
        retry_poll_failures: Scheduling.normalize_retry_poll_failures(metadata[:retry_poll_failures])
      })
    )
  end

  # Unwraps a local GitHub budget hold from every shape it can arrive in, so
  # `recovery_delay_options/1` can name the hold's own release time for the
  # automatic resume and agent-exit retry scheduling can route it to the
  # non-consuming `:local_budget_hold` retry (#2409, #2429):
  #
  #   * raw `{:aiur, :locally_held, hold}`
  #   * the `:local_hold` classification `Errors.classify_error` now assigns
  #     (`{:github, :local_hold, %{hold: hold}}`)
  #   * the legacy transport-classified `{:github, :transport, %{reason: ...}}`
  #     wrapper older classifier versions produced
  #   * a workspace preflight failure `{:workspace_github_connectivity_failed,
  #     workspace, inner}` — the shape an agent exits with when its workspace
  #     preflight is held (#2339)
  #   * the preflight diagnostic `{:github_auth_preflight_failed,
  #     %{classification: :local_hold, detail: ...}}` that `ensure_preflight/1`
  #     surfaces when the held request is the preflight probe itself.
  @doc false
  @spec local_budget_hold_reason(term()) :: map() | nil
  def local_budget_hold_reason({:aiur, :locally_held, hold}) when is_map(hold), do: hold
  def local_budget_hold_reason({:github, :local_hold, %{hold: hold}}) when is_map(hold), do: hold

  def local_budget_hold_reason({:github, :local_hold, %{reason: {:aiur, :locally_held, hold}}}) when is_map(hold),
    do: hold

  def local_budget_hold_reason({:github, :transport, %{reason: {:aiur, :locally_held, hold}}}) when is_map(hold), do: hold

  def local_budget_hold_reason({:workspace_github_connectivity_failed, _workspace, inner}),
    do: local_budget_hold_reason(inner)

  def local_budget_hold_reason({:github_auth_preflight_failed, %{classification: :local_hold} = diagnostic}),
    do: local_budget_hold_reason(Map.get(diagnostic, :detail))

  def local_budget_hold_reason(%{hold: hold}) when is_map(hold), do: hold
  def local_budget_hold_reason(%{reason: {:aiur, :locally_held, hold}}) when is_map(hold), do: hold
  def local_budget_hold_reason(:github_budget_broker_timeout), do: %{reason: :github_budget_broker_timeout}
  def local_budget_hold_reason(%{reason: :github_budget_broker_timeout} = detail), do: detail

  def local_budget_hold_reason({:github, classification, %{reason: :github_budget_broker_timeout} = detail})
      when classification in [:timeout, :local_hold], do: detail

  def local_budget_hold_reason({:github_auth_preflight_failed, %{classification: :timeout, detail: detail}}),
    do: local_budget_hold_reason(detail)

  def local_budget_hold_reason(_reason), do: nil

  @doc false
  @spec local_budget_reset_delay(map()) :: non_neg_integer()
  def local_budget_reset_delay(hold) do
    case Map.get(hold, :reset_at) || Map.get(hold, "reset_at") do
      %DateTime{} = reset_at -> max(DateTime.diff(reset_at, DateTime.utc_now(), :millisecond), 1_000)
      _missing -> max(Config.poll_interval_seconds() * 1_000, 10_000)
    end
  end

  @doc false
  @spec emit_claim_released_alert(State.t(), String.t(), String.t(), integer(), term(), map()) :: term()
  def emit_claim_released_alert(state, issue_id, identifier, attempt, reason, metadata) do
    {reason_code, details} = claim_release_reason(reason)
    auto_reclaim = Map.get(state.auto_resume, issue_id)
    recovery = claim_recovery_message(auto_reclaim)

    message =
      "Released claim for ticket=#{identifier} agent=#{metadata[:worker_host] || identifier} after #{@max_retry_poll_failures} tracker failures " <>
        "(reason=#{reason_code}, credential=#{credential_identity()}#{claim_release_detail_suffix(details)}). #{recovery}"

    Logger.error(
      "Claim released for issue_id=#{issue_id} issue_identifier=#{identifier} agent_attempt=#{attempt} " <>
        "max_retry_poll_failures=#{@max_retry_poll_failures} reason=#{reason_code} tracker_error=#{inspect(reason)}"
    )

    Alerts.emit_custom(
      "orchestrator.claim_released",
      message,
      issue: identifier,
      worker_host: metadata[:worker_host],
      reason: message,
      needs_attention: true,
      severity: "warning"
    )
  end

  defp claim_release_reason({:github, :rate_limited, details}) when is_map(details), do: {:rate_limit_exhausted, details}

  defp claim_release_reason({:workspace_hook_timeout, "before_run", timeout_ms}) when is_integer(timeout_ms),
    do: {:workspace_hook_timeout, %{hook: "before_run", timeout_ms: timeout_ms}}

  defp claim_release_reason(_reason), do: {:tracker_retry_exhausted, %{}}

  @doc false
  @spec recovery_delay_options(term()) :: keyword()
  def recovery_delay_options({:github, :rate_limited, details}) when is_map(details) do
    [retry_after: details[:retry_after], reset_at: details[:reset_at]]
  end

  # A local budget hold names its own release time (`reset_at`); the automatic
  # resume should not fire before it, or it would re-dispatch straight back into
  # the same hold. Handles the raw `{:aiur, :locally_held, hold}` and the
  # `:local_hold` / legacy transport-classified `{:github, ...}` forms (#2409,
  # #2429).
  def recovery_delay_options(reason) do
    case local_budget_hold_reason(reason) do
      %{reset_at: %DateTime{} = reset_at} ->
        [reset_at: DateTime.to_iso8601(reset_at)]

      _other ->
        []
    end
  end

  # Identify the credential that actually made the rate-limited request, not the
  # one the operator configured. `GitHubConfig.bot_account/0` is a config string:
  # under a GitHub App installation token it names a different principal than the
  # token in use, and naming the wrong principal on a security-adjacent alert is
  # worse than naming none. A fingerprint of the token that was actually used is
  # verifiable; when there is no token, say `unknown`.
  #
  # The verified login (`Aiur.GitHub.BotIdentity.fetch_authenticated_viewer_login/2`)
  # is deliberately not used here: it costs a live GitHub API call, and this code
  # path runs precisely when GitHub has stopped answering (#1475).
  defp credential_identity do
    case GitHubConfig.token() do
      token when is_binary(token) and byte_size(token) > 0 ->
        "token-sha256:" <> (:crypto.hash(:sha256, token) |> Base.encode16(case: :lower) |> binary_part(0, 12))

      _ ->
        "unknown"
    end
  end

  defp claim_release_detail_suffix(details) do
    [:remaining, :reset_at, :retry_after]
    |> Enum.flat_map(fn key ->
      case Map.get(details, key) do
        nil -> []
        value -> [", #{key}=#{value}"]
      end
    end)
    |> Enum.join()
  end

  defp claim_recovery_message(%{cause: :rate_limit, attempt: attempt}) do
    "Automatic re-claim is scheduled after rate-limit recovery (attempt #{attempt}/#{AutoResume.max_attempts()})."
  end

  defp claim_recovery_message(%{cause: :local_budget_hold, attempt: attempt}) do
    "Automatic re-claim is scheduled after the local GitHub budget hold lifts (attempt #{attempt}/#{AutoResume.max_attempts()})."
  end

  defp claim_recovery_message(%{cause: cause, attempt: attempt}) do
    "Automatic re-claim is scheduled after #{cause} recovery (attempt #{attempt}/#{AutoResume.max_attempts()})."
  end

  defp claim_recovery_message(_auto_reclaim), do: "Automatic re-claim is not scheduled; operator recovery is required."
end
