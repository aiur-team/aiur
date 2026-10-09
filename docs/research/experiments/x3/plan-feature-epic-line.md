---
title: EXP-X3-3 Measured feature-epic line - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x3/brainstorm.md
epic: aiur-team/aiur#3774
---

# EXP-X3-3 Measured feature-epic line - Plan

## Summary

An epic that carries the measure label (default `experiment:feature`) is armed
as a `feature` experiment as soon as the label is seen. Arming freezes the
baseline and asks for pre-registration. The line is set when every sub-issue is
closed, at least one is merged, a quiet period has passed, and the last merge
is live by the configured live signal. Product Contract unchanged.

## Problem frame

Feature epics such as #3755 and #3774 are plain parent issues with GitHub
sub-issues. They carry no `build-order` label. The `ResourceStore` holds
`:sub_issue` edges from webhook deposits
(`src/lib/aiur/events/github_webhook/deposit.ex:334`) and from Build Order
reconciliation. Only Build Order roots are reconciled, so a non-Build-Order
epic may have no edges in polling mode. `RecentMerge` carries
`merge_commit_sha` and the `aiur/<n>` ticket link.

"Live" means different things:
- For aiur-on-aiur, it is the next daemon build that contains the merge.
- For a consumer, Aiur cannot see the deploy.

## Requirements

R4, R5, AE4 of origin.

## Key technical decisions

- **State machine.** One record per epic in
  `<state node>/experiments/auto-features.json`:
  - `armed`: experiment created, baseline frozen, pre-registration requested;
  - `merging`: at least one member merged;
  - `awaiting_live`: all members closed and the quiet period passed;
  - `line_set`;
  - `cancelled`.

  The record is written before any side effect is published, the same
  durability order as `Aiur.BuildProgress`.
- **Finding labelled epics.** One REST call per hour:
  `GET /repos/{o}/{r}/issues?labels=<feature_label>&state=all&per_page=100`,
  through the GitHub budget broker under a named request origin.
  - Labelled issues that are already in `ResourceStore` `:issue_labels` are
    picked up between polls from the webhook path.
  - An issue counts as an epic only if it has at least one sub-issue. A
    labelled leaf issue is reported in `status/0` as `not_an_epic` and
    ignored.
- **Membership.** `ResourceStore` `:sub_issue` edges come first. Each armed
  epic also gets a bounded REST read, `GET /issues/{n}/sub_issues` (one page,
  100), once an hour. A `ticket.*.pr.merged` event for a known member
  triggers the read sooner, debounced to 5 minutes. Up to 100 members are
  supported. Beyond that, `status/0` reports `member_limit` and the line still
  works on the first 100. This matches the Build Order member limit in
  `catalog_store.ex`.
- **Member outcome.**
  - A member closed as `completed` that has a merged linked PR is merged. The
    merge time and merge SHA come from `RecentMergeStore` by ticket id. If the
    store has no record, they come from
    `GitHub.IssueRelationships.fetch_linked_pull_requests/3`.
  - A member closed `not_planned` is excluded.
  - A member closed `completed` with no merged PR (done without code) is
    excluded and annotated.
  - If every member is excluded, the experiment is cancelled.
- **Arming windows.** At arming, the Creator receives:
  - before = `[anchor - before_days, anchor)`, where anchor is the earliest
    member merge if one exists, else the arming time;
  - `freeze_baseline` on that window.

  At the first member merge, if that merge is after the arming time, the
  before window is moved to end at that merge and frozen again (KD4). From
  then on the window is fixed.
- **Late arming.** If the label is added after members have merged, the before
  window ends at the first member merge, which is in the past. The frozen
  baseline may miss data already pruned by retention. The experiment is then
  annotated `baseline_coverage: partial` with the covered range.
- **Quiet period.** The epic must have all members closed and no member added
  for `feature_quiet_hours`. A member added after `line_set` does not move the
  line. It is annotated as a post-line scope change.
- **Live signal resolution** (`feature_live_signal`):
  - **`auto`** resolves to `daemon_boot` when the deploy ledger's latest row
    has a `source_sha` and the build stamp's `repo_root` has an `origin` remote
    that names the managed repository. Otherwise it resolves to `merge`.
  - **`daemon_boot`**: the line is the first deploy-ledger row at or after the
    last merge where
    `git merge-base --is-ancestor <last_merge_sha> <source_sha>` succeeds in
    the warm clone. An unknown SHA, such as an unpushed local build, counts as
    "not containing".
  - **`release`**: the line is the first release tag (EXP-X3-2 seen-state)
    whose commit contains the last merge SHA.
  - **`merge`**: the line is the last member's merge time.
  - **Fallback**: after `live_signal_max_wait_hours` without a live signal,
    the line is the merge time, with the annotation `live_signal_fallback`.
- **Excluded rollout window.** The interval `[first member merge, line)` is
  passed to X2 as `windows.excluded`.
- **Label removed.**
  - Before `line_set`: the experiment is cancelled and
    `system.experiment.<id>.cancelled` is published.
  - After `line_set`: nothing changes. The data is already being collected,
    and removing the label is not a reason to throw it away.
- **The pre-registration event** (`system.experiment.<id>.preregister`) is
  published at arming time, through EXP-X3-4's notifier.

## Implementation units

### U1. Epic discovery and membership reader

**Files:** `src/lib/aiur/experiments/auto/feature_epics.ex`,
`src/lib/aiur/experiments/auto/epic_members.ex`, tests;
`src/lib/aiur/github/request_origin.ex` (new origin `:experiments_auto`).

**Test scenarios:**
- A labelled issue with 3 store sub-issue edges is discovered with 3 members.
- A labelled issue with no store edges and 2 REST sub-issues is discovered
  with 2 members.
- A labelled leaf issue is reported `not_an_epic` and never armed.
- When the budget broker refuses the read, the state is unchanged and the
  next tick retries.
- A `pr.merged` event for member #3763 triggers a membership refresh within
  the debounce window. A second event inside the window does not trigger a
  second read.

### U2. Feature state machine and arming

**Files:** `src/lib/aiur/experiments/auto/feature_line.ex` (GenServer),
`src/lib/aiur/experiments/auto/feature_state.ex` (a pure transition
function), tests.

**Execution note:** Implement `feature_state` test-first as a pure
`transition(state, observation, config, now)`. The GenServer only feeds it
observations.

**Test scenarios:**
- Covers AE4: the label is seen, no member is merged, and the state becomes
  `armed`. Creator is called with a before window ending now, and the
  baseline is frozen once.
- In `armed`, the first member merges 3 days later. The state becomes
  `merging`, the before window moves to end at that merge, and the baseline
  is frozen a second time.
- Late arming: the label is added after 2 members merged. The before window
  ends at the first merge, and a `baseline_coverage: partial` annotation is
  made when the retention start is after the window start.
- All members are closed and the last one closed 2 hours ago. The state stays
  `merging` until 6 hours pass, then becomes `awaiting_live`.
- A new member is added during the quiet period. The state returns to
  `merging`.
- All members closed `not_planned` makes the state `cancelled` and publishes
  the cancelled event once.
- Label removed while `armed`: the state becomes `cancelled`. Label removed
  after `line_set`: no change.
- After a daemon restart, the persisted state reloads and nothing is armed or
  frozen twice.

### U3. Live signal resolver

**Files:** `src/lib/aiur/experiments/auto/live_signal.ex`, tests.

**Test scenarios:**
- `auto` with a stamp `repo_root` whose origin is the managed repo resolves
  to `daemon_boot`. With no stamp, it resolves to `merge`.
- `daemon_boot`: a ledger row at T+3h whose `source_sha` contains the merge
  makes the line T+3h. An earlier row at T+1h whose SHA does not contain it
  is skipped.
- `daemon_boot`: an unknown `source_sha` (cat-file fails) counts as not
  containing. After 72 hours, the line is the merge time with the
  `live_signal_fallback` annotation.
- `release`: tag v1.2.0 contains the merge, so the line is the tag time.
  Tag v1.1.9 does not, so it is skipped.
- `merge`: the line is the last merge time.
- The excluded window `[first merge, line)` is passed to X2.

## Verification contract

- The unit tests pass, including the restart idempotency test.
- Dry run on the runtime daemon: add `experiment:feature` to a scratch epic
  with two scratch sub-issues. The arming record and the frozen baseline appear
  within one hour, or within minutes when a webhook delivers the label.
  Closing both sub-issues as not-planned cancels the experiment.

## Documentation

- Experiments concept page, section "Measuring a feature": how to tag an epic,
  when the line is set, the live signals, the quiet period, and what late
  tagging costs (a partial baseline).
- `.claude/skills/aiur-build/` and `website/docs-app/concepts/build-orders.md`:
  one line saying that adding `experiment:feature` to a root measures it.

## Risks

- **GitHub budget.** One label query per hour plus one sub-issue read per
  armed epic per hour. Armed epics are few, so this is negligible. Every call
  goes through the budget broker.
- **Squash and rebase merges.** `merge_commit_sha` is the commit on the base
  branch in every merge mode, so the ancestor check holds.
- **Members in another repository** (cross-repo sub-issues) are excluded and
  annotated. v1 measures only the managed repository.

## Dependencies

EXP-X3-1 (in area). EXP-X3-2 for the `release` live signal only; the other
signals do not need it. EXP-X3-4's notifier, for the preregister event. X2
facade (cross-area).

## Definition of done

U1 to U3 are merged with tests. The dry run is verified. Docs are shipped.
