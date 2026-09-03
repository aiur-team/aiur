defmodule Aiur.Orchestrator.CommentWake do
  @moduledoc """
  Trusted-comment reactivation routing: idle promotion to rework, running-entry
  reactivation, PR-merged terminalization, and comment-rework retry scheduling.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger
  import Bitwise, only: [<<<: 2]

  alias Aiur.Alerts
  alias Aiur.CurrentRunMembership
  alias Aiur.Events.UniversalSubscriptions
  alias Aiur.GitHub.{Config, LocalHold}
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, MembershipLifecycle, MergedTicketReconciler, PrAnchored, PushRouting, ReviewFreshness, ReworkGate, State}
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.Tracker
  alias Aiur.TrackerIdentity

  @comment_rework_retry_delay_ms 2_000
  @comment_rework_max_attempts 5

  @spec maybe_reactivate_on_comment(
          State.t(),
          String.t() | integer(),
          String.t() | atom(),
          map(),
          pos_integer()
        ) :: State.t()
  def maybe_reactivate_on_comment(%State{} = state, issue_number, source, event, attempt \\ 1) do
    case State.find_running_by_identifier(state.running, issue_number) do
      # An already-running entry (PR-anchored or legacy) resumes its SAME
      # session — a follow-up comment on a PR-anchored agent's PR resolves here
      # (identifier == to_string(pr#)) and never re-dispatches.
      running_entry when is_map(running_entry) ->
        reactivate_if_deactivated(state, running_entry, issue_number, source, event)

      _ ->
        PrAnchored.maybe_route_pr_anchored_or_legacy(state, issue_number, source, event, attempt)
    end
  end

  @spec mark_pr_merged_issue_done(State.t(), String.t() | integer(), keyword()) :: State.t()
  def mark_pr_merged_issue_done(%State{} = state, identifier, opts \\ []) when is_list(opts) do
    update_issue_state_fun =
      Keyword.get(opts, :update_issue_state_fun, &Tracker.update_issue_state/2)

    clear_session_handle_fun =
      Keyword.get(opts, :clear_session_handle_fun, &Orchestrator.clear_session_handle/1)

    observe_membership_fun =
      Keyword.get(opts, :observe_membership_fun, &MembershipLifecycle.observe/2)

    terminate_running_issue_fun =
      Keyword.get(opts, :terminate_running_issue_fun, &Orchestrator.terminate_running_issue/3)

    mark_reconciled_fun =
      Keyword.get(opts, :mark_reconciled_fun, &CurrentRunMembership.mark_reconciled/1)

    set_terminal_verification_pending_fun =
      Keyword.get(
        opts,
        :set_terminal_verification_pending_fun,
        &CurrentRunMembership.set_terminal_verification_pending/2
      )

    merger_allowed_fun =
      Keyword.get(opts, :merger_allowed_fun, &Config.human_merger_allowed?/1)

    emit_alert_fun =
      Keyword.get(opts, :emit_alert_fun, &emit_merge_alert/2)

    resume_blockees_fun =
      Keyword.get(opts, :resume_blockees_fun, &PushRouting.maybe_resume_blockees_on_merged_ticket/2)

    merged_by_login = Keyword.get(opts, :merged_by_login)

    Logger.info("PR merge received: issue_identifier=#{identifier} merged_by=#{inspect(merged_by_login)}")

    # The merged-PR terminal path is the fourth site of the hold-is-fatal
    # defect: a short self-clearing local budget hold on the open-PR lookup
    # that decides the post-merge target — or on the `done` write itself — used
    # to fire the merge-terminal-write alert and leave the ticket stranded on
    # its active-state label with its work complete (#2467). The shared helper
    # waits the hold out and retries, so the ticket closes; a hold beyond the
    # ceiling or past the cap still fails closed and the alert below still
    # fires.
    target_state =
      LocalHold.run(
        fn -> merged_issue_target_state(identifier, opts) end,
        LocalHold.caller_opts(opts)
      )

    terminal_state =
      case target_state do
        "done" ->
          result =
            LocalHold.run(
              fn -> update_issue_state_fun.(to_string(identifier), "done") end,
              LocalHold.caller_opts(opts)
            )

          case result do
            :ok ->
              state
              |> complete_merged_issue(
                identifier,
                clear_session_handle_fun,
                observe_membership_fun,
                terminate_running_issue_fun,
                mark_reconciled_fun,
                set_terminal_verification_pending_fun
              )
              |> resume_blockees_fun.(to_string(identifier))

            {:error, reason} ->
              Logger.warning("PR merge terminal transition skipped: issue_identifier=#{identifier} reason=#{inspect(reason)}")

              state
          end

        target when target in ["rework", "human-review"] ->
          # A merged PR does not close a ticket that still has other open PRs:
          # the ticket must stay active so the remaining PR's review findings
          # stay dispatchable. No terminal teardown runs — the ticket is not
          # done, so dependents stay blocked on it and no session handle is
          # cleared. The merged PR's own reconciliation is not marked here; the
          # poll-cycle reconciler consumes the merge and records it.
          case update_issue_state_fun.(to_string(identifier), target) do
            :ok ->
              Logger.info("PR merge left ticket open with remaining PRs: issue_identifier=#{identifier} target=#{target}")

              state

            {:error, reason} ->
              Logger.warning("PR merge remaining-open transition skipped: issue_identifier=#{identifier} target=#{target} reason=#{inspect(reason)}")

              state
          end

        {:error, reason} ->
          Logger.warning("PR merge target could not be determined; ticket left unchanged: issue_identifier=#{identifier} reason=#{inspect(reason)}")

          # A merged PR whose ticket could not be transitioned to `done` is a
          # stranded ticket; alert rather than only log so the Executor sees it
          # (#2420). Mirrors `MergedTicketReconciler.emit_failed_alert/5`.
          emit_merge_terminal_write_failed_alert(identifier, reason)

          state
      end

    audit_merge_attribution(
      identifier,
      merged_by_login,
      merger_allowed_fun,
      emit_alert_fun
    )

    terminal_state
  end

  # The state a merged-PR ticket should land in. Callers that already ran
  # `MergedTicketReconciler.merged_ticket_target/2` pass the decided
  # `:target_state` (the reconciler does, so its terminal path does not
  # re-enumerate the open-PR listing); everyone else — the live webhook route —
  # computes it here so no path can write `done` without checking the ticket's
  # other open PRs first.
  defp merged_issue_target_state(identifier, opts) do
    case Keyword.get(opts, :target_state) do
      target when target in ["done", "rework", "human-review"] ->
        target

      _other ->
        case MergedTicketReconciler.merged_ticket_target(identifier, opts) do
          {:ok, target} -> target
          {:error, _reason} = error -> error
        end
    end
  end

  defp emit_merge_alert(name, opts) do
    {message, alert_opts} = Keyword.pop!(opts, :message)
    Alerts.emit_custom(name, message, Keyword.put(alert_opts, :event_source, :system))
  end

  # A merged PR that names a ticket but fails to transition it to `done` leaves
  # the ticket stranded on an active-state label; surface it to the Executor
  # rather than only logging it (#2420).
  defp emit_merge_terminal_write_failed_alert(identifier, reason) do
    Alerts.emit_custom(
      "ticket.#{identifier}.agent.attention.merge_terminal_write_failed",
      "Merged PR could not transition ticket #{identifier} to done (#{inspect(reason)}); the ticket was not closed.",
      issue: identifier,
      reason: "The merge-to-done terminal write failed (#{inspect(reason)}) and the ticket keeps its active-state label; it is not stranded invisibly but needs attention.",
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end

  defp audit_merge_attribution(
         identifier,
         merged_by_login,
         merger_allowed_fun,
         emit_alert_fun
       ) do
    case safely_check_merger(merger_allowed_fun, merged_by_login) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        safely_emit_merge_alert(
          emit_alert_fun,
          "ticket.#{identifier}.merge.unauthorized_merger",
          message: "Unauthorized PR merger #{inspect(merged_by_login)} detected for ticket #{identifier}.",
          issue: to_string(identifier),
          reason: "PR merged by #{inspect(merged_by_login)} who is not in the human merger allowlist.",
          needs_attention: true,
          severity: "critical"
        )

      {:error, reason} ->
        Logger.error(
          "PR merge attribution check failed: issue_identifier=#{identifier} " <>
            "merged_by=#{inspect(merged_by_login)} reason=#{inspect(reason)}"
        )

        safely_emit_merge_alert(
          emit_alert_fun,
          "ticket.#{identifier}.merge.attribution_check_failed",
          message: "PR merge attribution check failed for ticket #{identifier}.",
          issue: to_string(identifier),
          reason: "PR merged by #{inspect(merged_by_login)}, but the human merger allowlist check failed: #{inspect(reason)}.",
          needs_attention: true,
          severity: "critical"
        )
    end
  end

  defp safely_check_merger(merger_allowed_fun, merged_by_login) do
    {:ok, merger_allowed_fun.(merged_by_login) == true}
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safely_emit_merge_alert(emit_alert_fun, name, opts) do
    emit_alert_fun.(name, opts)
  rescue
    error ->
      Logger.error("PR merge attribution alert failed: name=#{name} reason=#{Exception.message(error)}")
      :error
  catch
    kind, reason ->
      Logger.error("PR merge attribution alert failed: name=#{name} reason=#{inspect({kind, reason})}")
      :error
  end

  defp complete_merged_issue(
         state,
         identifier,
         clear_session_handle_fun,
         observe_membership_fun,
         terminate_running_issue_fun,
         mark_reconciled_fun,
         set_terminal_verification_pending_fun
       ) do
    case State.find_running_by_identifier(state.running, identifier) do
      %{issue: %Issue{} = issue} ->
        record_merged_issue_terminal(
          state,
          identifier,
          issue,
          clear_session_handle_fun,
          observe_membership_fun,
          terminate_running_issue_fun,
          mark_reconciled_fun,
          set_terminal_verification_pending_fun
        )

      _ ->
        state
    end
  end

  defp record_merged_issue_terminal(
         state,
         identifier,
         issue,
         clear_session_handle_fun,
         observe_membership_fun,
         terminate_running_issue_fun,
         mark_reconciled_fun,
         set_terminal_verification_pending_fun
       ) do
    case MembershipLifecycle.record(issue, :completed, observe_membership_fun) do
      :ok ->
        finalize_merged_issue_terminal(
          state,
          identifier,
          issue,
          clear_session_handle_fun,
          terminate_running_issue_fun,
          mark_reconciled_fun,
          set_terminal_verification_pending_fun
        )

      {:error, :membership_observation_failed} ->
        retain_merged_issue_for_terminal_verification(
          state,
          issue,
          mark_reconciled_fun,
          set_terminal_verification_pending_fun
        )
    end
  end

  defp finalize_merged_issue_terminal(
         state,
         identifier,
         issue,
         clear_session_handle_fun,
         terminate_running_issue_fun,
         mark_reconciled_fun,
         set_terminal_verification_pending_fun
       ) do
    case safely_set_terminal_verification_pending(
           set_terminal_verification_pending_fun,
           issue.tracker_identity,
           false
         ) do
      :ok ->
        clear_session_handle_fun.(identifier)
        terminate_running_issue_fun.(state, issue.id, true)

      :error ->
        retain_merged_issue_for_terminal_verification(
          state,
          issue,
          mark_reconciled_fun,
          set_terminal_verification_pending_fun
        )
    end
  end

  defp retain_merged_issue_for_terminal_verification(
         state,
         issue,
         mark_reconciled_fun,
         set_terminal_verification_pending_fun
       ) do
    safely_mark_membership_unavailable(
      mark_reconciled_fun,
      set_terminal_verification_pending_fun,
      issue.tracker_identity
    )

    state
  end

  defp safely_mark_membership_unavailable(
         mark_reconciled_fun,
         set_terminal_verification_pending_fun,
         identity
       ) do
    _ =
      safely_set_terminal_verification_pending(
        set_terminal_verification_pending_fun,
        identity,
        true
      )

    _ = mark_reconciled_fun.(:unavailable)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safely_set_terminal_verification_pending(
         set_terminal_verification_pending_fun,
         %TrackerIdentity{} = identity,
         pending?
       ) do
    if TrackerIdentity.joinable?(identity) do
      invoke_terminal_verification_marker(
        set_terminal_verification_pending_fun,
        identity,
        pending?
      )
    else
      :ok
    end
  end

  defp safely_set_terminal_verification_pending(
         _set_terminal_verification_pending_fun,
         _identity,
         _pending?
       ),
       do: :ok

  defp invoke_terminal_verification_marker(
         set_terminal_verification_pending_fun,
         identity,
         pending?
       ) do
    case set_terminal_verification_pending_fun.(identity, pending?) do
      :ok -> :ok
      _ -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  @doc false
  @spec trusted_comment_event?(map()) :: boolean()
  def trusted_comment_event?(event) when is_map(event) do
    Map.get(event, :author_trusted?) == true or Map.get(event, "author_trusted?") == true
  end

  @doc false
  @spec benign_review_pass_comment?(map()) :: boolean()
  def benign_review_pass_comment?(event) when is_map(event) do
    event
    |> comment_body()
    |> review_pass_comment?()
  end

  @doc false
  @spec maybe_transition_idle_issue_to_rework(
          State.t(),
          String.t() | integer(),
          String.t() | atom(),
          map(),
          pos_integer()
        ) :: State.t()
  def maybe_transition_idle_issue_to_rework(state, issue_number, source, event, attempt) do
    case idle_rework_decision(state, issue_number, event) do
      {:skip, reason} ->
        Logger.info("#{source} ignored for idle issue: issue_identifier=#{issue_number} reason=#{inspect(reason)}")

        state = cancel_comment_rework_retry(state, issue_number, source)

        # `not_yet_attempted` is a skip of the *label transition* only, never of
        # the comment. The ticket is dispatchable and will be picked up, so the
        # comment has to survive into the digest the agent reads on its first
        # turn. Dropping it here would trade a wrong label for lost operator
        # input, which is the worse failure of the two.
        if reason == :not_yet_attempted,
          do: seed_idle_comment_wake_event(state, issue_number, event),
          else: state

      {:error, reason} ->
        Logger.warning(
          "#{source} rework gate skipped; issue state could not be resolved: " <>
            "issue_identifier=#{issue_number} reason=#{inspect(reason)}"
        )

        schedule_comment_rework_retry(state, issue_number, source, event, attempt, reason)

      :active ->
        case transition_comment_issue_to_rework(state, issue_number, issue_number, source, event, nil) do
          {:ok, state} ->
            # The transition landed, so any retry still pending from an earlier
            # comment on this issue is now moot — cancel it rather than let it fire.
            state
            |> cancel_comment_rework_retry(issue_number, source)
            |> seed_idle_comment_wake_event(issue_number, event)

          {{:skip, reason}, state} ->
            Logger.info("#{source} ignored for idle issue: issue_identifier=#{issue_number} reason=#{inspect(reason)}")

            cancel_comment_rework_retry(state, issue_number, source)

          {{:error, reason}, state} ->
            Logger.warning("#{source} rework transition skipped; state update failed: issue_identifier=#{issue_number} reason=#{inspect(reason)}")

            schedule_comment_rework_retry(state, issue_number, source, event, attempt, reason)
        end
    end
  end

  # A trusted comment on an IDLE issue is only rework feedback if the ticket is
  # actually a tracked, worked ticket — one carrying an `agent:*` state label.
  # A ticket with NO `agent:*` label is how an operator parks work ("decide
  # before this is built"): there is no prior implementation for "rework" to
  # mean anything about, and auto-flipping it to `agent:rework` silently
  # overrides that intent (#1971). The explicit `agent:parked` marker is the
  # positive form of the same hold and is refused the same way. The poll path
  # never dispatches such tickets, so this gate is what keeps the comment path
  # from being the invisible auto-writer that reaches them.
  defp idle_rework_decision(state, issue_number, event) do
    case idle_rework_issue(state, issue_number, event) do
      {:ok, %Issue{} = issue} ->
        cond do
          Issue.parked?(issue) ->
            {:skip, :parked}

          DispatchPolicy.normalize_issue_state(issue.state) == "" ->
            {:skip, :unlabeled_issue}

          # Same argument as the unlabelled case, one state further along: a
          # `todo` ticket has not been worked either, so there is no prior
          # implementation for "rework" to mean anything about. Flipping it
          # discards the true state — nothing restores `todo` afterwards — and
          # makes an operator's own triage note indistinguishable from a
          # reviewer rejecting the work.
          #
          # Observed repeatedly: promoting a ticket to `agent:todo` and then
          # commenting to say why reliably un-promoted it on the next poll, so
          # promotion and commentary could not be done in the same breath.
          #
          # This skip still seeds the event digest below, unlike the two above:
          # the ticket is about to be dispatched, so the comment is briefing
          # material the agent must read on its first turn.
          DispatchPolicy.normalize_issue_state(issue.state) == "todo" ->
            {:skip, :not_yet_attempted}

          true ->
            :active
        end

      # The tracker has no record to read the labels off — a non-GitHub backend
      # that does not index by id, or an issue this repo does not own. Absence of
      # a record is NOT evidence of a parked ticket, so the gate must fail open
      # and leave the pre-#1971 behaviour (attempt the transition, let the
      # tracker write decide) exactly as it was.
      {:ok, :unresolved} ->
        :active

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Prefer the polled view already held in orchestrator state; fall back to an
  # authoritative tracker read (injectable via the event for tests) when this
  # issue was never polled — which is exactly the unlabelled/parked case.
  defp idle_rework_issue(%State{} = state, issue_number, event) do
    target = to_string(issue_number)

    case Enum.find(state.last_polled_issues, fn
           {_id, %Issue{id: id, identifier: identifier}} ->
             Issue.identifier_matches?(id, identifier, target)

           _ ->
             false
         end) do
      {_id, %Issue{} = issue} ->
        {:ok, issue}

      nil ->
        fetch_idle_rework_issue(issue_number, event)
    end
  end

  defp fetch_idle_rework_issue(issue_number, event) do
    fetcher =
      case Map.get(event, :issue_state_fetcher) do
        fun when is_function(fun, 1) -> fun
        _ -> &Tracker.fetch_issue_states_by_ids/1
      end

    case fetcher.([to_string(issue_number)]) do
      {:ok, [%Issue{} = issue | _]} -> {:ok, issue}
      {:ok, []} -> {:ok, :unresolved}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec comment_rework_retry_delay_ms(pos_integer()) :: pos_integer()
  def comment_rework_retry_delay_ms(attempt) when is_integer(attempt) do
    power = (attempt - 1) |> max(0) |> min(4)
    comment_rework_retry_base_delay_ms() * (1 <<< power)
  end

  @doc false
  @spec comment_rework_max_attempts() :: pos_integer()
  def comment_rework_max_attempts do
    case Application.get_env(:aiur, :comment_rework_max_attempts) do
      attempts when is_integer(attempts) and attempts > 0 -> attempts
      _ -> @comment_rework_max_attempts
    end
  end

  @doc false
  @spec event_digest_summary(map()) :: String.t()
  def event_digest_summary(event) when is_map(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic") || "(unknown)"
    message = Map.get(event, "message") || Map.get(event, :message) || Map.get(event, "summary")

    case message do
      m when is_binary(m) and m != "" -> "#{topic}: #{m}"
      _ -> topic
    end
  end

  defp reactivate_if_deactivated(state, running_entry, issue_number, source, event) do
    if State.deactivated_running_entry?(running_entry) do
      transition_and_revalidate_comment_reactivation(
        state,
        running_entry,
        issue_number,
        source,
        event
      )
    else
      protect_active_comment_delivery(state, running_entry, issue_number, source, event)
    end
  end

  defp protect_active_comment_delivery(state, running_entry, issue_number, source, event) do
    cond do
      not trusted_comment_event?(event) ->
        state

      benign_review_pass_comment?(event) ->
        state

      true ->
        identifier = to_string(issue_number)

        protected_state =
          Orchestrator.enqueue_event_digest_item(state, identifier, [event], event)

        issue_key = rework_issue_key(running_entry, issue_number)

        case transition_comment_issue_to_rework(
               protected_state,
               issue_key,
               issue_number,
               source,
               event,
               Map.get(running_entry, :telemetry_attempt_id)
             ) do
          {:ok, state} ->
            state

          {{:error, reason}, _state} ->
            Logger.warning(
              "#{source} active rework transition deferred behind delivery fence: " <>
                "issue_identifier=#{issue_number} reason=#{inspect(reason)}"
            )

            protected_state

          {{:skip, _reason}, _state} ->
            protected_state
        end
    end
  end

  defp schedule_comment_rework_retry(
         %State{} = state,
         issue_number,
         source,
         event,
         attempt,
         reason
       ) do
    max_attempts = comment_rework_max_attempts()
    key = comment_rework_retry_key(issue_number, source)

    # Any previously scheduled attempt for this issue+source is superseded by the
    # decision we are making now; cancel it so at most one timer per key is live.
    state = cancel_comment_rework_retry(state, key)

    cond do
      not retryable_comment_rework_failure?(reason) ->
        Logger.warning("#{source} rework transition failed permanently: issue_identifier=#{issue_number} attempts=#{attempt} reason=#{inspect(reason)}")

        state

      attempt >= max_attempts ->
        Logger.warning("#{source} rework transition retry exhausted: issue_identifier=#{issue_number} attempts=#{attempt} reason=#{inspect(reason)}")

        state

      true ->
        next_attempt = attempt + 1
        delay_ms = comment_rework_retry_delay_ms(attempt)

        timer_ref =
          Process.send_after(
            self(),
            {:retry_comment_rework, issue_number, source, event, next_attempt},
            delay_ms
          )

        Logger.info("#{source} rework transition retry scheduled: issue_identifier=#{issue_number} attempt=#{next_attempt}/#{max_attempts} delay_ms=#{delay_ms}")

        put_comment_rework_retry(state, key, {timer_ref, issue_number, source})
    end
  end

  @doc """
  Re-deliver a comment wake later because a transient, non-tracker condition
  blocked it.

  The PR-anchored path (`Aiur.Orchestrator.PrAnchored`) builds a synthetic work
  unit that carries no `agent:*` label and is not in the tracker, so the poll
  loop can never rediscover it. When the host-pressure admission gate holds that
  dispatch, dropping it would strand the work until a new human comment arrived.
  This re-arms the same bounded, escalating `{:retry_comment_rework, ...}` chain
  the tracker-failure path uses, so the held unit is re-offered to the gate on
  its own.

  Returns `{state, :scheduled | :exhausted}` so the caller can escalate when the
  chain runs out and the work really is being dropped.
  """
  @spec schedule_comment_wake_retry(
          State.t(),
          String.t() | integer(),
          String.t() | atom(),
          map(),
          pos_integer(),
          String.t()
        ) :: {State.t(), :scheduled | :exhausted}
  def schedule_comment_wake_retry(%State{} = state, issue_number, source, event, attempt, reason_label)
      when is_integer(attempt) and is_binary(reason_label) do
    max_attempts = comment_rework_max_attempts()
    key = comment_rework_retry_key(issue_number, source)

    # At most one live timer per issue+source: the decision being made now
    # supersedes any earlier scheduled attempt.
    state = cancel_comment_rework_retry(state, key)

    if attempt >= max_attempts do
      {state, :exhausted}
    else
      next_attempt = attempt + 1
      delay_ms = comment_rework_retry_delay_ms(attempt)

      timer_ref =
        Process.send_after(
          self(),
          {:retry_comment_rework, issue_number, source, event, next_attempt},
          delay_ms
        )

      Logger.info(
        "#{source} comment wake retry scheduled: issue_identifier=#{issue_number} " <>
          "attempt=#{next_attempt}/#{max_attempts} delay_ms=#{delay_ms} reason=#{reason_label}"
      )

      {put_comment_rework_retry(state, key, {timer_ref, issue_number, source}), :scheduled}
    end
  end

  @doc """
  Is a failed rework transition worth retrying?

  The retry chain runs up to `comment_rework_max_attempts/0` attempts with
  escalating delays — a full minute of work at the default settings. That only
  makes sense for failures a later attempt could plausibly clear: 5xx responses,
  timeouts, DNS/TLS/transport faults, and rate limiting.

  Auth and permission failures cannot: a missing or rejected token stays missing
  or rejected for all five attempts, so retrying only burns a minute producing
  warnings. Client errors (4xx other than 408/429) are the same — the request
  itself is wrong, and repeating it verbatim will not fix it.
  """
  @spec retryable_comment_rework_failure?(term()) :: boolean()
  def retryable_comment_rework_failure?(:missing_github_token), do: false
  def retryable_comment_rework_failure?({:github, classification, _detail}) when classification in [:auth, :permission], do: false
  def retryable_comment_rework_failure?({:github, :http, %{status: status}}), do: retryable_status?(status)
  def retryable_comment_rework_failure?({:github_api_status, status}) when is_integer(status), do: retryable_status?(status)
  def retryable_comment_rework_failure?(_reason), do: true

  # 408 Request Timeout and 429 Too Many Requests are the two 4xx codes that a
  # later identical request can legitimately succeed at.
  defp retryable_status?(status) when status in [408, 429], do: true
  defp retryable_status?(status) when is_integer(status) and status in 400..499, do: false
  defp retryable_status?(_status), do: true

  @doc false
  @spec comment_rework_retry_key(String.t() | integer(), String.t() | atom()) ::
          {String.t(), String.t()}
  def comment_rework_retry_key(issue_number, source),
    do: {to_string(issue_number), to_string(source)}

  @doc """
  Forget the retry timer for `issue_number`/`source` because its message just fired.

  The timer has already been delivered at this point, so there is nothing to
  cancel — dropping the ref keeps the tracking map from growing without bound.
  """
  @spec forget_comment_rework_retry(State.t(), String.t() | integer(), String.t() | atom()) ::
          State.t()
  def forget_comment_rework_retry(%State{} = state, issue_number, source) do
    key = comment_rework_retry_key(issue_number, source)
    %{state | comment_rework_retries: Map.delete(comment_rework_retries(state), key)}
  end

  @doc """
  Cancel every outstanding comment-rework retry timer.

  Retry chains run up to `comment_rework_max_attempts/0` attempts with escalating
  delays, so an untracked timer can fire — and log — tens of seconds after the
  work that scheduled it is gone. `terminate/2` calls this so a stopping
  orchestrator never leaves a retry firing into an unrelated context.
  """
  @spec cancel_comment_rework_retries(State.t()) :: State.t()
  def cancel_comment_rework_retries(%State{} = state) do
    state
    |> comment_rework_retries()
    |> Map.keys()
    |> Enum.reduce(state, &cancel_comment_rework_retry(&2, &1))
  end

  defp cancel_comment_rework_retry(%State{} = state, issue_number, source),
    do: cancel_comment_rework_retry(state, comment_rework_retry_key(issue_number, source))

  defp cancel_comment_rework_retry(%State{} = state, key) do
    case Map.pop(comment_rework_retries(state), key) do
      {nil, _retries} ->
        state

      {{timer_ref, issue_number, source}, retries} ->
        # `false` means the timer already fired, so its message is in the mailbox
        # and cancelling alone would not stop the retry from running.
        if Process.cancel_timer(timer_ref, async: false, info: true) == false do
          flush_comment_rework_retry(issue_number, source)
        end

        %{state | comment_rework_retries: retries}
    end
  end

  # Selective receive on the exact scheduled message: pinned issue/source means
  # unrelated mailbox entries keep their position rather than being re-sent.
  defp flush_comment_rework_retry(issue_number, source) do
    receive do
      {:retry_comment_rework, ^issue_number, ^source, _event, _attempt} -> :ok
    after
      0 -> :ok
    end
  end

  defp put_comment_rework_retry(%State{} = state, key, entry),
    do: %{state | comment_rework_retries: Map.put(comment_rework_retries(state), key, entry)}

  defp comment_rework_retries(%State{comment_rework_retries: retries}) when is_map(retries),
    do: retries

  defp comment_rework_retries(_state), do: %{}

  defp seed_idle_comment_wake_event(%State{} = state, issue_number, event) do
    identifier = to_string(issue_number)

    UniversalSubscriptions.attach(identifier)

    state
    |> Orchestrator.enqueue_event_digest_item(identifier, [event], event)
    |> dispatch_reworked_comment_issue(identifier)
  end

  defp dispatch_reworked_comment_issue(%State{} = state, identifier) when is_binary(identifier) do
    case fetch_comment_dispatch_issue(identifier) do
      {:ok, %Issue{} = issue} ->
        dispatch_reworked_comment_issue(state, issue)

      {:skip, reason} ->
        Logger.info("Trusted comment dispatch deferred: issue_identifier=#{identifier} reason=#{inspect(reason)}")

        Orchestrator.schedule_poll_cycle_start()
        state

      {:error, reason} ->
        Logger.warning("Trusted comment dispatch deferred: issue_identifier=#{identifier} reason=#{inspect(reason)}")

        Orchestrator.schedule_poll_cycle_start()
        state
    end
  end

  defp dispatch_reworked_comment_issue(%State{} = state, %Issue{} = issue) do
    active = DispatchPolicy.active_state_set()
    terminal = DispatchPolicy.terminal_state_set()

    if DispatchPolicy.should_dispatch_issue?(issue, state, active, terminal) do
      Dispatcher.maybe_choose_under_load(state, [issue], fn admitted, [admitted_issue] ->
        admitted
        |> Dispatcher.dispatch_issue(admitted_issue)
        |> maybe_record_comment_rework_resume(admitted_issue)
      end)
    else
      Orchestrator.schedule_poll_cycle_start()
      state
    end
  end

  # The successful state transition above captures the comment's rework intent,
  # but dispatch admission must continue to use the subsequently fetched state.
  # When that read is stale-but-active, record the intent only after a worker is
  # actually admitted; Dispatcher records the normal fetched-`rework` case.
  defp maybe_record_comment_rework_resume(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{pid: pid, issue: %Issue{} = dispatched_issue} = entry when is_pid(pid) ->
        if DispatchPolicy.normalize_issue_state(dispatched_issue.state) != "rework" do
          Lifecycle.record(
            issue.identifier,
            Map.get(entry, :telemetry_attempt_id),
            :agent_resume,
            :point,
            %{cause: :rework_dispatch}
          )
        end

      _other ->
        :ok
    end

    state
  end

  defp fetch_comment_dispatch_issue(identifier) do
    case Tracker.fetch_issue_states_by_ids([identifier]) do
      {:ok, [%Issue{} = issue | _]} ->
        {:ok, issue}

      {:ok, []} ->
        fetch_comment_dispatch_issue_from_candidates(identifier)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_comment_dispatch_issue_from_candidates(identifier) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        case find_issue_by_identifier_or_id(issues, identifier) do
          %Issue{} = issue -> {:ok, issue}
          nil -> {:skip, :missing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_issue_by_identifier_or_id(issues, identifier) when is_list(issues) do
    Enum.find(issues, fn
      %Issue{id: id, identifier: issue_identifier} ->
        id == identifier or issue_identifier == identifier

      _ ->
        false
    end)
  end

  defp transition_and_revalidate_comment_reactivation(
         state,
         running_entry,
         issue_number,
         source,
         event
       ) do
    issue_key = rework_issue_key(running_entry, issue_number)

    case transition_comment_issue_to_rework(
           state,
           issue_key,
           issue_number,
           source,
           event,
           Map.get(running_entry, :telemetry_attempt_id)
         ) do
      {:ok, state} ->
        revalidate_comment_reactivation(state, running_entry, issue_number, source)

      {{:skip, reason}, state} ->
        context = comment_reactivation_context(running_entry, issue_number)
        Logger.info("#{source} ignored for inactive issue: #{context} reason=#{inspect(reason)}")
        state

      {{:error, reason}, state} ->
        context = comment_reactivation_context(running_entry, issue_number)

        Logger.warning("#{source} reactivation skipped; state update failed: #{context} reason=#{inspect(reason)}")

        state
    end
  end

  defp transition_comment_issue_to_rework(state, issue_key, telemetry_ticket, source, event, attempt_id) do
    cond do
      not trusted_comment_event?(event) ->
        {{:skip, :untrusted_author}, state}

      benign_review_pass_comment?(event) ->
        {{:skip, :benign_review_pass_comment}, state}

      # An APPROVED pull request, or a review that predates the current head, is
      # not a request for rework — routing on it deadlocks the ticket (#1756).
      reason = ReviewFreshness.rework_skip_reason(event) ->
        {{:skip, reason}, state}

      true ->
        # #2422: `rework` is only justified while a reviewer is actually asking
        # for a change. GitHub's `reviewDecision` is sticky — it never clears
        # when findings are addressed — so it cannot distinguish "outstanding
        # findings" from "was once told to change something". Unresolved review
        # threads can, and routing on them is what lets a finished rework
        # escape `agent:rework` instead of looping. The check rides on the same
        # open-PR lookup `ReworkGate` already owns, so a ticket with no open PR
        # is still refused at the source (#2075); a transient thread read
        # surfaces as `{:error, _}` for the existing retry chain.
        case ReworkGate.verify_unresolved_review_threads(issue_key, rework_threads_opts(event)) do
          {:ok, pr} ->
            write_bounded_comment_rework(
              state,
              issue_key,
              telemetry_ticket,
              source,
              event,
              attempt_id,
              ReworkGate.head_sha(pr)
            )

          {:skip, reason} ->
            {{:skip, reason}, state}

          {:error, reason} ->
            {{:error, reason}, state}
        end
    end
  end

  # A rework-attempt bound for the comment path: the same head SHA must not
  # re-enter `agent:rework` indefinitely (#2422). When a head has already been
  # routed to rework `State.rework_attempt_limit/0` times without moving, the
  # next routing is a stuck condition — raise attention once and stop instead
  # of looping. `head_sha` is nil when the PR context cannot be read; the bound
  # then fails open (the rework write proceeds, exactly as before #2422).
  defp write_bounded_comment_rework(
         %State{} = state,
         issue_key,
         telemetry_ticket,
         source,
         event,
         attempt_id,
         head_sha
       ) do
    identifier = to_string(issue_key)
    opts = rework_attempt_alert_opts(event)

    case ReworkGate.verify_rework_attempt(state, identifier, head_sha, opts) do
      {:ok, state} ->
        case write_comment_rework(issue_key, telemetry_ticket, source, event, attempt_id) do
          :ok -> {:ok, State.bump_rework_attempt(state, identifier, head_sha)}
          {:error, _reason} = error -> {error, state}
        end

      {:skip, reason, state} ->
        {{:skip, reason}, state}
    end
  end

  # The open-PR lookup and the unresolved-thread read are injectable via the
  # event for tests; otherwise they route through `ReworkGate`'s defaults (the
  # tracker's open-PR fetch and review-thread fetch, which fail open where no
  # PR notion exists).
  defp rework_threads_opts(event) do
    event
    |> rework_open_pr_opts()
    |> maybe_put_threads_fetcher(event)
    |> Keyword.put(:changes_requested_review?, changes_requested_review?(event))
  end

  # A `CHANGES_REQUESTED` review submitted with a body and no inline comments
  # opens no review thread, so #2422's unresolved-thread read reports nothing
  # and the ticket never leaves `agent:human-review` (#2473). The review
  # submission *is* the outstanding finding, so it is handed to the gate as an
  # equivalent signal. What stops that from re-entering #2422's rework loop is
  # that a review submission is delivered once — `Aiur.Events.Publisher` drops
  # a redelivery on the durable `{:pr_review, …}` resource identity before it
  # ever reaches the gate — NOT `ReviewFreshness`, whose staleness half is
  # inert on webhook deliveries. `ReworkGate`'s `no_thread_verdict/1` carries
  # the full argument; read it there before changing this.
  #
  # Both publishers put the review under `comment` with an upper-cased `state`
  # — `GithubCommentsPoller.publish_pr_review_submission/5` reads REST
  # `/reviews`, which reports upper case, and the webhook pipe's
  # `Normalizer.review_submission_triple/3` applies `upcase_review_state/1` to
  # a delivery's lower-cased state — so one derivation covers the delivery path
  # and its polling backstop. The fold below is what makes that agreement a
  # property of this function rather than of its two producers.
  #
  # Event payloads reach the orchestrator with atom keys from an in-process
  # publish and string keys after a JSON round trip through the event store,
  # so both shapes are read, exactly as `comment_body/1` does.
  #
  # No non-map clause: the caller is what guarantees the map. `rework_threads_opts/1`
  # pipes the event through `rework_open_pr_opts/1` first, which reads it with
  # `Map.get/2`, so a non-map event raises there before reaching this function —
  # the same reason the two sibling helpers below carry no such clause either.
  defp changes_requested_review?(event) do
    case comment_review_state(event) do
      state when is_binary(state) -> String.upcase(state) == "CHANGES_REQUESTED"
      _other -> false
    end
  end

  defp comment_review_state(event) do
    comment = Map.get(event, :comment) || Map.get(event, "comment") || %{}

    if is_map(comment) do
      Map.get(comment, :state) || Map.get(comment, "state")
    end
  end

  defp rework_open_pr_opts(event) do
    case Map.get(event, :open_pr_fetcher) do
      fun when is_function(fun, 1) -> [open_pr_fetcher: fun]
      _ -> []
    end
  end

  defp maybe_put_threads_fetcher(opts, event) do
    case Map.get(event, :unresolved_threads_fetcher) do
      fun when is_function(fun, 1) -> Keyword.put(opts, :unresolved_threads_fetcher, fun)
      _ -> opts
    end
  end

  # The rework-attempt attention's emitter is injectable for tests; production
  # routes through `Aiur.Alerts.emit_system/2`.
  defp rework_attempt_alert_opts(event) do
    case Map.get(event, :emit_alert_fun) do
      fun when is_function(fun, 2) -> [emit_alert_fun: fun]
      _ -> []
    end
  end

  defp write_comment_rework(issue_key, telemetry_ticket, source, _event, attempt_id) do
    case Tracker.update_issue_state(to_string(issue_key), "rework") do
      :ok ->
        Lifecycle.record(
          to_string(telemetry_ticket),
          attempt_id,
          :rework_start,
          :point,
          %{source: source, outcome: :success}
        )

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp comment_body(event) do
    comment = Map.get(event, :comment) || Map.get(event, "comment") || %{}

    if is_map(comment) do
      Map.get(comment, :body) || Map.get(comment, "body")
    end
  end

  defp review_pass_comment?(body) when is_binary(body) do
    body
    |> String.trim()
    |> String.downcase()
    |> String.match?(~r/^\[codex\]\s+review\s+passed\b/)
  end

  defp review_pass_comment?(_body), do: false

  defp comment_rework_retry_base_delay_ms do
    case Application.get_env(:aiur, :comment_rework_retry_delay_ms) do
      delay when is_integer(delay) and delay >= 0 -> delay
      _ -> @comment_rework_retry_delay_ms
    end
  end

  defp rework_issue_key(%{issue: %Issue{id: issue_id}}, _issue_number) when is_binary(issue_id),
    do: issue_id

  defp rework_issue_key(_running_entry, issue_number), do: issue_number

  defp revalidate_comment_reactivation(state, running_entry, issue_number, source) do
    context = comment_reactivation_context(running_entry, issue_number)

    case fetch_current_reactivation_issue(running_entry) do
      {:ok, %Issue{} = refreshed_issue} ->
        reactivate_current_issue(state, running_entry, refreshed_issue, issue_number, source)

      {:skip, reason} ->
        Logger.info("#{source} ignored for inactive issue: #{context} reason=#{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.warning("#{source} reactivation skipped; issue refresh failed: #{context} reason=#{inspect(reason)}")

        state
    end
  end

  defp fetch_current_reactivation_issue(%{issue: %Issue{id: issue_id} = issue})
       when is_binary(issue_id) do
    case Dispatcher.revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           DispatchPolicy.terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} -> {:ok, refreshed_issue}
      {:skip, %Issue{} = refreshed_issue} -> {:skip, refreshed_issue.state}
      {:skip, :missing} -> {:skip, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_current_reactivation_issue(_running_entry), do: {:skip, :missing_issue_id}

  defp reactivate_current_issue(state, running_entry, refreshed_issue, issue_number, source) do
    issue_id = refreshed_issue.id
    refreshed_entry = Map.put(running_entry, :issue, refreshed_issue)
    state = %{state | running: Map.put(state.running, issue_id, refreshed_entry)}

    Logger.info("#{source} reactivating: issue_id=#{issue_id} issue_identifier=#{issue_number}")

    case Orchestrator.reactivate_issue(state, refreshed_entry) do
      {{:ok, :reactivated}, next_state} ->
        next_state

      {{:error, reason}, next_state} ->
        emit_comment_reactivation_deferred_alert(refreshed_entry, source, reason)
        next_state
    end
  end

  defp emit_comment_reactivation_deferred_alert(running_entry, source, reason) do
    identifier = Map.get(running_entry, :identifier)
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])

    Logger.warning("#{source} reactivation deferred: issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{inspect(reason)}")

    Alerts.emit_system("ticket.#{identifier}.agent.review_feedback_delivery_deferred",
      issue: identifier,
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      reason: "Trusted review feedback moved the ticket to rework, but the agent could not resume: #{inspect(reason)}.",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp comment_reactivation_context(running_entry, issue_number) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    "issue_id=#{issue_id} issue_identifier=#{issue_number}"
  end
end
