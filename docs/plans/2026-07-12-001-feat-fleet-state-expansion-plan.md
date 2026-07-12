---
title: "feat: Fleet-state expansion (explicit waiting reasons)"
type: feat
status: in-progress
date: 2026-07-12
---

# feat: Fleet-state expansion (explicit waiting reasons)

## Summary

OCC-5: expand the dashboard/API fleet snapshot beyond live running procs with
an explicit waiting-reason vocabulary, stale-activity age, PR/CI/review
status, and an open-decision count per row — extending `Presenter` /
`DashboardLive` rather than building a parallel projection.

## Dependency note (OCC-1 / #979)

The issue says "Depends on OCC-1." #979 is not merged yet. After auditing
`Aiur.DecisionAttention`, `Aiur.Events.SubscriptionStore`, and
`Aiur.AgentList.Roster` (the CLI's existing `❗N` badge), the open-decision
*count* does not actually need OCC-1's `DecisionStore`: `SubscriptionStore`
already tracks `open_attentions` per ticket durably and independently of
OCC-1, and the CLI roster already renders a count from it
(`Roster.refresh_open_attentions/1`). U3 reuses that same source for the web
row. When OCC-1's `DecisionStore` lands, its richer Decision detail can
enrich this count without changing the row shape — that follow-up swap is
out of scope here. Nothing in this ticket is blocked on #979.

## Units

### U1 — explicit waiting reasons + stale-activity age

- New pure module `Aiur.Orchestrator.WaitingReason` computing one of
  `:waiting_for_human | :waiting_for_supervisor | :waiting_for_dependency |
  :waiting_for_ci | :waiting_for_review | :paused | :backing_off |
  :unresponsive | :active` — never a generic "blocked".
  - Running rows: derived from `work_state`/`pause_reason`
    (`:ci_wait` → waiting_for_ci; `:operator_pause`/`:label_override`/
    `:pane_ctrl_c`/`:max_agent_duration`/`:agent_pause_request` →
    `:paused`), overridden by staleness past `Config.agent_stall_timeout_ms/0`
    → `:unresponsive`, overridden by an open `SubscriptionStore` attention →
    `:waiting_for_human`.
  - Retry-queue rows: always `:backing_off`.
  - Idle/queued rows (tracker-active, no live process — new bucket, see
    below): derived from tracker state (`ci-wait` → waiting_for_ci;
    `human-review` → waiting_for_review; `rework` → waiting_for_human;
    `merging` → waiting_for_supervisor) and
    `DispatchPolicy.todo_issue_blocked_by_non_terminal?/2` →
    `waiting_for_dependency` (takes precedence for `todo`-state issues).
- Extend `Aiur.Orchestrator.StatusReport.snapshot/1` with a third `idle` list
  built the same way `agent_statuses/1`'s `idle_statuses/2` already does
  (tracker-active issues from `state.last_polled_issues` with no running
  entry) — the PRD asks for "one consolidated view of all run work, not just
  running procs."
- `stale_for_seconds` per running/idle row: `DateTime.diff(now,
  last_codex_timestamp || started_at)`, mirroring
  `RuntimeWatchdog.stall_elapsed_ms/2`'s existing signal — no new tracking.
- `Presenter.state_payload/2` projects `waiting_reason` and
  `stale_for_seconds` for `running`/`retrying`, and adds the new `idle` list
  + `counts.idle`.
- `DashboardLive` gets a "Waiting" badge column on the running table (new
  badge helper, since `state_badge_class/1`'s substring matching doesn't fit
  an explicit atom vocabulary) and a compact new "Queued / waiting" section
  for the `idle` bucket.

### U2 — PR/CI/review status per row

- `Aiur.Orchestrator.CiLifecycle.apply_ci_poll_result/3` gets a thin wrapper
  that stashes a small `%{decision, pr_number, head_sha}` projection of the
  already-fetched `GithubCIPoller` result onto the running entry
  (`:last_ci_result`) before delegating to the existing transition logic —
  reuses the existing poll, adds no new GitHub calls, and preserves the
  existing transition behavior byte-for-byte except that one new key.
  - One existing test
    (`orchestrator_ci_lifecycle_test.exs` "pending CI is idempotent...")
    asserts full `next == state` for a no-transition poll; it will be
    updated to assert the rest of the entry is unchanged plus the new
    `:last_ci_result` key, since a fresh CI/PR read is exactly what this
    ticket asks a redundant poll to still produce.
- `review` status is derived from tracker state only (`human-review` vs
  not) — no new call to `HumanReviewGate`/`ReviewThreads` per row; that
  live thread check stays a one-shot check at the state-transition moment,
  per its existing design. Documented as a known limitation.
- `Presenter` projects `ci: %{decision, pr_number, head_sha}` (nil until a
  ticket has actually entered CI polling) and `review: :awaiting |
  :not_started` per running row.

### U3 — open-decision count per row

- `open_decision_count` per running/idle row, sourced from
  `Aiur.Events.SubscriptionStore.snapshot(identifier).open_attentions`
  (same source as `Roster.attention_count_for/1`), with the same
  not-found/rescue fallback to `0`.

## Test plan

- New `Aiur.Orchestrator.WaitingReasonTest` — pure unit tests per branch of
  the derivation logic.
- Extend `orchestrator_status_test.exs` for the new `idle` snapshot list and
  `stale_for_seconds`.
- Extend `orchestrator_ci_lifecycle_test.exs` for `:last_ci_result` stashing
  (plus the one updated assertion above).
- New `AiurWeb.PresenterTest` (none exists today) covering `state_payload/2`
  projection of the new fields for running/retrying/idle rows.
- `mix compile --warnings-as-errors`, `mix format`, affected tests with
  `--max-cases 4`.

## Out of scope

- OCC-1's `DecisionStore` integration (richer Decision detail beyond a
  count) — future enrichment, not blocked on here.
- Live per-row GitHub review-thread polling.
- OCC-4's decision inbox UI.
