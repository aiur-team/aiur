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

  alias Aiur.{Alerts, Issue, RecentMerge, RecentMergeStore, Tracker}
  alias Aiur.Orchestrator.{CommentWake, PushRouting, ReworkGate, State}

  require Logger

  # A merge older than this no longer explains why a ticket is open now: the
  # ticket has had a full day to be reopened deliberately.
  @stale_merge_after_seconds 24 * 60 * 60

  # A draft pull request with no update within this window no longer stands
  # between a ticket and `done`. Deliberately longer than the merge-staleness
  # window: a live parallel draft can legitimately sit idle for days while its
  # author works, so declaring a draft abandoned early would abandon real work —
  # the exact failure this reconciler exists to prevent. The safer failure is
  # the opposite: an abandoned draft lingers a few days longer than strictly
  # necessary before the ticket completes.
  @stale_draft_after_seconds 7 * 24 * 60 * 60

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
    case merged_ticket_target(issue.identifier, opts) do
      {:ok, "done"} ->
        reconcile_merged_ticket_to_done(state, issue, merge, opts, retained)

      {:ok, target} when target in ["rework", "human-review"] ->
        reconcile_merged_ticket_remaining_open(state, issue, merge, target, opts, retained)

      {:error, reason} ->
        # A failed open-PR lookup must never guess at `done`: closing the ticket
        # is exactly the abandonment this reconciler exists to prevent. Retain
        # the ticket and raise the standard attention; the next poll retries.
        state = emit_failed_alert(state, issue, merge, reason, opts)
        {state, [issue | retained]}
    end
  end

  defp reconcile_merged_ticket(state, issue, _merge, _opts, retained), do: {state, [issue | retained]}

  # The merge closed the ticket's last open PR: no other PR remains, so the
  # legacy one-PR-per-ticket terminal path holds exactly as before.
  defp reconcile_merged_ticket_to_done(state, %Issue{} = issue, merge, opts, retained) do
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

  # A second (or later) open PR for the same ticket survives the merge, so the
  # ticket must NOT be terminalized: its remaining PR's review findings have to
  # stay dispatchable. Route to rework when any remaining PR has unresolved
  # review findings, otherwise to human-review. The reconciliation is still
  # recorded so this merged PR does not re-fire every poll, and the ticket is
  # not retained as a dispatch candidate this cycle — the normal poll picks it
  # up in its new state next cycle. No terminal teardown runs: the ticket is
  # still active, so dependents stay blocked on it and no session handle is
  # cleared.
  defp reconcile_merged_ticket_remaining_open(state, %Issue{} = issue, merge, target, opts, retained) do
    update_issue_state_fun =
      Keyword.get(opts, :update_issue_state_fun, fn identifier, state_name, expected_state ->
        Tracker.update_issue_state(identifier, state_name, expected_state: expected_state)
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

  @doc """
  Decides where a ticket named by a merged PR should land.

  Before any path writes `done` for a merged-PR ticket it must consult this,
  because a ticket can legitimately carry more than one open pull request — two
  `aiur/<ticket>-<slug>` branches worked in parallel. Returns `{:ok, "done"}`
  only when no blocking open PR remains, `{:ok, "rework"}` when a remaining open
  PR has unresolved review findings, `{:ok, "human-review"}` when remaining open
  PRs merely await review, and `{:error, reason}` when the open-PR lookup itself
  failed — callers must never close the ticket on that path.

  A remaining open PR that is a stale draft does not block `done`: a superseded
  or abandoned attempt left open forever must not pin its ticket out of its
  terminal state. Every other open PR blocks, because its review findings or
  review state are still live work.

  The open-PR listing and the per-PR unresolved-findings predicate are
  injectable via opts (`:open_pull_requests_fun` and
  `:open_pull_request_unresolved_findings_fun`) so callers can supply their own
  review-state source. The defaults route unresolved review threads through
  `ReworkGate` — the single place that owns that rule (#2450) — via the tracker
  boundary.
  """
  @spec merged_ticket_target(String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def merged_ticket_target(identifier, opts) when is_binary(identifier) or is_integer(identifier) do
    open_pull_requests_fun =
      Keyword.get(opts, :open_pull_requests_fun, &Tracker.fetch_open_pull_requests_for_branch/1)

    case open_pull_requests_fun.(to_string(identifier)) do
      {:ok, []} ->
        {:ok, "done"}

      {:ok, pull_requests} when is_list(pull_requests) ->
        merged_ticket_target_for_open_pull_requests(pull_requests, opts)

      {:ok, _other} ->
        # An unexpected listing shape must never close the ticket: fail safe so
        # the caller retains it and retries rather than guessing at done.
        {:error, :invalid_open_pull_requests_listing}

      {:error, _reason} = error ->
        error
    end
  end

  def merged_ticket_target(_identifier, _opts), do: {:ok, "done"}

  # Classifies a known-valid open-PR listing into the ticket's post-merge
  # target. Extracted so the caller's case stays flat (Credo's nesting cap):
  # a non-blocking set means the merge closed the ticket's last live PR, while
  # a blocking set routes to rework when any of it carries unresolved findings
  # and to human-review when it merely awaits review.
  defp merged_ticket_target_for_open_pull_requests(pull_requests, opts) do
    case blocking_open_pull_requests(pull_requests, opts) do
      [] ->
        {:ok, "done"}

      blocking ->
        if Enum.any?(blocking, &open_pull_request_has_unresolved_findings?(&1, opts)) do
          {:ok, "rework"}
        else
          {:ok, "human-review"}
        end
    end
  end

  # The open PRs that still stand between the ticket and `done` after a merge.
  # A stale draft is treated as a superseded attempt and filtered out: a dead
  # draft left open forever must not pin its ticket out of `done` (the
  # mirror-image of the abandonment this reconciler prevents). Every other open
  # PR blocks, because its review findings or review state are still live work.
  # Missing or unparseable draft/staleness signals fail open to blocking — a
  # wrongly-ignored PR abandons work, while a wrongly-blocking one merely keeps
  # the ticket active and dispatchable.
  defp blocking_open_pull_requests(pull_requests, opts) do
    now = now_fun(opts).()
    Enum.reject(pull_requests, &stale_draft?(&1, now))
  end

  defp now_fun(opts), do: Keyword.get(opts, :now_fun, &DateTime.utc_now/0)

  defp stale_draft?(pull_request, now) do
    draft_pull_request?(pull_request) and stale_since?(pull_request, now)
  end

  defp draft_pull_request?(pull_request) when is_map(pull_request) do
    Map.get(pull_request, "draft") == true or Map.get(pull_request, :draft) == true
  end

  defp draft_pull_request?(_pull_request), do: false

  defp stale_since?(pull_request, now) do
    case updated_at(pull_request) do
      %DateTime{} = updated_at -> DateTime.diff(now, updated_at, :second) > @stale_draft_after_seconds
      _ -> false
    end
  end

  defp updated_at(pull_request) do
    case Map.get(pull_request, "updated_at") || Map.get(pull_request, :updated_at) do
      %DateTime{} = updated_at ->
        updated_at

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, updated_at, _offset} -> updated_at
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Per-PR unresolved-findings predicate, injectable so callers can substitute
  # their own review-state source. The default routes on unresolved review
  # threads via `ReworkGate` — the single place that owns that rule (#2450) —
  # with the #1756 carve-out that an `APPROVED` verdict outranks a thread
  # nobody clicked "resolve" on, so an approved PR merely awaits review.
  defp open_pull_request_has_unresolved_findings?(pull_request, opts) do
    unresolved_findings_fun =
      Keyword.get(
        opts,
        :open_pull_request_unresolved_findings_fun,
        &default_open_pull_request_unresolved_findings?(&1, opts)
      )

    unresolved_findings_fun.(pull_request)
  end

  defp default_open_pull_request_unresolved_findings?(pull_request, opts) when is_map(pull_request) do
    case review_decision(pull_request) do
      # #1756: a reviewer's approval is a judgement on the whole change and
      # outranks a thread nobody resolved; the PR merely awaits review.
      "APPROVED" ->
        false

      _other ->
        # #2450: `reviewDecision` is sticky — a `CHANGES_REQUESTED` verdict never
        # clears when findings are addressed — so it is not a rework signal.
        # Unresolved review threads are: a PR whose threads are all resolved is
        # merely awaiting a fresh review and must not be routed to rework.
        case ReworkGate.open_pull_request_rework_verdict(pull_request, opts) do
          {:ok, :rework} ->
            true

          {:skip, :no_unresolved_review_threads} ->
            Logger.info(
              "merged-ticket reconcile: PR ##{pull_request_number(pull_request)} has zero unresolved review threads " <>
                "(#{inspect(:no_unresolved_review_threads)}); skipping rework (#2450)"
            )

            false

          # Fails open to "no unresolved findings": a transient thread lookup
          # must never fabricate a rework verdict. A wrongly-clear answer can at
          # worst route the ticket to `human-review`, whose entry gate re-checks
          # threads before letting the transition land, so it can never write
          # `done` over a finding.
          {:error, _reason} ->
            false
        end
    end
  end

  defp default_open_pull_request_unresolved_findings?(_pull_request, _opts), do: false

  defp review_decision(pull_request) do
    Map.get(pull_request, "review_decision") || Map.get(pull_request, :review_decision)
  end

  defp pull_request_number(%{"number" => number}) when is_integer(number), do: number
  defp pull_request_number(%{number: number}) when is_integer(number), do: number
  defp pull_request_number(_pull_request), do: nil

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
      resume_blockees_fun: Keyword.get(opts, :resume_blockees_fun, &PushRouting.maybe_resume_blockees_on_merged_ticket/2),
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
        "GitHub auto-close is best-effort and can silently miss a referenced ticket, so a merged PR does not reliably close the tickets it names. " <>
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
end
