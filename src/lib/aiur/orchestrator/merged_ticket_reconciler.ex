defmodule Aiur.Orchestrator.MergedTicketReconciler do
  @moduledoc """
  Closes tickets that a merged pull request named with a closing keyword.

  GitHub auto-closes referenced issues only when a pull request merges into the
  repository's default branch, and that mechanism is best-effort: a keyword the
  parser misses, a merge into a non-default branch, or a delivery gap leaves
  the ticket open with no signal. This reconciler is the reliable completion
  path — it also releases dependency-paused agents, which auto-close does not —
  rather than a repair for a one-off GitHub failure. Alerts are worded and
  rated accordingly.

  Two guards keep a retained merge record from re-closing a ticket that is
  legitimately open again. A merge reconciles a given ticket at most once per
  run, and a merge older than `@stale_merge_after_seconds` is ignored
  altogether: `RecentMergeStore` keeps the last hundred merges with no recency
  bound of its own, so without this a ticket reopened for rework would be
  force-closed on the next poll.

  A ticket can legitimately carry more than one open pull request — two
  `aiur/<ticket>-<slug>` branches worked in parallel — so a merge is only
  terminal when the ticket has no *other* blocking open PRs left. Before
  writing `done`, the reconciler enumerates the ticket's open PRs: a remaining
  open PR with unresolved review findings routes the ticket to `rework`, one
  merely awaiting review routes it to `human-review`, and only a ticket with no
  blocking open PR at all is written `done`. A stale draft — one with no update
  within the staleness window — is treated as a superseded attempt and does not
  block `done`: an abandoned draft must not pin its ticket out of its terminal
  state. A failed open-PR lookup never closes the ticket.
  """
  alias Aiur.{Alerts, Issue, RecentMerge, RecentMergeStore}

  alias Aiur.Orchestrator.{
    Lifecycle,
    MergeStateWriter,
    OptimisticLedger,
    PushRouting,
    Reconciler,
    State,
    TrackerTasks
  }

  alias Aiur.Orchestrator.MergedTicketReconciler.{
    ClosedRepair,
    NonClosingMerge,
    OpenPullRequestTarget
  }

  require Logger

  # A merge older than this no longer explains why a ticket is open now: the
  # ticket has had a full day to be reopened deliberately.
  @stale_merge_after_seconds 24 * 60 * 60

  # An idle draft only stops blocking `done` after a longer window than merge
  # staleness: live parallel work can sit idle for days.

  @spec reconcile(State.t(), [Issue.t()], keyword()) :: {State.t(), [Issue.t()]}
  def reconcile(state, issues, opts \\ [])

  def reconcile(%State{} = state, issues, opts) when is_list(issues) do
    recent_merges_fun = Keyword.get(opts, :recent_merges_fun, &RecentMergeStore.list/0)
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
    now = now_fun.()
    merges = recent_merges_fun.()

    {state, retained} =
      Enum.reduce(issues, {state, []}, fn issue, {state_acc, retained} ->
        case merged_pull_request_for(state_acc, issue, merges, now, opts) do
          nil ->
            {state_acc, [issue | retained]}

          merge ->
            reconcile_merged_ticket(state_acc, issue, merge, opts, retained)
        end
      end)

    repair_recent_closed_tickets(state, issues, merges, now, opts)
    |> then(fn state -> {state, Enum.reverse(retained)} end)
  end

  def reconcile(%State{} = state, _issues, _opts), do: {state, []}

  defp repair_recent_closed_tickets(state, issues, merges, now, opts) do
    ClosedRepair.reconcile(state, issues, merges, now, opts, &record_reconciled(&1, &2, &3), &repair_closed_issue(&1, &2, &3, &4))
  end

  defp repair_closed_issue(state, issue, merge, opts) do
    update =
      Keyword.get(opts, :update_issue_state_fun, fn identifier, target, expected ->
        MergeStateWriter.write_reconciler_transition(identifier, target, expected, opts)
      end)

    case update.(issue.identifier, "done", :none) do
      :ok ->
        emit_reconciled_alert(issue, merge, 0, 0, opts)
        record_reconciled(state, issue, merge)

      {:error, reason} ->
        emit_failed_alert(state, issue, merge, reason, opts)
    end
  end

  defp reconcile_merged_ticket(state, %Issue{} = issue, merge, opts, retained) do
    unless NonClosingMerge.reference_only?(issue, merge, opts) do
      close_ledger = Keyword.get(opts, :close_optimistic_ledger_fun, &OptimisticLedger.close/3)
      close_ledger.(issue.identifier, :merged, System.system_time(:millisecond))
    end

    if TrackerTasks.owner?(state) do
      input = Reconciler.issue_input(state, issue.id)

      state =
        TrackerTasks.run(
          state,
          {:merged_reconcile, issue.id},
          fn -> fetch_merged_ticket_state({issue, merge, opts}) end,
          fn arg1, arg2 ->
            apply_merged_ticket_state(arg1, arg2, {input, issue, merge, opts})
          end
        )

      {state, retained}
    else
      reconcile_merged_ticket_sync(state, issue, merge, opts, retained)
    end
  end

  defp reconcile_merged_ticket(state, issue, _merge, _opts, retained),
    do: {state, [issue | retained]}

  defp start_merged_transition(state, issue, merge, opts, {:ok, target}) do
    input = Reconciler.issue_input(state, issue.id)

    update =
      Keyword.get(opts, :update_issue_state_fun, fn identifier, target, expected ->
        MergeStateWriter.write_reconciler_transition(identifier, target, expected, opts)
      end)

    TrackerTasks.run(
      state,
      {:merged_reconcile, issue.id},
      fn ->
        if target == "needs-triage",
          do: NonClosingMerge.write_target(issue, merge, expected_state(issue), opts, update),
          else: update.(issue.identifier, target, expected_state(issue))
      end,
      fn current, result ->
        if Reconciler.issue_input(current, issue.id) == input do
          apply_merged_result(current, issue, merge, opts, {:transition, target, result})
        else
          Lifecycle.wake_tick(current)
        end
      end
    )
  end

  defp start_merged_transition(state, issue, merge, opts, {:error, reason}),
    do: emit_failed_alert(state, issue, merge, reason, opts)

  defp apply_merged_result(state, issue, merge, opts, {:transition, target, result}) do
    opts =
      Keyword.put(opts, :update_issue_state_fun, fn _identifier, _target, _expected -> result end)

    {state, _retained} =
      cond do
        target == "done" ->
          reconcile_merged_ticket_to_done(state, issue, merge, opts, [])

        target == "needs-triage" ->
          if result == :ok do
            {record_reference_triage(state, issue, merge, opts), []}
          else
            {emit_failed_alert(state, issue, merge, result, opts), [issue]}
          end

        true ->
          reconcile_merged_ticket_remaining_open(state, issue, merge, target, opts, [])
      end

    if result == :ok, do: Lifecycle.wake_tick(state), else: state
  end

  defp reconcile_merged_ticket_sync(state, %Issue{} = issue, merge, opts, retained) do
    if NonClosingMerge.reference_only?(issue, merge, opts) do
      reconcile_reference_only_ticket(state, issue, merge, opts, retained)
    else
      reconcile_closing_merge_ticket(state, issue, merge, opts, retained)
    end
  end

  defp reconcile_closing_merge_ticket(state, issue, merge, opts, retained) do
    case merged_ticket_target_for_issue(issue, opts) do
      {:ok, "done"} ->
        reconcile_merged_ticket_to_done(state, issue, merge, opts, retained)

      {:ok, "needs-triage"} ->
        case NonClosingMerge.write_target(issue, merge, issue.state, opts, NonClosingMerge.update_issue_state_fun(opts)) do
          :ok -> {record_reconciled(state, issue, merge), retained}
          {:error, reason} -> {emit_failed_alert(state, issue, merge, reason, opts), [issue | retained]}
        end

      {:ok, target} when target in ["rework", "ci-wait", "human-review"] ->
        reconcile_merged_ticket_remaining_open(state, issue, merge, target, opts, retained)

      {:error, reason} ->
        # A failed open-PR lookup must never guess at `done`: closing the ticket
        # is exactly the abandonment this reconciler exists to prevent. Retain
        # the ticket and raise the standard attention; the next poll retries.
        state = emit_failed_alert(state, issue, merge, reason, opts)
        {state, [issue | retained]}
    end
  end

  defp reconcile_reference_only_ticket(state, issue, merge, opts, retained) do
    case NonClosingMerge.write_target(issue, merge, issue.state, opts, NonClosingMerge.update_issue_state_fun(opts)) do
      :ok ->
        state = record_reference_triage(state, issue, merge, opts)
        {state, retained}

      {:error, reason} ->
        state = emit_failed_alert(state, issue, merge, reason, opts)
        {state, [issue | retained]}
    end
  end

  defp record_reference_triage(state, issue, merge, opts),
    do: NonClosingMerge.record_triage(state, issue, merge, opts, &record_reconciled/3, &emit_failed_alert/5)

  # Repair a physical close with a missing state label from its branch merge;
  # other open PRs cannot make an already-closed issue dispatchable again.
  defp merged_ticket_target_for_issue(%Issue{} = issue, opts) do
    if closed_without_state_label?(issue), do: {:ok, "done"}, else: merged_ticket_target(issue.identifier, opts)
  end

  # The merge closed the ticket's last open PR: no other PR remains, so the
  defp reconcile_merged_ticket_to_done(state, %Issue{} = issue, merge, opts, retained) do
    update_issue_state_fun =
      Keyword.get(opts, :update_issue_state_fun, fn identifier, state_name, expected_state ->
        MergeStateWriter.write_reconciler_transition(identifier, state_name, expected_state, opts)
      end)

    case update_issue_state_fun.(issue.identifier, "done", expected_state(issue)) do
      :ok ->
        blocked_before = PushRouting.merged_ticket_blockee_count(state, issue.identifier)

        state =
          __MODULE__.StrandedWork.mark_merged(
            state,
            issue.identifier,
            Keyword.merge(merged_ticket_opts(merge, opts),
              head_sha: merge.head_sha,
              pr_number: merge.number
            )
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

  # A second (or later) open PR for the same ticket survives the merge, so the
  # ticket must NOT be terminalized: its remaining PR's review findings have to
  # stay dispatchable. Route to rework when any remaining PR has unresolved
  # review findings, otherwise to human-review. The reconciliation is still
  # recorded so this merged PR does not re-fire every poll, and the ticket is
  # not retained as a dispatch candidate this cycle — the normal poll picks it
  # up in its new state next cycle. No terminal teardown runs: the ticket is
  # still active, so dependents stay blocked on it and no session handle is
  # cleared.
  defp reconcile_merged_ticket_remaining_open(
         state,
         %Issue{} = issue,
         merge,
         target,
         opts,
         retained
       ) do
    update_issue_state_fun =
      Keyword.get(opts, :update_issue_state_fun, fn identifier, state_name, expected_state ->
        MergeStateWriter.write_reconciler_transition(identifier, state_name, expected_state, opts)
      end)

    case update_issue_state_fun.(issue.identifier, target, issue.state) do
      :ok ->
        state = record_reconciled(state, issue, merge)
        emit_remaining_open_alert(issue, merge, target, opts)
        {state, retained}

      {:error, reason} ->
        state = emit_failed_alert(state, issue, merge, reason, opts)
        {state, [issue | retained]}
    end
  end

  @doc "Returns the post-merge ticket state based on remaining open PRs."
  @spec merged_ticket_target(String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def merged_ticket_target(identifier, opts),
    do: OpenPullRequestTarget.merged_ticket_target(identifier, opts)

  # Terminalization already checked open PRs; preserve merger attribution for
  # the audit and skip that audit when the stored merge has no attributed actor.
  defp merged_ticket_opts(%RecentMerge{merged_by: merged_by}, opts) do
    base = [
      update_issue_state_fun: fn _identifier, "done" -> :ok end,
      resume_blockees_fun:
        Keyword.get(
          opts,
          :resume_blockees_fun,
          &PushRouting.maybe_resume_blockees_on_merged_ticket/2
        ),
      # This caller already ran `merged_ticket_target/2` and only reaches the
      # terminal path when no other open PR remains, so `mark_pr_merged_issue_done`
      # must not re-enumerate the ticket's open PRs (and would hit the stubbed
      # arity-2 update fun below on a non-done target).
      target_state: "done"
    ]

    base = Keyword.merge(base, Keyword.take(opts, [:merger_allowed_fun]))

    if attributed_merger?(merged_by) do
      Keyword.put(base, :merged_by_login, merged_by)
    else
      Keyword.put_new(base, :merger_allowed_fun, fn _login -> true end)
    end
  end

  defp attributed_merger?(merged_by), do: is_binary(merged_by) and String.trim(merged_by) != ""

  defp merged_pull_request_for(
         %State{} = state,
         %Issue{identifier: identifier} = issue,
         merges,
         now,
         opts
       )
       when is_binary(identifier) and is_list(merges) do
    Enum.find(merges, fn
      %RecentMerge{} = merge ->
        (identifier in RecentMerge.closing_issue_identifiers(merge) or
           (closed_without_state_label?(issue) and merge.ticket_id == identifier) or
           NonClosingMerge.triage_due?(issue, merge, opts)) and
          not stale_merge?(merge, now) and
          not already_reconciled?(state, issue, merge)

      _ ->
        false
    end)
  end

  defp merged_pull_request_for(_state, _issue, _merges, _now, _opts), do: nil

  defp closed_without_state_label?(%Issue{state: state, state_labels: labels}) do
    String.downcase(to_string(state || "")) == "closed" and labels in [nil, []]
  end

  defp expected_state(%Issue{} = issue),
    do: if(closed_without_state_label?(issue), do: :none, else: issue.state)

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

  defp reconciliation_key(%Issue{identifier: identifier}, %RecentMerge{id: id}),
    do: {identifier, id}

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
        "GitHub auto-close is best-effort and can silently miss a referenced ticket, so a merged PR does not reliably close the tickets it names. " <>
          "Ticket #{issue.identifier} is named by merged PR ##{merge.number}, so it was transitioned to done by compare-and-set" <>
          "#{resumed_reason(resumed, blocked_before)}.",
      needs_attention: false,
      severity: "info"
    )
  end

  defp resumed_phrase(_resumed, 0), do: " (no dependent agents were waiting on it)"

  defp resumed_phrase(resumed, blocked_before),
    do: " and resumed #{resumed} of #{blocked_before} dependent agent(s)"

  defp resumed_reason(_resumed, 0), do: "; no dependent agents were waiting on it"

  defp resumed_reason(resumed, blocked_before),
    do: "; #{resumed} of #{blocked_before} dependent agent(s) resumed"

  # The merged PR closed one of the ticket's PRs, but other open PRs survive, so
  # the ticket stays active and its remaining PR's findings must remain
  # dispatchable. Announced like the done path: a state write this consequential
  # must never be invisible.
  defp emit_remaining_open_alert(issue, merge, target, opts) do
    emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

    emit_alert_fun.(
      "ticket.#{issue.identifier}.dependency.merged_pr_remaining_open",
      issue: issue,
      message: "Merged PR ##{merge.number} closed one of ticket #{issue.identifier}'s PRs; marked it #{target} instead of done because other open PRs remain.",
      reason:
        "Merged PR ##{merge.number} names ticket #{issue.identifier}, but the ticket still has other open pull requests, so it must not be closed: " <>
          "their review findings stay dispatchable, and the ticket was transitioned to #{target} rather than done by compare-and-set.",
      needs_attention: false,
      severity: "info"
    )
  end

  # The transition retries on every poll while it keeps failing, so the alert
  # is raised once per distinct failure and repeated only when the reason
  # changes. Silence at zero dependents would hide a permanently stuck ticket.
  # The failure covers every target the reconciler can pick: the done
  # transition, a remaining-open-PR transition (rework/human-review), or the
  # open-PR lookup itself — all of which keep the ticket active and undispatch
  # it into a terminal state.
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
        message: "Merged PR ##{merge.number} could not reconcile ticket #{issue.identifier}#{blocked_phrase(blockee_count)}.",
        reason:
          "Merged PR ##{merge.number} names this active ticket, but the reconciliation failed (#{inspect(reason)}) and will keep being retried" <>
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

  defp fetch_merged_ticket_state({issue, merge, opts}),
    do:
      if(NonClosingMerge.reference_only?(issue, merge, opts),
        do: {:ok, "needs-triage"},
        else: merged_ticket_target_for_issue(issue, opts)
      )

  defp apply_merged_ticket_state(current, result, {input, issue, merge, opts}) do
    if Reconciler.issue_input(current, issue.id) == input do
      start_merged_transition(current, issue, merge, opts, result)
    else
      Lifecycle.wake_tick(current)
    end
  end
end
