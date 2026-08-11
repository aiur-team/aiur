defmodule Aiur.Orchestrator.MergedTicketReconciler do
  @moduledoc false

  alias Aiur.{Alerts, Issue, RecentMerge, RecentMergeStore, Tracker}
  alias Aiur.Orchestrator.{CommentWake, PushRouting, State}

  @spec reconcile(State.t(), [Issue.t()], keyword()) :: {State.t(), [Issue.t()]}
  def reconcile(state, issues, opts \\ [])

  def reconcile(%State{} = state, issues, opts) when is_list(issues) do
    recent_merges_fun = Keyword.get(opts, :recent_merges_fun, &RecentMergeStore.list/0)
    merges = recent_merges_fun.()

    Enum.reduce(issues, {state, []}, fn issue, {state_acc, retained} ->
      case merged_pull_request_for(issue, merges) do
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
        blockee_count = PushRouting.merged_ticket_blockee_count(state, issue.identifier)

        state =
          CommentWake.mark_pr_merged_issue_done(state, issue.identifier,
            update_issue_state_fun: fn _identifier, "done" -> :ok end,
            merger_allowed_fun: fn _login -> true end,
            resume_blockees_fun: Keyword.get(opts, :resume_blockees_fun, &PushRouting.maybe_resume_blockees_on_merged_ticket/2)
          )

        emit_reconciled_alert(issue, merge, blockee_count, opts)
        {state, retained}

      {:error, reason} ->
        emit_failed_alert(state, issue, merge, reason, opts)
        {state, [issue | retained]}
    end
  end

  defp reconcile_merged_ticket(state, issue, _merge, _opts, retained), do: {state, [issue | retained]}

  defp merged_pull_request_for(%Issue{identifier: identifier}, merges) when is_binary(identifier) and is_list(merges) do
    Enum.find(merges, fn
      %RecentMerge{} = merge -> identifier in RecentMerge.closing_issue_identifiers(merge)
      _ -> false
    end)
  end

  defp merged_pull_request_for(_issue, _merges), do: nil

  defp emit_reconciled_alert(_issue, _merge, 0, _opts), do: :ok

  defp emit_reconciled_alert(issue, merge, blockee_count, opts) do
    emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

    emit_alert_fun.(
      "ticket.#{issue.identifier}.dependency.merged_blocker_reconciled",
      issue: issue,
      reason: "Merged PR ##{merge.number} closed this active ticket by reference; reconciling it and resuming #{blockee_count} dependent agent(s).",
      needs_attention: false,
      severity: "warning"
    )
  end

  defp emit_failed_alert(state, issue, merge, reason, opts) do
    blockee_count = PushRouting.merged_ticket_blockee_count(state, issue.identifier)

    if blockee_count > 0 do
      emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

      emit_alert_fun.(
        "ticket.#{issue.identifier}.agent.attention.merged_pr_reconciliation_failed",
        issue: issue,
        reason: "Merged PR ##{merge.number} closes this active ticket, but the transition to done failed (#{inspect(reason)}); #{blockee_count} dependent agent(s) remain paused.",
        needs_attention: true,
        severity: "warning",
        central: true
      )
    end
  end
end
