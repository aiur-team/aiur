defmodule Aiur.Orchestrator.RetryEngine.Scheduling do
  @moduledoc "Retry scheduling, delays and metadata."

  require Logger
  import Bitwise, only: [<<<: 2]

  alias Aiur.Alerts
  alias Aiur.Config
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.RetryEngine.Exhaustion
  alias Aiur.Orchestrator.RetryEngine.HoldStreak
  alias Aiur.Orchestrator.RetryEngine.PollFailure
  alias Aiur.Orchestrator.State

  @continuation_retry_delay_ms 1_000

  @failure_retry_base_ms 10_000

  @max_retry_poll_failures 3

  @spec schedule_issue_retry(State.t(), String.t(), integer() | nil, map()) :: State.t()
  def schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    transient_reason = pick_retry_transient_reason(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    tracker_identity = pick_retry_tracker_identity(previous_retry, metadata)
    priority = pick_retry_priority(previous_retry, metadata)
    issue_state = pick_retry_issue_state(previous_retry, metadata)
    rework_head_sha = Map.get(metadata, :rework_head_sha, Map.get(previous_retry, :rework_head_sha))
    last_failure_at = pick_retry_last_failure_at(previous_retry, metadata)
    prior_work? = pick_retry_prior_work(previous_retry, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_poll_failures = pick_retry_poll_failures(previous_retry, metadata)

    if is_reference(old_timer), do: Process.cancel_timer(old_timer)
    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    if failure_retry?(metadata) and next_attempt > Config.max_retry_attempts() do
      failed_attempts = max(next_attempt - 1, Map.get(previous_retry, :attempt, 0))

      Logger.warning("Giving up on issue_id=#{issue_id} issue_identifier=#{identifier} after #{failed_attempts} failed attempt(s); max_retry_attempts=#{Config.max_retry_attempts()}#{error_suffix}")

      alert_message = Exhaustion.retry_exhausted_alert_message(error)

      Alerts.emit_custom("ticket.#{identifier}.agent.retry_exhausted", alert_message,
        issue: identifier,
        reason: alert_message,
        needs_attention: true,
        severity: "warning"
      )

      # The structured transient reason wins when recorded; otherwise the
      # formatted error string is the fallback (which
      # `Errors.retryable_github_error?/1` treats as permanent).
      exhaustion_reason = Exhaustion.effective_exhaustion_reason(transient_reason, error)

      # Release the claim so a later label-driven re-dispatch (Executor moves the
      # ticket from `error` back to an active state) is picked up without a full
      # daemon restart (#699). The crash path pops `running` but deliberately
      # holds the claim across retries; on give-up that hold must end, otherwise
      # the issue lingers in `claimed` and `dispatch_candidate?/4` refuses it for
      # the daemon's lifetime. Mirrors the retry-poll exhaustion path, which
      # already releases the claim.
      #
      # The `Exhaustion.move_exhausted_issue_to_error_state/2` above is best-effort: if that
      # tracker write fails the issue keeps its active-state label, so releasing
      # the claim leaves it eligible for an immediate re-dispatch with a fresh
      # retry budget. That re-dispatch thrash is the class the per-issue
      # `check_thrash_budget/3` breaker exists to bound (it trips with a
      # needs_attention `thrash_circuit_open` alert), and a recovered tracker
      # write parks the ticket in `error` on the next give-up — keeping the
      # ticket recoverable without a restart rather than stranding it in
      # `claimed`, which is the behaviour #699 is fixing.
      #
      # When the exhaustion cause is a transient infrastructure fault (tracker
      # 403 / rate limit / provider timeout / transport), `move_exhausted_issue_to_error_state`
      # skips the terminal `agent:error` write, and the bounded automatic
      # re-dispatch below recovers the ticket once the cause clears instead of
      # parking it in a terminal state until an operator notices (#1453, #2427).

      released =
        state
        |> RetryEngine.release_issue_claim(issue_id)
        |> PollFailure.record_claim_release(issue_id, exhaustion_reason)

      released =
        Exhaustion.maybe_schedule_transient_auto_resume(
          released,
          issue_id,
          exhaustion_reason
        )

      PollFailure.emit_claim_released_alert(released, issue_id, identifier, failed_attempts, exhaustion_reason, %{worker_host: worker_host})

      released
      |> Map.put(:retry_attempts, Map.delete(released.retry_attempts, issue_id))
      |> Exhaustion.start_exhausted_state_write(issue_id, identifier, exhaustion_reason, Map.put(metadata, :rework_head_sha, rework_head_sha))
    else
      delay_ms = retry_delay(next_attempt, metadata)
      retry_token = make_ref()
      # `:now_ms` lets tests drive the hold-streak clock (#4693).
      now_ms = metadata[:now_ms] || System.monotonic_time(:millisecond)
      due_at_ms = now_ms + delay_ms

      timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

      log_scheduled_retry(
        issue_id,
        identifier,
        delay_ms,
        next_attempt,
        retry_poll_failures,
        metadata,
        error_suffix
      )

      %{
        state
        | retry_attempts:
            Map.put(state.retry_attempts, issue_id, %{
              attempt: next_attempt,
              timer_ref: timer_ref,
              retry_token: retry_token,
              due_at_ms: due_at_ms,
              identifier: identifier,
              error: error,
              last_failure_at: last_failure_at,
              transient_reason: transient_reason,
              retry_poll_failures: retry_poll_failures,
              prior_work: prior_work?,
              worker_host: worker_host,
              workspace_path: workspace_path,
              tracker_identity: tracker_identity,
              priority: priority,
              issue_state: issue_state,
              rework_head_sha: rework_head_sha,
              terminal_membership_pending?: metadata[:terminal_membership_pending?] == true,
              # Persisted so the non-consuming classification is observable and
              # asserted directly: a `:local_budget_hold` retry is bounded by
              # the hold's own `reset_at` and never advances toward give-up
              # (#2429 rework round 2). `pop_retry_attempt_state/3` deliberately
              # does not round-trip it — the retry path reclassifies the failure
              # it sees at dispatch time rather than trusting stale metadata.
              delay_type: metadata[:delay_type],
              local_budget_hold: metadata[:local_budget_hold]
            })
      }
      |> record_hold_deferral(issue_id, identifier, metadata, now_ms)
    end
  end

  # A hold retry never consumes the failure budget, so a hold that never clears is surfaced by duration instead (#4693).
  defp record_hold_deferral(state, issue_id, identifier, %{delay_type: :local_budget_hold, local_budget_hold: %{} = hold}, now_ms),
    do: HoldStreak.record(state, issue_id, identifier, hold, now_ms)

  # Any other retry means the hold lifted, so the streak ends; a later hold starts a fresh one.
  defp record_hold_deferral(state, issue_id, _identifier, _metadata, _now_ms), do: HoldStreak.clear(state, issue_id)

  @spec failure_retry?(map()) :: boolean()
  def failure_retry?(metadata) when is_map(metadata) do
    Map.get(metadata, :delay_type) not in [
      :continuation,
      :capacity_wait,
      :model_limit_wait,
      :local_budget_hold,
      :precondition,
      :terminal_verification
    ]
  end

  @spec pop_retry_attempt_state(State.t(), String.t(), reference()) ::
          {:ok, integer(), map(), State.t()} | :missing
  def pop_retry_attempt_state(%State{} = state, issue_id, retry_token)
      when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          last_failure_at: Map.get(retry_entry, :last_failure_at),
          transient_reason: Map.get(retry_entry, :transient_reason),
          retry_poll_failures: Map.get(retry_entry, :retry_poll_failures),
          prior_work: Map.get(retry_entry, :prior_work, false),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          tracker_identity: Map.get(retry_entry, :tracker_identity),
          priority: Map.get(retry_entry, :priority),
          issue_state: Map.get(retry_entry, :issue_state),
          terminal_membership_pending?: Map.get(retry_entry, :terminal_membership_pending?, false),
          rework_head_sha: Map.get(retry_entry, :rework_head_sha)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  @spec retry_delay(integer(), map()) :: non_neg_integer()
  def retry_delay(attempt, %{delay_type: :continuation})
      when is_integer(attempt) and attempt == 1 do
    @continuation_retry_delay_ms
  end

  def retry_delay(_attempt, %{delay_type: :capacity_wait}) do
    @continuation_retry_delay_ms
  end

  def retry_delay(_attempt, %{delay_type: :model_limit_wait}) do
    max(Config.poll_interval_seconds() * 1_000, 10_000)
  end

  def retry_delay(_attempt, %{delay_type: :local_budget_hold, local_budget_hold: hold}) do
    reset_delay = PollFailure.local_budget_reset_delay(hold)
    min(max(reset_delay, 1_000), Config.settings!().agent.max_retry_backoff_ms)
  end

  def retry_delay(_attempt, %{
        delay_type: :precondition,
        retry_poll_failures: retry_poll_failures
      }) do
    retry_poll_failures
    |> normalize_retry_poll_failures()
    |> max(1)
    |> failure_retry_delay()
  end

  def retry_delay(attempt, metadata)
      when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    failure_retry_delay(attempt)
  end

  @spec failure_retry_delay(integer()) :: non_neg_integer()
  def failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)

    min(
      @failure_retry_base_ms * (1 <<< max_delay_power),
      Config.settings!().agent.max_retry_backoff_ms
    )
  end

  @spec normalize_retry_attempt(integer() | term()) :: non_neg_integer()
  def normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  def normalize_retry_attempt(_attempt), do: 0

  @spec next_retry_attempt_from_running(map()) :: pos_integer() | nil
  def next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp log_scheduled_retry(
         issue_id,
         identifier,
         delay_ms,
         attempt,
         retry_poll_failures,
         metadata,
         error_suffix
       ) do
    case Map.get(metadata, :delay_type) do
      :continuation ->
        Logger.warning("Scheduling continuation retry issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{attempt})#{error_suffix}")

      :capacity_wait ->
        Logger.warning("Retrying capacity precondition issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (agent_attempt #{attempt})#{error_suffix}")

      :local_budget_hold ->
        Logger.warning("Retrying local GitHub budget hold issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (agent_attempt #{attempt})#{error_suffix}")

      :precondition ->
        Logger.warning(
          "Retrying retry-poll precondition issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (agent_attempt #{attempt}, retry_poll_failure #{retry_poll_failures}/#{@max_retry_poll_failures})#{error_suffix}"
        )

      _ ->
        Logger.warning("Retrying agent failure issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{attempt})#{error_suffix}")
    end
  end

  @doc false
  @spec normalize_retry_poll_failures(term()) :: non_neg_integer()
  def normalize_retry_poll_failures(failures) when is_integer(failures) and failures > 0,
    do: failures

  def normalize_retry_poll_failures(_failures), do: 0

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_last_failure_at(previous_retry, metadata) do
    metadata[:last_failure_at] || Map.get(previous_retry, :last_failure_at)
  end

  # The structured (non-formatted) failure reason, retained so retry exhaustion
  # can classify a transient infrastructure fault for the #1453 auto-resume.
  defp pick_retry_transient_reason(previous_retry, metadata) do
    if Map.has_key?(metadata, :transient_reason) do
      Map.get(metadata, :transient_reason)
    else
      Map.get(previous_retry, :transient_reason)
    end
  end

  defp pick_retry_poll_failures(previous_retry, metadata) do
    metadata
    |> Map.get(:retry_poll_failures, Map.get(previous_retry, :retry_poll_failures))
    |> normalize_retry_poll_failures()
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_tracker_identity(previous_retry, metadata) do
    if Map.has_key?(metadata, :tracker_identity) do
      Map.get(metadata, :tracker_identity)
    else
      Map.get(previous_retry, :tracker_identity)
    end
  end

  defp pick_retry_priority(previous_retry, metadata) do
    if Map.has_key?(metadata, :priority) do
      Map.get(metadata, :priority)
    else
      Map.get(previous_retry, :priority)
    end
  end

  defp pick_retry_issue_state(previous_retry, metadata) do
    if Map.has_key?(metadata, :issue_state) do
      Map.get(metadata, :issue_state)
    else
      Map.get(previous_retry, :issue_state)
    end
  end

  defp pick_retry_prior_work(previous_retry, metadata) do
    Map.get(metadata, :prior_work, Map.get(previous_retry, :prior_work, false)) == true
  end
end
