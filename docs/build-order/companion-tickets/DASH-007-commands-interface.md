# BO: DASH-007 — Align Commands presentation

**Kind:** executable

**Provenance:** planned in plan v1 after Commands/current-main adversarial review

**Complexity:** 3 — Accessible vocabulary and composition over fixed durable Decision contracts

**Risk:** high

**Phase hint:** 3

**Depends on:** DASH-001, DASH-006, DASH-017

**Serializes with:** DASH-003, DASH-005, DASH-015, DASH-021, DASH-022, DASH-027, DASH-028, DASH-031 — shared `DashboardLive`/CSS

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-007

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-terra`, `phase:3`, `build-lane:dashboard-ui`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

The Executor Control Center presents Commands with the refreshed vocabulary, primary filters, provenance, option previews, and confidence while preserving every retained Decision state, stable deep link, and authenticated lifecycle action.

## Context and evidence

Current main has a durable, integrated Decision inbox/detail/history with answer, retry, revise, follow-up, acknowledgement, resolution, supervisor, and latency behavior. The prototype simplifies entry to Open/Blocking/Resolved/All and improves card hierarchy, but it hides secondary states, parses display prose for model identity, and contains fake quick actions. DASH-006 supplies exact lookup, pagination, and counts; DASH-017 supplies trusted optional provenance while existing `supervisor_basis.confidence` remains the confidence source.

## Scope

- Use Commands and Executor-facing vocabulary in navigation, page title, banner, filters, cards, detail, confirmation, empty/error states, and singular/plural copy. Preserve internal `Decision*` module, persistence, API, event, and historical ticket names.
- Render primary filters `Open`, `Blocking`, `Resolved`, and `All`. `Open` includes human-required recorded Decisions; `Blocking` includes unresolved blocking Decisions; `Resolved` includes resolved Decisions; `All` uses DASH-006's paginated retained query and exposes search. Keep answered-not-delivered, delivery-failed, supervising-decided, acknowledged, superseded, revisions, and follow-up states visible through cards, secondary status controls, detail, or history.
- Drive banner counts from DASH-006 canonical retained counts. If counts are degraded or partial, label them rather than presenting the bounded overview count as global truth.
- Render DASH-017 provider/backend/resolved-model provenance only when present and render the existing integer `supervisor_basis.confidence` unchanged on its `0..100` scale. Render unknown legacy values honestly. Show bounded option previews, selected/supervising-answer indicators, blocking reason, authority, delivery status, and latency without parsing prose.
- Preserve URL-backed filters, cursor/search state where shareable, direct detail routes, browser back/forward, irreversible confirmation, sanitization, optimistic-lock/version conflict handling, retry, revise, follow-up, and dynamic writable/auth gates.
- Preserve complete durable Decision history on a reachable Commands surface
  before DASH-034 changes the Units Recent region. History keeps provenance,
  selected answers, revisions, dispatch/acknowledgement, supersession, and
  stable detail navigation; it is never silently deleted to match the mock.

## Non-goals

- Rename/migrate the Decision domain, author provenance, alter supervisor-basis confidence, change authority or lifecycle semantics, or copy prototype Defer/Acknowledge/quick-choice actions.
- Make all history unbounded in one render, infer fields from prose, or hide actionable lifecycle states merely to match the four primary filters.
- Change Units, Build Order, usage accounting, or Analytics.

## Existing owner and reuse target

Extend current `DashboardLive`, `DecisionInbox`, `DecisionCard`, `DecisionDetail`, `DecisionHistory`, `DecisionPresenter`, and route helpers. Consume DASH-001 shell, DASH-006 providers, and DASH-017 canonical fields while preserving current Decision action APIs.

## Contract and invariants

- Commands is presentation vocabulary; canonical Decision identities, states, ordering, and write contracts remain authoritative.
- Every retained lifecycle state is reachable and named. Primary-filter simplicity cannot turn answered-pending, failed, superseded, or follow-up work into invisible state.
- Counts declare scope and health. Direct lookup never depends on the newest-50 overview window.
- Provenance displays only DASH-017 canonical values; confidence displays only existing `supervisor_basis.confidence` without rescaling or reconstruction.
- Mutation behavior remains confirmed where required, versioned, sanitized, authenticated, fail closed, and reconciled from the durable store.

## Refreshable implementation notes

- Refresh #1034's final Executor terminology and current OCC integration docs at pickup.
- Keep vocabulary/filter/card policy in presenters/components rather than changing store atoms or duplicating lifecycle reducers.
- Preserve full Decision detail as the source for long context; card previews remain bounded and escaped/sanitized.

## Acceptance and verification

### Agent gate

- Presenter/LiveView tests cover each primary and secondary lifecycle state,
  paginated/search `All`, old direct links, complete durable history,
  canonical/partial counts, blocking banner, pluralization, legacy/canonical
  provenance, confidence, and every existing write safeguard.
- Browser/a11y tests cover URL/back/search/pagination, keyboard/touch, focus/confirmation, retry/error/version conflict, 200% zoom, 320/390/768/960 widths, read-only and unauthenticated modes.
- Regression tests prove no prototype-only action is dispatchable and no lifecycle state disappears from all reachable surfaces.

### At-merge gate

- Rebase on #1034, DASH-001/006/017, and the resolved configured integration target; sequence Decision/DashboardLive/CSS ownership and pass Decision store/API/history/metrics, auth, accessibility, and full CI suites.

### Human/manual evidence

- From the Executor repository root, use the real dashboard to open, answer, retry or revise, and revisit representative blocking, delivery-pending/failed, supervising-decided, superseded, and resolved Commands, including a direct link outside the overview window.

## Failure, security, migration, and accessibility cases

- Provider failure preserves healthy sections, marks partial counts/pages/detail, and never hides a known blocking Command as an empty healthy state.
- Preserve sanitization, Basic/supervisor auth, CSRF, writable, version-conflict, trusted-link, and secret-redaction behavior.
- This presentation ticket introduces no persistence-name or additive schema
  migration; DASH-017 owns provenance schema, replay, and legacy migration.
- Filters, status, urgency, confirmation, errors, option previews, and confidence remain keyboard/touch reachable and non-color-dependent.

## Surfaces

- Reads: DASH-006 overview/page/search/detail/count contracts; DASH-017 provenance; existing supervisor basis; current Decision lifecycle/action state.
- Writes: Commands presenters/components/routes copy, URL interaction, CSS, browser/component tests.
- Contracts: Commands vocabulary, filter/state reachability, banner/count presentation.

## Sibling boundaries and open gates

DASH-001 owns navigation shell, DASH-006 owns retained queries, and DASH-017
owns durable provenance without changing existing confidence. DASH-034 may
change Units Recent only after this Commands history remains reachable. This
ticket must not absorb new Decision actions or become an excuse to rewrite the
integrated OCC lifecycle.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-007`
- [Graph waves, critical path, and parallelism](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
