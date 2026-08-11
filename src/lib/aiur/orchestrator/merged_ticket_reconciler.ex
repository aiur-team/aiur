defmodule Aiur.Orchestrator.MergedTicketReconciler do
  @moduledoc """
  Closes tickets that a merged pull request named with a closing keyword.

  GitHub only auto-closes referenced issues when a pull request merges into the
  repository's default branch. Work here merges into `develop`, so `Closes #N`
  never fires on its own and this reconciler is the ordinary way a merged
  ticket reaches `done` — not a repair for a GitHub failure. Alerts are worded
  and rated accordingly.

  Two guards keep a retained merge record from re-closing a ticket that is
  legitimately open again. A merge reconciles a given ticket at most once per
  run, and a merge older than `@stale_merge_after_seconds` is ignored
  altogether: `RecentMergeStore` keeps the last hundred merges with no recency
  bound of its own, so without this a ticket reopened for rework would be
  force-closed on the next poll.
  """

  alias Aiur.{Alerts, Issue, RecentMerge, RecentMergeStore, Tracker}
  alias Aiur.Orchestrator.{CommentWake, PushRouting, State}

  # A merge older than this no longer explains why a ticket is open now: the
  # ticket has had a full day to be reopened deliberately.
  @stale_merge_after_seconds 24 * 60 * 60

  @spec reconcile(State.t(), [Issue.t()], keyword()) :: {State.t(), [Issue.t()]}
  def reconcile(state, issues, opts \\ [])

  def reconcile(%State{} = state, issues, opts) when is_list(issues) do
    recent_merges_fun = Keyword.get(opts, :recent_merges_fun, &RecentMergeStore.list/0)
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
    now = now_fun.()
    merges = recent_merges_fun.()

    Enum.reduce(issues, {state, []}, fn issue, {state_acc, retained} ->
      case merged_pull_request_for(state_acc, issue, merges, now) do
        nil ->
          {state_acc, [issue | retained]}

        merge ->
          reconcile_merged_ticket(state_acc, issue, merge, opts, retained)
      end
    end)
    |> then(fn {state, retained} -> {state, Enum.reverse(retained)} end)
  end

  def reconcile(%State{} = state, _issues, _opts), do: {state, []}

  defp reconcile_merged_ticket(state, %Issue{} = issue, merge, opts, retained) do
    update_issue_state_fun =
      Keyword.get(opts, :update_issue_state_fun, fn identifier, state_name, expected_state ->
        Tracker.update_issue_state(identifier, state_name, expected_state: expected_state)
      end)

    case update_issue_state_fun.(issue.identifier, "done", issue.state) do
      :ok ->
        blocked_before = PushRouting.merged_ticket_blockee_count(state, issue.identifier)

        state =
          CommentWake.mark_pr_merged_issue_done(
            state,
            issue.identifier,
            merged_ticket_opts(merge, opts)
          )

        blocked_after = PushRouting.merged_ticket_blockee_count(state, issue.identifier)

        state = record_reconciled(state, issue, merge)
        emit_reconciled_alert(issue, merge, blocked_before - blocked_after, blocked_before, opts)
        {state, retained}

      {:error, reason} ->
        state = emit_failed_alert(state, issue, merge, reason, opts)
        {state, [issue | retained]}
    end
  end

  defp reconcile_merged_ticket(state, issue, _merge, _opts, retained), do: {state, [issue | retained]}

  # The ticket was already transitioned above, so the terminalisation pass only
  # has to tear the agent down and resume dependents.
  #
  # `merged_by` is the sole input to the merger-attribution audit, so it is
  # passed through: with it stubbed out the audit could never fire. A record
  # backfilled from the Events API often carries no merger at all, and an
  # unattributed merge is not evidence of an unauthorised one, so in that case
  # the audit is skipped rather than allowed to assert a merger who is not
  # in the record.
  defp merged_ticket_opts(%RecentMerge{merged_by: merged_by}, opts) do
    base = [
      update_issue_state_fun: fn _identifier, "done" -> :ok end,
      resume_blockees_fun: Keyword.get(opts, :resume_blockees_fun, &PushRouting.maybe_resume_blockees_on_merged_ticket/2)
    ]

    base = Keyword.merge(base, Keyword.take(opts, [:merger_allowed_fun]))

    if attributed_merger?(merged_by) do
      Keyword.put(base, :merged_by_login, merged_by)
    else
      Keyword.put_new(base, :merger_allowed_fun, fn _login -> true end)
    end
  end

  defp attributed_merger?(merged_by), do: is_binary(merged_by) and String.trim(merged_by) != ""

  defp merged_pull_request_for(%State{} = state, %Issue{identifier: identifier} = issue, merges, now)
       when is_binary(identifier) and is_list(merges) do
    Enum.find(merges, fn
      %RecentMerge{} = merge ->
        identifier in RecentMerge.closing_issue_identifiers(merge) and
          not stale_merge?(merge, now) and
          not already_reconciled?(state, issue, merge)

      _ ->
        false
    end)
  end

  defp merged_pull_request_for(_state, _issue, _merges, _now), do: nil

  defp stale_merge?(%RecentMerge{merged_at: %DateTime{} = merged_at}, %DateTime{} = now) do
    DateTime.diff(now, merged_at, :second) > @stale_merge_after_seconds
  end

  defp stale_merge?(_merge, _now), do: true

  defp already_reconciled?(%State{} = state, %Issue{} = issue, %RecentMerge{} = merge) do
    MapSet.member?(state.merged_ticket_reconciliations, reconciliation_key(issue, merge))
  end

  defp record_reconciled(%State{} = state, %Issue{} = issue, %RecentMerge{} = merge) do
    %{
      state
      | merged_ticket_reconciliations: MapSet.put(state.merged_ticket_reconciliations, reconciliation_key(issue, merge))
    }
  end

  defp reconciliation_key(%Issue{identifier: identifier}, %RecentMerge{id: id}), do: {identifier, id}

  # Every reconciliation is announced, including the common case of a ticket
  # with no dependents: this force-transitions a live ticket to `done`, and a
  # state change that consequential must never be invisible.
  defp emit_reconciled_alert(issue, merge, resumed, blocked_before, opts) do
    emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

    emit_alert_fun.(
      "ticket.#{issue.identifier}.dependency.merged_blocker_reconciled",
      issue: issue,
      message: "Merged PR ##{merge.number} closed ticket #{issue.identifier}; marked it done#{resumed_phrase(resumed, blocked_before)}.",
      reason:
        "Pull requests here merge into develop rather than the default branch, so GitHub does not auto-close the tickets they reference. " <>
          "Ticket #{issue.identifier} is named by merged PR ##{merge.number}, so it was transitioned to done by compare-and-set" <>
          "#{resumed_reason(resumed, blocked_before)}.",
      needs_attention: false,
      severity: "info"
    )
  end

  defp resumed_phrase(_resumed, 0), do: " (no dependent agents were waiting on it)"
  defp resumed_phrase(resumed, blocked_before), do: " and resumed #{resumed} of #{blocked_before} dependent agent(s)"

  defp resumed_reason(_resumed, 0), do: "; no dependent agents were waiting on it"

  defp resumed_reason(resumed, blocked_before),
    do: "; #{resumed} of #{blocked_before} dependent agent(s) resumed"

  # The transition retries on every poll while it keeps failing, so the alert
  # is raised once per distinct failure and repeated only when the reason
  # changes. Silence at zero dependents would hide a permanently stuck ticket.
  defp emit_failed_alert(state, issue, merge, reason, opts) do
    blockee_count = PushRouting.merged_ticket_blockee_count(state, issue.identifier)
    signature = {reconciliation_key(issue, merge), inspect(reason)}

    if MapSet.member?(state.merged_ticket_reconciliation_failures, signature) do
      state
    else
      emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

      emit_alert_fun.(
        "ticket.#{issue.identifier}.agent.attention.merged_pr_reconciliation_failed",
        issue: issue,
        message: "Merged PR ##{merge.number} could not close ticket #{issue.identifier}#{blocked_phrase(blockee_count)}.",
        reason:
          "Merged PR ##{merge.number} names this active ticket, but the transition to done failed (#{inspect(reason)}) and will keep being retried" <>
            "#{blocked_reason(blockee_count)}.",
        needs_attention: true,
        severity: "warning",
        central: true
      )

      %{
        state
        | merged_ticket_reconciliation_failures: MapSet.put(state.merged_ticket_reconciliation_failures, signature)
      }
    end
  end

  defp blocked_phrase(0), do: ""
  defp blocked_phrase(count), do: "; #{count} dependent agent(s) remain paused"

  defp blocked_reason(0), do: "; no dependent agents are waiting on it"
  defp blocked_reason(count), do: "; #{count} dependent agent(s) remain paused"
end
