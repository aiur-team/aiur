# DASH-034 — Render current-run Recent outcomes

**Kind:** executable

**Provenance:** planned in plan v1 after shipped-dashboard and refreshed-prototype Recent audit

**Complexity:** 3 — Responsive current-run outcome presentation with history preservation and degraded-state semantics

**Risk:** medium

**Phase hint:** 7

**Depends on:** DASH-003, DASH-007, DASH-032

**Serializes with:** DASH-005, DASH-015, DASH-021, DASH-022, DASH-027, DASH-028, DASH-031 — shared `DashboardLive`, Recent region, and responsive CSS

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-034

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-sol`, `phase:7`, `build-lane:dashboard-ui`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

The Units page renders a bounded `Recent / Finished this run` region from
DASH-032's qualified outcomes with truthful association, freshness, partiality,
and source states, while the global repository-merge audit, complete Decision
history, and real Analytics destination remain available on their proper
surfaces.

## Context and evidence

Current main shows durable repository merges and Decision history in the shared
Recent area. The prototype instead labels outcome cards `Finished this run`.
DASH-032 owns the temporal/identity qualification needed to make that claim;
LiveView must not recreate it from `observed_run_id`, visible rows, or event
time. DASH-007 must preserve complete Decision history before this ticket
changes the Units-region composition.

## Scope

- Render DASH-032 qualified outcomes only on the accepted Units destination,
  using safe PR number/title/summary, canonical ticket display identity, merge
  time, association wording, observation provenance, and source freshness.
- Label the region `Finished this run` only when the entire snapshot has a
  canonical current-run generation. Describe cards as repository merges
  associated with current-run member tickets; never claim Aiur/agent authorship
  or causality.
- Render healthy empty, partial reconciliation, stale membership/run window,
  merge source unavailable, restart/new-run, and truncated states explicitly.
  A partial or unavailable result cannot display a confident no-outcomes claim.
- Preserve trusted GitHub PR links and the real authenticated Analytics route.
  Do not copy the prototype's hard-coded `aiur.team/analytics` destination.
- Preserve the global RecentMerge audit where current product navigation keeps
  cross-run repository history. Do not destructively filter or relabel its
  durable store.
- Preserve complete Decision history through DASH-007 Commands composition,
  including provenance, revisions, dispatch, acknowledgement, and deep links.
  Removing it from Units is permitted only after that route remains reachable
  and regression-proven.
- Subscribe through existing dashboard PubSub/coalesced reloads and render only
  current DASH-032 generation. Preserve focus, scroll, and screen-reader
  stability as outcomes arrive or are enriched.
- Reflow cards, provenance, safe links, health copy, and empty states at
  320/390/768/960/desktop and 200% zoom with 44px interactive targets.

## Non-goals

- Qualify merges, query GitHub, mutate RecentMerge persistence, infer causality,
  display arbitrary branches, or create a second current-run outcome store.
- Replace Commands/Decision history, redesign Analytics, show cross-run BI, or
  add build accounting to outcome cards.
- Copy prototype CI/review/agent claims unless an accepted canonical source is
  separately present in DASH-032; unknown facts remain absent.

## Existing owner and reuse target

Extend the shipped `RecentOutcomes`/DashboardLive composition and safe-link
patterns. Consume DASH-032 snapshots only, preserve the global RecentMerge
presentation as a distinct scope, and rely on DASH-007 for Decision-history
relocation/preservation.

## Contract and invariants

- Presentation never recomputes membership, time-window qualification, branch
  linkage, or causality. Every card comes from the exact DASH-032 snapshot.
- `observed_run_id` may be shown as observation provenance but cannot select,
  label, sort, or promote an outcome.
- Global repository merges, current-run-qualified outcomes, and Decision
  history remain distinct scopes with truthful headings and destinations.
- Snapshot generation is pinned while rendering. Stale/new-run updates cannot
  append prior-run cards under the current heading.
- Safe text is bounded/escaped and links retain configured-repository trust.
  Raw GitHub events, PR bodies beyond the safe summary, credentials, account
  data, and local paths never reach the DOM.

## Refreshable implementation notes

- Reinspect final DASH-007/032 contracts, current RecentOutcomes component, and
  Analytics route at pickup. Preserve existing route/deep-link behavior.
- Prefer a pure presenter plus a small keyed component. Client hooks may manage
  focus/scroll only; they cannot filter or classify outcomes.
- Coordinate the shared Recent region and responsive CSS through declared
  serialization rather than duplicating a second dashboard container.

## Acceptance and verification

### Agent gate

- Presenter/LiveView tests cover qualified live/backfilled outcomes, healthy
  empty, partial, stale, unavailable, restart/new-run, truncation, enrichment,
  ordering, unsafe links, and generation changes.
- Regression tests prove `observed_run_id` alone never renders a card, global
  repository history remains separately reachable, complete Decision history
  remains reachable through Commands, and Analytics uses the real route.
- Browser/a11y tests cover keyboard/touch links, focus/scroll during live
  inserts, bounded announcements, safe empty/error copy, light/dark/reduced
  motion, 44px targets, 200% zoom, and all supported breakpoints.

### At-merge gate

- Rebase on DASH-003/007/032 and current main, sequence shared dashboard files,
  and pass RecentMerge, Decision history, Commands, Analytics, LiveView,
  security, browser accessibility, and full CI suites.

### Human/manual evidence

- From the Executor repository root, run the real dashboard and show a
  canonical current-run merge, an unrelated live-observed merge excluded, a
  qualifying backfilled merge, partial/unavailable wording, preserved Commands
  history, real Analytics navigation, and desktop/390px layouts.

## Failure, security, migration, and accessibility cases

- On provider/projection failure, retain only a visibly stale same-generation
  snapshot or show the named unavailable state; never fall back to raw events,
  visible rows, or a fabricated empty list.
- Escape/bound every field and preserve trusted configured-repository links.
  Evidence uses synthetic/redacted data and contains no credentials or paths.
- No durable migration. Global merge and Decision stores remain unchanged.
  Headings, provenance, health, time, and actions are semantic and non-color-
  dependent.

## Surfaces

- Reads: DASH-003 Units composition, DASH-007 Commands/Decision-history
  preservation, DASH-032 current-run outcome snapshots, real Analytics route.
- Writes: current-run Recent presenter/component, DashboardLive composition,
  responsive CSS, browser/regression/security tests.
- Contracts: `Finished this run` presentation and separation of current-run,
  global merge, and Decision-history scopes.
- Safety: causality-safe wording, trusted links, generation-safe live updates.

## Sibling boundaries and open gates

DASH-032 alone qualifies outcomes. DASH-007 owns Commands and Decision history;
this ticket may relocate presentation but cannot reduce lifecycle/history
access. DASH-033 proves composed existing-dashboard acceptance. This work is
outside the Build Order root and completion math.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-034`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
