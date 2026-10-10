defmodule Aiur.Orchestrator.AutoResume do
  @moduledoc """
  Bounded automatic re-dispatch for tickets parked in a transient pause/error
  state (#1453).

  When a dispatch or retry fails on a classifiably transient cause (tracker
  HTTP failure / rate limit / provider timeout), the ticket can end up in
  `agent:error` (retry exhaustion) or have its claim released with nothing
  scheduled to retry once the cause clears. This module records those tickets
  and, after a bounded backoff (2m / 5m / 15m, max 3 attempts), flips them
  back to a dispatchable state and re-dispatches — no operator resume needed.

  Exemptions are structural, not per-entry checks that can drift:
    * entries are only ever scheduled by the transient-failure paths in
      `Aiur.Orchestrator.RetryEngine`, never for an operator label flip, so an
      operator-decision pause never enters the map; and
    * `resume_one/4` refuses a ticket that is currently `agent:paused` (an
      operator's explicit pause wins over a pending transient resume) or whose
      lifetime dispatch latch is exhausted (see `Dispatcher.dispatch_latch_status/2`).

  All functions execute inside the orchestrator GenServer process.
  """

  require Logger
  alias Aiur.{Alerts, Issue}
  alias Aiur.GitHub.Errors
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, State, TicketTransition, TrackerTasks}

  @backoff_ms [120_000, 300_000, 900_000]
  @max_attempts 3

  @type cause :: :transient_tracker | :rate_limit | :provider_timeout | :local_budget_hold

  @doc "Bounded backoff schedule for the given 1-based attempt."
  @spec backoff_ms(pos_integer()) :: pos_integer()
  def backoff_ms(attempt) when is_integer(attempt) and attempt > 0 do
    case Enum.at(@backoff_ms, attempt - 1) do
      ms when is_integer(ms) -> ms
      _ -> List.last(@backoff_ms)
    end
  end

  @doc "Maximum automatic resume attempts per ticket before parking for an operator."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc """
  Classifies a failure reason as a transient infrastructure fault worth an
  automatic re-dispatch. Returns `nil` for terminal/operator causes.

  Tracker errors follow `Aiur.GitHub.Errors`'s taxonomy (including the
  secondary-rate-limit 403 whose body names a rate limit and the
  auth-preflight transport shape the claim-release path surfaces — both go
  through `Aiur.GitHub.Errors.transient_github_error?/1`, the same shared
  classifier `Aiur.Orchestrator.HumanReview` uses to defer rather than
  terminate); provider timeouts are recognized as bare or wrapped `:timeout` /
  transport terms.

  A raw `Req.TransportError`/`Mint.TransportError` (the shape the transport
  error funnel surfaces) is normalised through the shared taxonomy before
  classifying, so "suppressed as transient" in `RetryEngine` and "scheduled
  for auto-resume" here are the same predicate by construction (#2427 review).
  """
  @spec classify(term()) :: cause() | nil
  def classify(reason) do
    reason = normalise_transport_error(reason)

    cond do
      local_budget_hold?(reason) -> :local_budget_hold
      tracker_rate_limited?(reason) -> :rate_limit
      tracker_transient?(reason) -> :transient_tracker
      provider_timeout?(reason) -> :provider_timeout
      true -> nil
    end
  end

  # A raw `%Req.TransportError{}`/`%Mint.TransportError{}` (as `transport.ex`'s
  # error funnel surfaces) is normalised through `Errors.classify_error/1`
  # before classifying, exactly as `RetryEngine.transient_exhaustion_reason?/1`
  # does, so a reason the shared classifier calls transient (DNS, timeout, TLS,
  # connection closed) always schedules a re-claim. Without this, a DNS failure
  # (`:nxdomain`) — transient to the shared classifier, absent from the
  # provider-timeout whitelist — released a claim with no re-claim scheduled:
  # strictly worse than the `agent:error` it used to get (#2427 review).
  defp normalise_transport_error(%{__struct__: struct} = reason)
       when struct in [Req.TransportError, Mint.TransportError] do
    Errors.classify_error({:error, reason})
  end

  defp normalise_transport_error(reason), do: reason

  defp tracker_rate_limited?({:github, :rate_limited, _detail}), do: true
  defp tracker_rate_limited?(_reason), do: false

  # A local GitHub budget hold is a transient infrastructure fault — the guard
  # is throttling a resource for a bounded window, not rejecting the work — so
  # a ticket parked in `agent:error` by one must auto-resume once the hold
  # lifts instead of waiting for an operator. Recognized in the raw
  # `{:aiur, :locally_held, hold}` form, the `:local_hold` classification
  # `Errors.classify_error` now assigns, the legacy transport-classified
  # `{:github, :transport, %{reason: ...}}` form (#2409, #2429), a workspace
  # preflight failure `{:workspace_github_connectivity_failed, workspace,
  # inner}` (the shape an agent exits with when its workspace preflight is
  # held, #2339), and the preflight diagnostic
  # `{:github_auth_preflight_failed, %{classification: :local_hold}}`.
  defp local_budget_hold?({:aiur, :locally_held, _hold}), do: true
  defp local_budget_hold?({:github, :local_hold, _detail}), do: true
  defp local_budget_hold?({:github, :transport, %{reason: {:aiur, :locally_held, _hold}}}), do: true

  defp local_budget_hold?({:workspace_github_connectivity_failed, _workspace, inner}),
    do: local_budget_hold?(inner)

  defp local_budget_hold?({:github_auth_preflight_failed, %{classification: :local_hold}}), do: true
  defp local_budget_hold?(_reason), do: false

  # The shared transient classifier (taxonomy + 408/429/5xx + the auth-preflight
  # transport diagnostic) so the claim-release path and retry exhaustion treat
  # a TransportError as a transient fault that schedules a re-claim rather than
  # parking the ticket with no recovery (#2361, #2420). A workspace connectivity
  # failure wraps the inner tracker/preflight reason, and a raw `:nxdomain`
  # DNS failure bypasses the classifier's structured tuple, so both are
  # unwrapped/recognized here so the taxonomy and the exhaustion-classification
  # boundary agree everywhere (#2429 / #2427).
  defp tracker_transient?(reason) do
    reason
    |> unwrap_workspace_connectivity()
    |> then(fn inner -> Errors.transient_github_error?(inner) or dns_failure?(inner) end)
  end

  # A workspace connectivity failure wraps the inner tracker/preflight reason;
  # unwrap it so the transient classification applies to what is actually
  # failing rather than the wrapper (#2429 / #2427).
  defp unwrap_workspace_connectivity({:workspace_github_connectivity_failed, _workspace, inner}),
    do: inner

  defp unwrap_workspace_connectivity(reason), do: reason

  # A DNS transport failure (`:nxdomain`) is a transient infrastructure fault,
  # but `Errors.retryable_github_error?/1` only recognizes the already-classified
  # `{:github, kind, _}` tuple. A raw `:nxdomain` — bare, `{:error, ...}`-wrapped,
  # or inside a `Req.TransportError`/`Mint.TransportError` — bypasses the
  # classifier and would otherwise park a retry-exhausted ticket in `agent:error`
  # instead of auto-resuming once DNS recovers (#2429 / #2427). `Errors` already
  # maps `:nxdomain` → `:dns`; this closes the gap at the exhaustion-classification
  # boundary so the classifier and the taxonomy agree everywhere.
  defp dns_failure?({:error, reason}), do: dns_failure?(reason)

  defp dns_failure?(%{__struct__: struct, reason: reason})
       when struct in [Req.TransportError, Mint.TransportError],
       do: dns_failure?(reason)

  defp dns_failure?(:nxdomain), do: true
  defp dns_failure?(_reason), do: false

  defp provider_timeout?(:timeout), do: true
  defp provider_timeout?({:error, :timeout}), do: true
  defp provider_timeout?({:timeout, _detail}), do: true

  # Bare transport terms from a provider (not a `Req.TransportError` struct —
  # those are normalised through the shared taxonomy in `classify/1` before
  # reaching here).
  defp provider_timeout?(reason)
       when reason in [:timeout, :closed, :econnrefused, :ehostunreach, :enetunreach, :econnreset],
       do: true

  defp provider_timeout?(_reason), do: false

  @doc """
  Records (or refreshes) a pending automatic resume for a ticket parked on a
  transient cause. Bounded to `max_attempts/0`; once the bound is reached the
  entry is dropped and an operator alert is emitted, leaving the ticket parked
  for human recovery.
  """
  @spec schedule(State.t(), String.t(), cause()) :: State.t()
  def schedule(%State{} = state, issue_id, cause) when is_binary(issue_id) and is_atom(cause) do
    schedule(state, issue_id, cause, &Alerts.emit_system/2)
  end

  @spec schedule(State.t(), String.t(), cause(), keyword()) :: State.t()
  def schedule(%State{} = state, issue_id, cause, opts) when is_binary(issue_id) and is_atom(cause) and is_list(opts) do
    schedule_with_options(state, issue_id, cause, Keyword.put_new(opts, :emit_fun, &Alerts.emit_system/2))
  end

  @doc false
  # Testable variant with an injected alert emitter; the production path routes
  # through `Alerts.emit_system/2`.
  @spec schedule(State.t(), String.t(), cause(), (String.t(), keyword() -> term())) :: State.t()
  def schedule(%State{} = state, issue_id, cause, emit_fun)
      when is_binary(issue_id) and is_atom(cause) and is_function(emit_fun, 2) do
    schedule_with_options(state, issue_id, cause, emit_fun: emit_fun)
  end

  defp schedule_with_options(%State{} = state, issue_id, cause, opts) do
    entries = state.auto_resume || %{}
    previous = Map.get(entries, issue_id) || %{}
    attempt = Map.get(previous, :attempt, 0) + 1

    if attempt > @max_attempts do
      Logger.warning("Transient auto-resume exhausted for issue_id=#{issue_id} attempts=#{@max_attempts} cause=#{cause}; parking for operator recovery")

      Keyword.fetch!(opts, :emit_fun).("ticket.#{issue_id}.agent.auto_resume_exhausted",
        message:
          "Transient auto-resume exhausted for issue #{issue_id} after #{@max_attempts} " <>
            "attempts (cause=#{cause}); the ticket is parked for operator recovery.",
        reason:
          "Automatic re-dispatch exhausted its bounded budget for issue #{issue_id} " <>
            "(cause=#{cause}). `aiurdev resume <id>` or an operator state flip is required.",
        needs_attention: true,
        severity: "warning"
      )

      %{state | auto_resume: Map.delete(entries, issue_id)}
    else
      scheduled_at_ms = System.monotonic_time(:millisecond)
      due_at_ms = max(scheduled_at_ms + backoff_ms(attempt), recovery_due_at_ms(opts, scheduled_at_ms))
      entry = %{attempt: attempt, cause: cause, scheduled_at_ms: scheduled_at_ms, due_at_ms: due_at_ms}
      %{state | auto_resume: Map.put(entries, issue_id, entry)}
    end
  end

  @doc "Milliseconds until the next automatic resume attempt for the ticket, or nil."
  @spec retry_in_ms(State.t(), String.t(), integer()) :: non_neg_integer() | nil
  def retry_in_ms(%State{} = state, issue_id, now_ms) when is_binary(issue_id) do
    case Map.get(state.auto_resume, issue_id) do
      %{attempt: attempt, scheduled_at_ms: scheduled_at} = entry ->
        retry_at = Map.get(entry, :due_at_ms, scheduled_at + backoff_ms(attempt))
        max(0, retry_at - now_ms)

      _ ->
        nil
    end
  end

  @doc "Entries whose backoff has elapsed, ordered by retry time."
  @spec due_entries(State.t(), integer()) :: [{String.t(), map()}]
  def due_entries(%State{} = state, now_ms) do
    state.auto_resume
    |> Enum.filter(fn {_issue_id, %{attempt: attempt, scheduled_at_ms: scheduled_at} = entry} ->
      Map.get(entry, :due_at_ms, scheduled_at + backoff_ms(attempt)) <= now_ms
    end)
    |> Enum.sort_by(fn {_issue_id, %{attempt: attempt, scheduled_at_ms: scheduled_at} = entry} ->
      Map.get(entry, :due_at_ms, scheduled_at + backoff_ms(attempt))
    end)
  end

  @doc """
  Reconciles due automatic resumes once per poll cycle, after the tracker
  poll has refreshed `last_polled_issues`. A due ticket is re-dispatched only
  when it is still alive (not terminal, not running, not claimed), not
  operator-paused, and not held by the lifetime dispatch latch. Dispatch is
  gated by the same admission path as normal dispatch (global pause, capacity,
  prewarm, host pressure); when a gate holds the entry is deferred without
  spending a bounded attempt, so a fleet that is briefly paused or busy never
  burns the ticket's auto-resume budget (#1453).
  """
  @spec maybe_resume(State.t(), integer(), keyword()) :: State.t()
  def maybe_resume(%State{} = state, now_ms, opts \\ []) do
    Enum.reduce(due_entries(state, now_ms), state, fn {issue_id, entry}, acc ->
      resume_one(acc, issue_id, entry, opts)
    end)
  end

  defp resume_one(%State{} = state, issue_id, entry, opts) do
    case Map.get(state.last_polled_issues, issue_id) do
      %Issue{} = issue ->
        cond do
          TrackerTasks.issue_pending?(state, issue_id) -> state
          resumable?(state, issue) -> do_resume(state, issue_id, issue, entry, opts)
          true -> drop_after_refusal(state, issue_id, issue)
        end

      nil ->
        # The ticket is no longer tracked (moved to a terminal state or left
        # the board). Drop the pending entry.
        %{state | auto_resume: Map.delete(state.auto_resume, issue_id)}
    end
  end

  defp resumable?(%State{} = state, %Issue{} = issue) do
    terminal_states = DispatchPolicy.terminal_state_set()

    not DispatchPolicy.terminal_issue_state?(issue.state, terminal_states) and
      not Map.has_key?(state.running, issue.id) and
      not MapSet.member?(state.claimed, issue.id) and
      not Issue.paused?(issue) and
      Dispatcher.dispatch_latch_status(state, issue.id) == :none
  end

  # An operator's explicit `agent:paused` label, a terminal state, or a
  # lifetime latch supersedes a pending transient resume. Drop the entry so the
  # poll does not keep re-firing against it.
  defp drop_after_refusal(%State{} = state, issue_id, %Issue{} = issue) do
    if Issue.paused?(issue) or match?({:lifetime, _, _}, Dispatcher.dispatch_latch_status(state, issue.id)) do
      Logger.info("Transient auto-resume superseded for #{State.issue_context(issue)}; dropping pending entry")
    end

    %{state | auto_resume: Map.delete(state.auto_resume, issue_id)}
  end

  defp do_resume(%State{} = state, issue_id, %Issue{} = issue, entry, opts) do
    if DispatchPolicy.active_issue_state?(issue.state, DispatchPolicy.active_state_set()) do
      dispatch_resume(state, issue_id, issue, entry, opts)
    else
      admission_fun = Keyword.get(opts, :admission_fun, &Dispatcher.auto_resume_admission/1)

      case admission_fun.(state) do
        {:hold, reason} -> defer_for_admission(state, issue_id, entry, reason)
        :dispatch -> restore_for_resume(state, issue_id, issue, entry, opts)
      end
    end
  end

  defp restore_for_resume(state, issue_id, issue, entry, opts) do
    update_fun = Keyword.get(opts, :update_state_fun, fn arg1, arg2 -> restore_resume_state(arg1, arg2, {issue}) end)

    TrackerTasks.run(state, {:auto_restore, issue_id}, fn -> write_resume_state({issue, update_fun}) end, fn arg1, arg2 ->
      apply_resume_restore(arg1, arg2, {entry, issue, issue_id, opts})
    end)
  end

  defp dispatch_resume(state, issue_id, issue, entry, opts) do
    admission_fun = Keyword.get(opts, :admission_fun, &Dispatcher.auto_resume_admission/1)

    case admission_fun.(state) do
      {:hold, reason} ->
        # A non-causal deferral: the fleet is globally paused, at capacity, in a
        # prewarm hold, or under host-pressure admission. Do NOT advance the
        # bounded attempt budget — the original transient cause may already be
        # clear, and burning a retry on an operator halt or a busy fleet would
        # park the ticket after a handful of irrelevant holds (#1453 review P1/P2a).
        defer_for_admission(state, issue_id, entry, reason)

      :dispatch ->
        dispatch_fun =
          Keyword.get(opts, :dispatch_fun, fn current, ticket ->
            dispatch_with_resume_completion(current, ticket, entry)
          end)

        state |> dispatch_fun.(issue) |> finish_dispatch(issue, entry)
    end
  end

  defp dispatch_with_resume_completion(state, issue, entry) do
    Dispatcher.dispatch_issue(state, issue, nil, nil, dispatch_result_fun: fn current -> finish_dispatch(current, issue, entry) end)
  end

  @doc false
  @spec finish_dispatch(State.t(), Issue.t(), map()) :: State.t()
  def finish_dispatch(state, issue, entry) do
    cond do
      Map.get(state.auto_resume, issue.id) != entry ->
        state

      state.globally_paused ->
        state

      TrackerTasks.issue_pending?(state, issue.id) ->
        state

      MapSet.member?(state.claimed, issue.id) or Map.has_key?(state.running, issue.id) ->
        Logger.info("Transient auto-resume dispatched #{State.issue_context(issue)}")
        %{state | auto_resume: Map.delete(state.auto_resume, issue.id), released_claims: Map.delete(state.released_claims, issue.id)}

      true ->
        Logger.info("Transient auto-resume deferred for #{State.issue_context(issue)} cause=#{entry.cause}")
        schedule(state, issue.id, entry.cause)
    end
  end

  # Keeps the entry with its current attempt count so a later poll re-checks
  # admission once the hold lifts. The entry is already due, so the next poll
  # re-runs `maybe_resume/3` against it without spending a bounded attempt.
  defp defer_for_admission(%State{} = state, issue_id, entry, reason) do
    Logger.info("Transient auto-resume admission deferred for issue_id=#{issue_id} reason=#{inspect(reason)}")

    %{state | auto_resume: Map.put(state.auto_resume, issue_id, entry)}
  end

  defp recovery_due_at_ms(opts, now_ms) do
    retry_after_ms = if is_integer(opts[:retry_after]) and opts[:retry_after] > 0, do: opts[:retry_after] * 1_000, else: 0

    reset_after_ms =
      with reset_at when is_binary(reset_at) <- opts[:reset_at],
           {:ok, reset_at, _offset} <- DateTime.from_iso8601(reset_at) do
        max(0, DateTime.diff(reset_at, DateTime.utc_now(), :millisecond))
      else
        _ -> 0
      end

    now_ms + max(retry_after_ms, reset_after_ms)
  end

  defp restore_resume_state(identifier, next_state, {issue}) do
    TicketTransition.write_state(identifier, next_state, writer: :auto_resume, expected_state: issue.state)
  end

  defp write_resume_state({issue, update_fun}) do
    update_fun.(issue.identifier, "todo")
  end

  defp apply_resume_restore(current, result, {entry, issue, issue_id, opts}) do
    if Map.get(current.auto_resume, issue_id) == entry and
         Map.get(current.last_polled_issues, issue_id) == issue and resumable?(current, issue) do
      case result do
        :ok ->
          refreshed = %{issue | state: "todo"}

          current = %{
            current
            | last_polled_issues: Map.put(current.last_polled_issues, issue.id, refreshed)
          }

          dispatch_resume(current, issue_id, refreshed, entry, opts)

        {:error, reason} ->
          Logger.warning("Transient auto-resume state restore failed for #{State.issue_context(issue)}: #{inspect(reason)}")

          schedule(current, issue_id, entry.cause)
      end
    else
      current
    end
  end
end
