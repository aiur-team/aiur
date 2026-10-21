defmodule Aiur.Orchestrator.CommentWake.Reactivation do
  @moduledoc "Running comment delivery and reactivation after state refresh."

  require Logger

  alias Aiur.Alerts
  alias Aiur.Issue
  alias Aiur.Orchestrator.CommentWake
  alias Aiur.Orchestrator.CommentWake.ReworkRetries
  alias Aiur.Orchestrator.CommentWake.ReworkTransition
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.Tracker

  @doc false
  @spec reactivate_if_deactivated(State.t(), map(), String.t() | integer(), String.t() | atom(), map(), pos_integer()) :: State.t()
  def reactivate_if_deactivated(state, running_entry, issue_number, source, event, attempt) do
    if State.deactivated_running_entry?(running_entry) do
      transition_and_revalidate_comment_reactivation(
        state,
        running_entry,
        issue_number,
        source,
        event,
        attempt
      )
    else
      protect_active_comment_delivery(state, running_entry, issue_number, source, event, attempt)
    end
  end

  # The third running-entry shape, and the one the other two branches do not
  # cover: an entry that is present but not `:deactivated`. A worker that has
  # just finished its turn leaves `control.status: :completed` here, and a ticket
  # that has bounced `human-review` → `ci-wait` → `human-review` keeps its entry
  # across the round trip — so a reviewer's `--request-changes` landing in either
  # window routes through this function rather than the idle writer or the
  # `:deactivated` reactivation path (#2814).
  defp protect_active_comment_delivery(state, running_entry, issue_number, source, event, attempt) do
    cond do
      not CommentWake.trusted_comment_event?(event) ->
        state

      CommentWake.benign_review_pass_comment?(event) ->
        state

      # A live rework worker gets the review; a finished one may have handed off since the last poll (#4601).
      live_rework_worker?(running_entry) ->
        OperatorMessages.enqueue_event_digest_item(state, to_string(issue_number), [event], event)

      true ->
        identifier = to_string(issue_number)

        protected_state =
          OperatorMessages.enqueue_event_digest_item(state, identifier, [event], event)

        issue_key = rework_issue_key(running_entry, issue_number)

        ReworkTransition.with_comment_transition(
          protected_state,
          issue_key,
          issue_number,
          source,
          event,
          Map.get(running_entry, :telemetry_attempt_id),
          attempt,
          &apply_active_comment_protection(&1, {attempt, event, issue_number, source})
        )
    end
  end

  defp live_rework_worker?(%{issue: %Issue{state: issue_state}, control: %{status: :working}}), do: DispatchPolicy.normalize_issue_state(issue_state) == "rework"
  defp live_rework_worker?(_running_entry), do: false

  # A gate refusal on the running-entry path used to be the quietest outcome in
  # the whole comment-wake chain: no label write, no retry, no log line, no
  # alert. What the operator saw was a ticket that simply stayed in
  # `agent:human-review` after a formal `--request-changes` review, with nothing
  # anywhere naming a decision.
  #
  # Refusals that are *correct* readings of a comment that is not a change
  # request stay as quiet as they were: an untrusted author, a bot review-pass
  # comment, an approved pull request, a review that predates the head, a plain
  # conversation comment on a ticket whose threads are clear. What must never be
  # quiet is a live `CHANGES_REQUESTED` review that produced no rework write — by
  # construction a reviewer asked for a change and the ticket did not move, the
  # review will never be delivered again, and an operator is the only thing that
  # can release it.
  defp refuse_active_comment_rework(%State{} = state, issue_number, source, event, reason) do
    context = "issue_identifier=#{issue_number} reason=#{inspect(reason)}"

    if ReworkTransition.changes_requested_review?(event) do
      Logger.warning("#{source} refused rework for a changes-requested review: #{context}")

      emit_refused_review_rework_alert(issue_number, event, reason)
    else
      Logger.info("#{source} active comment rework skipped: #{context}")
    end

    state
  end

  defp emit_refused_review_rework_alert(issue_number, event, reason) do
    emit_alert_fun =
      case Map.get(event, :emit_alert_fun) do
        fun when is_function(fun, 2) -> fun
        _ -> &Alerts.emit_system/2
      end

    identifier = to_string(issue_number)

    emit_alert_fun.(
      "ticket.#{identifier}.agent.attention.review_rework_refused",
      issue: identifier,
      message:
        "Ticket #{identifier} received a CHANGES_REQUESTED review but was not moved to rework " <>
          "(#{inspect(reason)}); it is still sitting in its review state.",
      reason:
        "The rework gate refused the transition for a live changes-requested review, and a review " <>
          "submission is delivered only once, so nothing re-derives it. Remedy: move the ticket to " <>
          "rework or re-review it after addressing the gate condition.",
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end

  @doc false
  @spec transition_and_revalidate_comment_reactivation(term(), term(), term(), term(), term(), term()) :: term()
  def transition_and_revalidate_comment_reactivation(
        state,
        running_entry,
        issue_number,
        source,
        event,
        attempt
      ) do
    issue_key = rework_issue_key(running_entry, issue_number)

    ReworkTransition.with_comment_transition(
      state,
      issue_key,
      issue_number,
      source,
      event,
      Map.get(running_entry, :telemetry_attempt_id),
      attempt,
      fn arg1 ->
        apply_comment_reactivation(
          arg1,
          {event, issue_number, running_entry, source}
        )
      end
    )
  end

  defp rework_issue_key(%{issue: %Issue{id: issue_id}}, _issue_number) when is_binary(issue_id),
    do: issue_id

  defp rework_issue_key(_running_entry, issue_number), do: issue_number

  # The only gate refusal that means "the label is already right", rather than
  # "this comment is not reviewer feedback". Everything else — an untrusted
  # author, a benign review-pass comment, an approved or stale review, a ticket
  # with no open PR — must keep dropping the comment exactly as before.
  defp wake_without_rework_write?(:no_unresolved_review_threads), do: true
  defp wake_without_rework_write?(_reason), do: false

  defp revalidate_comment_reactivation(state, running_entry, issue_number, source, opts \\ []) do
    TrackerTasks.run(state, {:comment_revalidate, issue_number, make_ref()}, fn -> fetch_current_reactivation_issue(running_entry) end, fn current, result ->
      if TrackerTasks.same_runner?(State.find_running_by_identifier(current.running, issue_number), running_entry) do
        apply_comment_reactivation(current, State.find_running_by_identifier(current.running, issue_number), issue_number, source, opts, result)
      else
        current
      end
    end)
  end

  defp apply_comment_reactivation(state, running_entry, issue_number, source, opts, result) do
    context = comment_reactivation_context(running_entry, issue_number)

    case result do
      {:ok, %Issue{} = refreshed_issue} ->
        reactivate_when_state_matches(state, running_entry, refreshed_issue, issue_number, source, opts)

      {:skip, reason} ->
        Alerts.emit_custom(
          "ticket.#{issue_number}.agent.attention.comment_wake_inactive_issue_reactivation",
          "Reactivation for inactive issue #{issue_number} was ignored (#{inspect(reason)})",
          issue: to_string(issue_number),
          reason: "Inactive issues cannot be reactivated by comments (#{inspect(reason)}). Remedy: change the issue to an active state, then retry the comment delivery.",
          needs_attention: false,
          severity: "info",
          event_source: :system
        )

        Logger.info("#{source} ignored for inactive issue: #{context} reason=#{inspect(reason)}")

        state

      {:error, reason} ->
        Alerts.emit_custom(
          "ticket.#{issue_number}.agent.attention.comment_wake_reactivation_refresh_failed",
          "Reactivation for issue #{issue_number} failed - could not refresh state (#{inspect(reason)})",
          issue: to_string(issue_number),
          reason: "Could not fetch the current issue state during reactivation (#{inspect(reason)}). Remedy: check tracker access and retry reactivation.",
          needs_attention: false,
          severity: "info",
          event_source: :system
        )

        Logger.warning("#{source} reactivation skipped; issue refresh failed: #{context} reason=#{inspect(reason)}")

        state
    end
  end

  defp apply_comment_reactivation(
         outcome,
         {event, issue_number, running_entry, source}
       ) do
    case outcome do
      {:ok, state} ->
        revalidate_comment_reactivation(state, running_entry, issue_number, source)

      {{:skip, reason}, state} ->
        # A skipped *label write* is not automatically a skipped *wake*. The
        # ticket is already `agent:rework` and its threads are all resolved, so
        # the gate is right to refuse a transition — but the agent's provider
        # has completed and its `:deactivated` entry blocks re-dispatch
        # (`DispatchPolicy`'s `:already_running`), so nothing else brings it
        # back and an Executor had to send `aiurdev message` by hand (#2601).
        #
        # Scope, precisely — this branch is NOT the #2601 review path. A
        # body-only blocking review submission carries
        # `blocking_review_submission?: true` into the gate, which answers
        # `{:ok, :rework}` via #2473's `no_thread_verdict/1` and takes the
        # ordinary write-then-reactivate branch above. What lands here is every
        # *other* trusted comment on a rework ticket whose threads are clear:
        # a PR conversation comment. Waking
        # on those is the intent (#2601's third acceptance criterion), so N
        # distinct trusted comments produce N wakes by design — an operator
        # asking for something twice should be heard twice. What stops that
        # from being thrash is the digest enqueue below: the comment travels
        # with the wake, so the agent knows what it was woken for instead of
        # respawning into an unchanged state and immediately exiting.
        #
        # No `rework` write happens here, so #2422's loop stays closed.
        if wake_without_rework_write?(reason) do
          context = comment_reactivation_context(running_entry, issue_number)
          Logger.info("#{source} waking without rework write: #{context} reason=#{inspect(reason)}")

          state
          |> OperatorMessages.enqueue_event_digest_item(to_string(issue_number), [event], event)
          |> revalidate_comment_reactivation(running_entry, issue_number, source, require_state: "rework")
        else
          Alerts.emit_custom(
            "ticket.#{issue_number}.agent.attention.comment_wake_inactive_issue",
            "Comment on inactive issue #{issue_number} was ignored (#{inspect(reason)})",
            issue: to_string(issue_number),
            reason:
              "Inactive issues are not dispatch candidates and do not accept comment-based reactivation (#{inspect(reason)}). Remedy: change the issue to an active state, then retry the comment delivery.",
            needs_attention: false,
            severity: "info",
            event_source: :system
          )

          context = comment_reactivation_context(running_entry, issue_number)
          Logger.info("#{source} ignored for inactive issue: #{context} reason=#{inspect(reason)}")

          state
        end

      {{:error, reason}, state} ->
        context = comment_reactivation_context(running_entry, issue_number)

        Alerts.emit_custom(
          "ticket.#{issue_number}.agent.attention.comment_wake_reactivation_state_failed",
          "Reactivation for issue #{issue_number} failed (#{inspect(reason)})",
          issue: to_string(issue_number),
          reason: "Could not update issue state during reactivation (#{inspect(reason)}). Remedy: check tracker permissions and retry reactivation.",
          needs_attention: false,
          severity: "info",
          event_source: :system
        )

        Logger.warning("#{source} reactivation skipped; state update failed: #{context} reason=#{inspect(reason)}")

        state
    end
  end

  defp fetch_current_reactivation_issue(%{issue: %Issue{id: issue_id} = issue} = running_entry)
       when is_binary(issue_id) do
    fetcher = Map.get(running_entry, :comment_reactivation_issue_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    case Dispatcher.revalidate_issue_for_dispatch(
           issue,
           fetcher,
           DispatchPolicy.terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} -> {:ok, refreshed_issue}
      {:skip, %Issue{} = refreshed_issue} -> {:skip, refreshed_issue.state}
      {:skip, :missing} -> {:skip, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_current_reactivation_issue(_running_entry), do: {:skip, :missing_issue_id}

  # The wake-without-write path asserts the ticket really is in the state that
  # made the label write unnecessary, read from the freshly-fetched issue
  # rather than the running entry's cached copy. Without the assertion a
  # `human-review` ticket whose threads are all resolved would be reactivated
  # by any trusted comment, which is the pre-#2422 behaviour this must not
  # restore.
  defp reactivate_when_state_matches(state, running_entry, refreshed_issue, issue_number, source, opts) do
    case Keyword.get(opts, :require_state) do
      nil ->
        CommentWake.reactivate_current_issue(state, running_entry, refreshed_issue, issue_number, source)

      required ->
        if DispatchPolicy.normalize_issue_state(refreshed_issue.state) == required do
          CommentWake.reactivate_current_issue(state, running_entry, refreshed_issue, issue_number, source, wrote_rework?: false)
        else
          Logger.info(
            "#{source} wake without rework write skipped; issue is not #{required}: " <>
              "#{comment_reactivation_context(running_entry, issue_number)} state=#{inspect(refreshed_issue.state)}"
          )

          state
        end
    end
  end

  @doc false
  @spec emit_comment_reactivation_deferred_alert(map(), String.t() | atom(), term(), keyword()) :: term()
  def emit_comment_reactivation_deferred_alert(running_entry, source, reason, opts) do
    identifier = Map.get(running_entry, :identifier)
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])

    Logger.warning("#{source} reactivation deferred: issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{inspect(reason)}")

    Alerts.emit_system("ticket.#{identifier}.agent.review_feedback_delivery_deferred",
      issue: identifier,
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      reason: deferred_alert_reason(reason, Keyword.get(opts, :wrote_rework?, true)),
      needs_attention: true,
      severity: "warning"
    )
  end

  # The wake-without-write path writes no label, so an operator told the ticket
  # "moved to rework" would go looking for a transition that never happened.
  defp deferred_alert_reason(reason, true),
    do: "Trusted review feedback moved the ticket to rework, but the agent could not resume: #{inspect(reason)}."

  defp deferred_alert_reason(reason, false),
    do:
      "Trusted feedback arrived on a ticket already in rework, but its completed agent could not be woken: #{inspect(reason)}. " <>
        "The ticket keeps its current label; the feedback is queued for the agent's next turn."

  defp comment_reactivation_context(running_entry, issue_number) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    "issue_id=#{issue_id} issue_identifier=#{issue_number}"
  end

  defp apply_active_comment_protection(outcome, {attempt, event, issue_number, source}) do
    case outcome do
      {:ok, state} ->
        state

      {{:error, reason}, state} ->
        Logger.warning(
          "#{source} active rework transition deferred behind delivery fence: " <>
            "issue_identifier=#{issue_number} reason=#{inspect(reason)}"
        )

        # A review submission is delivered ONCE. The `Aiur.Events` publish boundary
        # marks `{:pr_review, owner, repo, review_id}` handled for 72h at
        # `resource_version = submitted_at`, and the poller's
        # `pr_review_seen_at` watermark advances past that `submitted_at` in
        # the very cycle that read `/reviews` — so nothing re-derives this
        # review later. Returning `protected_state` here did not defer the
        # transition, it abandoned it: one transient refusal (a held, 5xx or
        # 429 open-PR search, review-thread read, or label write) left the
        # ticket on `agent:human-review` for good and an operator had to
        # relabel it by hand.
        #
        # The idle writer has always retried exactly this failure class
        # (`IdleRework.maybe_transition_idle_issue_to_rework/5`), and `Aiur.Orchestrator`'s
        # `{:retry_comment_rework, ...}` handler routes the retry back through
        # `CommentWake.maybe_reactivate_on_comment/5`, so the running-entry writer
        # re-enters this branch with the entry still in place. The attempt
        # bound and `ReworkRetries.retryable_comment_rework_failure?/1` are shared, so an
        # auth or non-retryable 4xx refusal still fails once and stays failed.

        ReworkRetries.schedule_comment_rework_retry(state, issue_number, source, event, attempt, reason)

      {{:skip, reason}, state} ->
        refuse_active_comment_rework(state, issue_number, source, event, reason)
    end
  end
end
