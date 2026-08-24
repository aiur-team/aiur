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

  alias Aiur.{Alerts, Issue, Tracker}
  alias Aiur.GitHub.Errors
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, State}

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
  secondary-rate-limit 403 whose body names a rate limit); provider timeouts
  are recognized as bare or wrapped `:timeout` / transport terms.
  """
  @spec classify(term()) :: cause() | nil
  def classify(reason) do
    cond do
      local_budget_hold?(reason) -> :local_budget_hold
      tracker_rate_limited?(reason) -> :rate_limit
      tracker_transient?(reason) -> :transient_tracker
      provider_timeout?(reason) -> :provider_timeout
      true -> nil
    end
  end

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

  defp tracker_transient?(reason) do
    reason
    |> unwrap_workspace_connectivity()
    |> then(fn inner -> Errors.retryable_github_error?(inner) or dns_failure?(inner) end)
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

  defp provider_timeout?(%{__struct__: struct, reason: reason})
       when struct in [Req.TransportError, Mint.TransportError] do
    reason in [:timeout, :closed, :econnrefused, :ehostunreach, :enetunreach, :econnreset]
  end

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
        if resumable?(state, issue) do
          do_resume(state, issue_id, issue, entry, opts)
        else
          drop_after_refusal(state, issue_id, issue)
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
    active_states = DispatchPolicy.active_state_set()

    state =
      if DispatchPolicy.active_issue_state?(issue.state, active_states) do
        state
      else
        restore_state(state, issue, opts)
      end

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
        dispatch_fun = Keyword.get(opts, :dispatch_fun, &Dispatcher.dispatch_issue/2)
        next_state = dispatch_fun.(state, issue)

        if MapSet.member?(next_state.claimed, issue.id) or Map.has_key?(next_state.running, issue.id) do
          Logger.info("Transient auto-resume dispatched #{State.issue_context(issue)}")
          %{next_state | auto_resume: Map.delete(next_state.auto_resume, issue.id), released_claims: Map.delete(next_state.released_claims, issue.id)}
        else
          # Admission passed but the dispatch itself refused (thrash window,
          # backend usage limit, worker-capacity race, spawn failure) — a real
          # re-dispatch attempt, so advance the bounded backoff.
          Logger.info("Transient auto-resume deferred for #{State.issue_context(issue)} cause=#{entry.cause}")
          schedule(next_state, issue_id, entry.cause)
        end
    end
  end

  # Keeps the entry with its current attempt count so a later poll re-checks
  # admission once the hold lifts. The entry is already due, so the next poll
  # re-runs `maybe_resume/3` against it without spending a bounded attempt.
  defp defer_for_admission(%State{} = state, issue_id, entry, reason) do
    Logger.info("Transient auto-resume admission deferred for issue_id=#{issue_id} reason=#{inspect(reason)}")

    %{state | auto_resume: Map.put(state.auto_resume, issue_id, entry)}
  end

  # An `agent:error` ticket (from retry exhaustion on a transient cause) must
  # be restored to a dispatchable state before it can be re-dispatched.
  #
  # The restore writes `todo`, never `rework`: nothing here rejected the work.
  # `rework` means "work exists and was rejected" (a reviewer's verdict); a
  # transient infra fault only needs "make this dispatchable again", which is
  # exactly what `todo` says. Writing `rework` also let a no-PR ticket be
  # stamped with a review verdict it never received, stranding the ticket in a
  # state nothing would select (#2075).
  defp restore_state(state, %Issue{} = issue, opts) do
    update_fun = Keyword.get(opts, :update_state_fun, &Tracker.update_issue_state/2)

    case update_fun.(issue.identifier, "todo") do
      :ok ->
        refreshed = %{issue | state: "todo"}
        %{state | last_polled_issues: Map.put(state.last_polled_issues, issue.id, refreshed)}

      {:error, reason} ->
        Logger.warning("Transient auto-resume state restore failed for #{State.issue_context(issue)}: #{inspect(reason)}")
        state
    end
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
end
