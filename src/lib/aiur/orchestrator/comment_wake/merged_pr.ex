defmodule Aiur.Orchestrator.CommentWake.MergedPr do
  @moduledoc "Merged PR target writes and terminal membership completion."

  require Logger

  alias Aiur.Alerts
  alias Aiur.CurrentRunMembership
  alias Aiur.GitHub.Config
  alias Aiur.GitHub.Issues, as: GitHubIssues
  alias Aiur.GitHub.LocalHold
  alias Aiur.Issue
  alias Aiur.Orchestrator.CommentWake.MergeAudit
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.MembershipLifecycle
  alias Aiur.Orchestrator.MergeAttribution
  alias Aiur.Orchestrator.MergedTicketReconciler
  alias Aiur.Orchestrator.MergeStateWriter
  alias Aiur.Orchestrator.MergeTransition
  alias Aiur.Orchestrator.OptimisticLedger
  alias Aiur.Orchestrator.PushRouting
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.Orchestrator.WorkspaceCleanup
  alias Aiur.RecentMerge

  @non_closing_merge_state "needs-triage"
  @max_closing_refreshes 10

  @spec mark_pr_merged_issue_done(State.t(), String.t() | integer(), keyword()) :: State.t()
  def mark_pr_merged_issue_done(%State{} = state, identifier, opts \\ []) when is_list(opts) do
    # Another instance owns the ticket and closes it itself (#5803).
    if Aiur.Instance.skip?(identifier, nil, :merge_transition), do: state, else: mark_done(state, identifier, opts)
  end

  defp mark_done(state, identifier, opts) do
    if merged_pr_closes_ticket?(identifier, opts), do: OptimisticLedger.close(to_string(identifier), :merged, System.system_time(:millisecond))

    update_issue_state_fun = Keyword.get(opts, :update_issue_state_fun, &MergeStateWriter.write_if_current(&1, &2, Keyword.take(opts, [:tracker, :fetch_issue_states_fun])))

    clear_session_handle_fun =
      Keyword.get(opts, :clear_session_handle_fun, &WorkspaceCleanup.clear_session_handle/1)

    observe_membership_fun =
      Keyword.get(opts, :observe_membership_fun, &MembershipLifecycle.observe/2)

    terminate_running_issue_fun =
      Keyword.get(opts, :terminate_running_issue_fun, &TicketTransition.apply_effect(&1, {:terminate, &2, &3}))

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

    entry = State.find_running_by_identifier(state.running, identifier)

    TrackerTasks.run(
      state,
      {:merged_comment, identifier},
      fn ->
        write_merged_issue_target({emit_alert_fun, identifier, merged_by_login, merger_allowed_fun, opts, update_issue_state_fun})
      end,
      fn arg1, arg2 ->
        apply_merged_issue_target(
          arg1,
          arg2,
          {clear_session_handle_fun, entry, identifier, mark_reconciled_fun, observe_membership_fun, resume_blockees_fun, set_terminal_verification_pending_fun, terminate_running_issue_fun}
        )
      end
    )
  end

  # A PR can close more tickets than the one its branch names. GitHub closes
  # each of them, but only the branch ticket gets a store write from this path,
  # so a dependent of any other one would wait for the next open-issue poll to
  # see the close (#2714). Re-read up to `@max_closing_refreshes` of them so
  # their `:issue` records say closed. The reads are conditional (free when the
  # record is current) and run off the Orchestrator process: an epic PR closing
  # forty tickets must not stall polls and dispatch behind forty serial reads.
  # References past the cap are left to the open-issue poll, which releases
  # their dependents on the next tick for one `blocked_by` read each.
  defp refresh_other_closed_issues(identifier, opts) do
    case Keyword.get(opts, :pr_body) do
      body when is_binary(body) and body != "" ->
        refresh_fun = Keyword.get(opts, :refresh_issue_fun, &refresh_issue_record/1)

        body
        |> RecentMerge.closing_issue_identifiers_in_body(merge_repository(opts))
        |> Enum.uniq()
        |> Enum.reject(&(&1 == to_string(identifier)))
        |> Enum.take(@max_closing_refreshes)
        |> start_closing_refreshes(refresh_fun)

      _no_body ->
        :ok
    end
  end

  defp start_closing_refreshes([], _refresh_fun), do: :ok

  defp start_closing_refreshes(identifiers, refresh_fun) do
    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> Enum.each(identifiers, refresh_fun) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.info("PR merge closing-issue refresh not started: #{inspect(reason)}")
    end

    :ok
  catch
    # No task supervisor: skip. The open-issue poll still carries the close.
    :exit, reason ->
      Logger.info("PR merge closing-issue refresh not started: #{inspect(reason)}")
      :ok
  end

  defp refresh_issue_record(identifier) do
    if Dispatcher.github_tracker_kind?() do
      case GitHubIssues.fetch_issue_raw_conditional(identifier, revalidate: true) do
        {:ok, _body, _freshness} ->
          :ok

        {:error, reason} ->
          Logger.info("PR merge could not refresh closed issue ##{identifier}: #{inspect(reason)}")
      end
    end

    :ok
  end

  # Reuse the reconciler's target when available; the webhook computes one only
  # after checking the closing keyword and remaining open PRs.
  @spec merged_issue_target_state(String.t() | integer(), keyword()) :: String.t() | {:error, term()}
  def merged_issue_target_state(identifier, opts) do
    case Keyword.get(opts, :target_state) do
      target when target in ["done", "rework", "ci-wait", "human-review"] ->
        target

      _other ->
        computed_merged_issue_target_state(identifier, opts)
    end
  end

  defp computed_merged_issue_target_state(identifier, opts) do
    if merged_pr_closes_ticket?(identifier, opts) do
      case MergedTicketReconciler.merged_ticket_target(identifier, opts) do
        {:ok, target} -> target
        {:error, _reason} = error -> error
      end
    else
      if identifier in RecentMerge.referenced_issue_identifiers_in_body(Keyword.get(opts, :pr_body), merge_repository(opts)), do: @non_closing_merge_state, else: "human-review"
    end
  end

  # The live merged route resolves its ticket from the `aiur/<id>-<slug>` head
  # branch, which says only that the PR belongs to the ticket — not that it
  # completes it. A PR body deliberately written `Refs #176 (merge does not
  # close the ticket)` is GitHub's documented way to say "related, not
  # resolving", and closing the ticket anyway retires an operator's still-open
  # acceptance checklist out from under them (#2609). So the branch identifies
  # the ticket and the body decides the outcome, exactly as
  # `MergedTicketReconciler` — the poll-cycle backstop — has always done.
  #
  # Absent evidence is not closing evidence: an empty body, a body the delivery
  # dropped, or a repository lookup that failed all leave the ticket open. That
  # direction is self-correcting — the reconciler reads the merge record's own
  # body on the next poll and closes a genuinely-closing ticket then — while
  # the opposite direction is the unrecoverable close this guard exists to
  # prevent.
  defp merged_pr_closes_ticket?(identifier, opts) do
    identifier = to_string(identifier)
    body = Keyword.get(opts, :pr_body)
    closes? = identifier in RecentMerge.closing_issue_identifiers_in_body(body, merge_repository(opts))

    unless closes? do
      Logger.info(
        "PR merge carries no closing keyword for its ticket; leaving it open: " <>
          "issue_identifier=#{identifier} target=#{@non_closing_merge_state}"
      )
    end

    closes?
  end

  defp merge_repository(opts) do
    repo_fun = Keyword.get(opts, :repo_fun, &Config.repo/0)

    repo_fun.()
  rescue
    error ->
      # A repository lookup is not worth failing a merge route over: without it
      # only `owner/repo#N` references are dropped, and a bare `#N` — what every
      # Aiur PR description carries — still closes normally.
      Logger.warning("PR merge repository lookup failed; qualified closing references ignored: #{inspect(error)}")

      nil
  end

  defp emit_merge_alert(name, opts) do
    {message, alert_opts} = Keyword.pop!(opts, :message)
    Alerts.emit_custom(name, message, Keyword.put(alert_opts, :event_source, :system))
  end

  defp emit_merge_terminal_write_failed_alert(identifier, reason) do
    reason = MergeTransition.reason_name(reason)

    Alerts.emit_custom(
      "ticket.#{identifier}.agent.attention.merge_terminal_write_failed",
      "Merged PR could not transition ticket #{identifier} to done (#{reason}).",
      issue: identifier,
      reason: "The merge transition failed (#{reason}); check the ticket's current state and labels.",
      needs_attention: true,
      severity: "warning",
      central: true
    )
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
    case CurrentRunMembership.set_terminal_verification_pending(
           set_terminal_verification_pending_fun,
           issue.tracker_identity,
           false
         ) do
      result when result in [:ok, :skipped] ->
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
      CurrentRunMembership.set_terminal_verification_pending(
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

  defp write_merged_issue_target({emit_alert_fun, identifier, merged_by_login, merger_allowed_fun, opts, update_issue_state_fun}) do
    target =
      LocalHold.run(
        fn -> merged_issue_target_state(identifier, opts) end,
        LocalHold.caller_opts(opts)
      )

    {target, result} =
      if target == @non_closing_merge_state do
        {target, :ok}
      else
        target
        |> then(&MergeTransition.write_terminal_target(&1, identifier, update_issue_state_fun, opts))
        |> then(&MergeTransition.normalize({target, &1}))
      end

    result = if target == "done", do: Alerts.StaleNotClosed.resolve_on_ok(result, identifier), else: result

    MergeAudit.audit_merge_attribution(identifier, MergeAttribution.resolve(merged_by_login, opts), merger_allowed_fun, emit_alert_fun)
    refresh_other_closed_issues(identifier, opts)
    {target, result}
  end

  defp apply_merged_issue_target(
         current,
         outcome,
         {clear_session_handle_fun, entry, identifier, mark_reconciled_fun, observe_membership_fun, resume_blockees_fun, set_terminal_verification_pending_fun, terminate_running_issue_fun}
       ) do
    case MergeTransition.normalize(outcome) do
      {"done", :ok} ->
        if TrackerTasks.same_runner?(
             State.find_running_by_identifier(current.running, identifier),
             entry
           ) do
          current
          |> complete_merged_issue(
            identifier,
            clear_session_handle_fun,
            observe_membership_fun,
            terminate_running_issue_fun,
            mark_reconciled_fun,
            set_terminal_verification_pending_fun
          )
          |> resume_blockees_fun.(to_string(identifier))
        else
          current
        end

      {target, :ok} when target in ["rework", "ci-wait", "human-review", "needs-triage"] ->
        current

      {"done", :skipped} ->
        current

      {_, {:error, reason}} ->
        Logger.warning("PR merge transition deferred: issue_identifier=#{identifier} reason=#{MergeTransition.reason_name(reason)}")

        emit_merge_terminal_write_failed_alert(identifier, reason)
        current

      {:error, reason} ->
        emit_merge_terminal_write_failed_alert(identifier, reason)
        current
    end
  end
end
