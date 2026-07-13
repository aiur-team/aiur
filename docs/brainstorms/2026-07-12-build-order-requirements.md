---
date: 2026-07-12
topic: build-order-dashboard
---

# Build Order Dashboard Requirements

## Summary

Build Order gives an operator a truthful, selectable dependency view of one
bounded feature while Aiur executes it. GitHub remains authoritative for order
identity, current membership, ticket facts, lifecycle, planning metadata and
native blockers. Aiur contributes current activity, progress and event evidence
without being allowed to clear a GitHub dependency.

The Build Order implementation is fifteen tickets. Fifteen standalone dashboard
companions align Units, Commands, controls and usage/accounting with the
refreshed prototype; they are not Build Order members or completion blockers.
The split follows independently testable backend/protocol/browser boundaries,
not the opening ten-ticket estimate.

## Product decisions

- V1 reads only the configured GitHub repository and one direct-child order at
  a time, up to 100 members.
- Build Order does not mutate GitHub planning data. Existing Aiur runtime
  actions remain governed by their own authenticated writable/capability and
  acknowledgement contracts.
- GitHub and the active Aiur instance are the two live truth sources. Browser
  reconnect reads current cached snapshots and receives PubSub/LiveView pushes;
  GitHub polling remains daemon-owned and bounded.
- Flat-subscription dollars are versioned API-equivalent estimates, marked `*`
  with an accessible explanation and actual plan tier. They are not billed
  spend.
- Build totals include every retained Aiur observation for current member
  tickets, including observations from before membership.
- Claude REPL/Remote Control accounting is required standalone work, not an
  accepted unsupported state.
- Linear parity remains separate human-blocked issue #1067.

## Build Order requirements

### GitHub planning truth

- **BOREQ-001 — Selectable order identity.** Discover roots carrying exactly
  the controlled `build-order` role in the configured repository. Use GitHub
  node ID internally and repository/number in URLs; selecting one root never
  mixes another root's members.
- **BOREQ-002 — Direct membership and strict metadata.** Direct native
  sub-issues are the member set. Parse one `complexity:1..5`, positive
  `phase:N`, and controlled `build-lane:*`; member-local ambiguity renders
  Unphased/Unassigned/unknown plus warnings rather than hiding trustworthy
  ticket facts.
- **BOREQ-003 — Native blockers and conservative readiness.** GitHub native
  `blockedBy` is the only hard-edge truth. Edge/readiness states are `cleared`,
  `blocking`, `terminal_unsatisfied`, `unknown`, and `cyclic`; precedence is
  cyclic, unknown, terminal-unsatisfied, blocking, then ready. Only
  `CLOSED + COMPLETED` clears an edge.
- **BOREQ-004 — Complete provider generations.** Root catalog and selected
  graph have separate bounded paginated health domains. Publish complete
  validated candidates atomically, retain visibly stale last-known-good data,
  distinguish structural invalidity from provider failure, and never let one
  bad root hide the catalog.

### Aiur identity and runtime

- **BOREQ-005 — Trusted ticket identity.** Ticket-scoped lifecycle/events carry
  or resolve a repository-qualified tracker identity at a trusted boundary.
  Bare issue topics, display names and transient agent prose cannot be join
  keys.
- **BOREQ-006 — Shared activity projection.** A daemon-owned projection, not
  interactive AgentList state, retains running, queued, retrying, paused,
  completed, progress, stage, waiting and latest evidence with source/time and
  honest restart unknowns. AgentList migrates to the same contract.
- **BOREQ-007 — Pure planning/runtime join.** Compose immutable GitHub and Aiur
  snapshots without provider I/O, log parsing or guessed defaults. Planned
  phase, dependency readiness, GitHub outcome, execution state, agent stage and
  progress remain distinct fields.

### Browser and operator experience

- **BOREQ-008 — Real browser test infrastructure.** Establish deterministic
  LiveView/browser accessibility, interaction and performance fixtures before
  graph behavior depends on them, including 20/50/100-member and degraded
  graphs.
- **BOREQ-009 — Local layout platform.** Pin, audit and package a maintained
  layout-only engine and worker locally with no CDN/runtime dependency. Product
  state and semantic rendering remain Aiur-owned.
- **BOREQ-010 — Semantic DOM/SVG adapter.** Measure server-rendered cards,
  compute lane/phase-constrained coordinates and routed SVG edges off the main
  thread, discard stale generations, redraw after LiveView/font/theme/resize
  changes, and preserve a deterministic readable fallback.
- **BOREQ-011 — Reusable all-state ticket context.** Load bounded detail from
  cached providers only after selection. Show canonical GitHub navigation,
  upstream/downstream chips, available chat/command/runtime actions and
  partial/error states with correct focus trap/replacement/restoration.
- **BOREQ-012 — URL-backed minimum graph.** `/build-orders` and selected-root
  routes survive share/back/refresh and render loading, empty, unavailable,
  stale, invalid and cyclic states. Cards expose source-backed identity, title,
  metadata, lifecycle and progress provenance; bodies stay out of graph cards.
- **BOREQ-013 — Accessible relationship interaction.** Keyboard, pointer and
  touch selection persistently highlight upstream/downstream closure. Provide
  named pan/zoom/fit controls, accessible graph/edge summaries, visible focus,
  reduced motion and origin focus restoration.
- **BOREQ-014 — Responsive bounded scale.** The internal graph viewport may pan
  in two dimensions, but page controls never clip or hide. At 320px, 200% text
  zoom and 20/50/100 members, layout is off-main-thread, generation-safe and
  within documented budgets.
- **BOREQ-015 — Durable bounded acceptance.** Provider, parser, projection,
  presenter, TUI migration, assets, LiveView, browser, accessibility,
  degradation, performance, documentation and post-merge real-CLI/browser
  proof all have one capstone owner.

## Standalone dashboard requirements

These become standalone issues and do not belong to the Build Order root.

- **DREQ-001 — Responsive route shell.** URL-backed Units, Commands, Build
  Order and existing Analytics navigation; desktop/sidebar and mobile/bottom
  layouts, safe areas, theme, live status and `aria-current`; sequence after
  #1034 terminology work.
- **DREQ-002 — Canonical Units catalog.** Define current-run membership,
  terminal retention and a truth table for lifecycle scope
  Live/Unfinished/All/None plus overlapping Active/Alert/Paused/Stuck/Queued/
  Finished conditions; preserve provenance and waiting reasons.
- **DREQ-003 — Units presentation.** URL/count/zero-result filter behavior,
  exact backend/model/effort/complexity/lane/progress with unknowns, responsive
  table/cards and adoption of shared all-state ticket context.
- **DREQ-004 — Applied runtime-control protocol.** Pause/resume uses correlated
  request, accepted, worker-applied/rejected/expired facts with idempotency,
  conflict and audit semantics. Request acceptance is not worker confirmation.
- **DREQ-005 — Unit and capacity controls.** Authenticated capability-gated
  pause/resume and positive-integer max-agent UI waits for authoritative state,
  handles concurrency/timeouts/errors and uses named 44px controls.
- **DREQ-006 — Decision lookup and provenance.** Direct old-record lookup,
  bounded pagination/search, canonical source backend/model/confidence capture
  and migration. Never parse display prose or transient running-agent state.
- **DREQ-007 — Commands catch-up.** Apply current Commands vocabulary/cards/
  filters while preserving every Decision lifecycle, deep link, confirmation,
  retry, revision, follow-up, sanitization and partial-history state.
- **DREQ-008 — Provider-neutral usage envelope.** Normalize delta/absolute
  counters with time, scope, epoch/generation, source identity, raw absolute,
  derived delta, full/partial coverage, non-overlapping token semantics and
  exact decimal provider cost.
- **DREQ-009 — Durable attributed usage ledger.** Single-writer append-only
  NDJSON authority plus crash-safe checkpoints/aggregates survives restart,
  retry, fallback and completion while preserving grouping/coverage through
  compaction. It supersedes #132's storage/accounting portion and deliberately
  defers #845's database/BI program.
- **DREQ-010 — Remote Control accounting.** Ingest supported structured Claude
  Code request telemetry locally, correlate session to run/ticket/attempt,
  deduplicate and redact identity/content. The ticket cannot finish with
  `claude-repl` coverage unsupported.
- **DREQ-011 — Versioned cost/grouping projection.** Report tokens and
  separately labelled provider/API-equivalent estimate bases by run/build,
  ticket, agent family, backend and model with pricing revision, coverage and
  earliest retained time; never sum unlike bases.
- **DREQ-012 — Meter contract and Codex adapter.** Full snapshot versus sparse
  patch, tombstone/expiry, per-window freshness and account generation for
  subscription/API-key plan tier, quota/rate/credit values; extend structured
  Codex integration.
- **DREQ-013 — Claude plan-meter parity.** Provide structured Claude
  subscription and API-key account meters without interactive-output or
  credential scraping; protocol unavailability is an explicit external gate,
  not fabricated session/weekly bars.
- **DREQ-014 — Canonical current-run summary.** Define live/remaining universe,
  complexity-weighted progress with unknown denominator, wall-clock elapsed and
  evidence-based ETA with provenance/confidence/freshness.
- **DREQ-015 — Authenticated usage/run UI.** Compose live provider/run cards and
  ticket/model/backend/agent breakdowns from cached snapshots. Show estimate
  asterisks/popovers, actual tier, scope/basis/coverage/freshness, accessible
  meter semantics and locked financial values when unauthenticated.

## Acceptance examples

1. Two roots exist. Selecting the second updates the URL, survives refresh and
   never renders members from the first.
2. A blocker reports Aiur progress 100% but remains open in GitHub; its edge is
   still blocking and its dependent is not ready.
3. A blocker closes `NOT_PLANNED`; its edge becomes terminal-unsatisfied rather
   than cleared or actively blocking.
4. Dependency page two fails; the prior complete graph remains visibly stale
   and no disappeared edge makes work look ready.
5. One root is structurally invalid; other catalog roots remain selectable.
6. Aiur restarts without replayed progress; open-ticket progress is unknown
   while GitHub metadata remains visible.
7. A keyboard user selects a card, navigates dependency chips, closes context
   and returns focus to the originating card.
8. At 390px and 200% zoom, fixed navigation cannot obscure content and every
   unit action is at least 44px; only the graph viewport pans horizontally.
9. Subscription usage shows `$…*`, actual tier and an explanation that the
   value is an API-equivalent estimate, never billed spend.
10. A current Build Order member displays retained usage from before it joined,
    while a removed ticket no longer contributes to the selected-build total.

## Non-goals

- GitHub planning mutation, Linear, cross-repository or nested orders in v1.
- More than 100 direct members or a ticket in multiple orders.
- Phase as a global execution barrier or Aiur progress as dependency outcome.
- Prototype fake data, fixed coordinates, client-only state, mouse-only cards,
  Analytics placeholder, minimap or in-graph editing.
- Postgres/multi-controller BI, subscription fee allocation, budgets/alerts or
  opencode TUI accounting surfaces in the companion program.
- Letting companion/reliability/optimization work change Build Order completion.

## Evidence

- `docs/build-order/design-manifest.md`
- `docs/build-order/06-prototype-capability-audit.md`
- `docs/build-order/03-source-of-truth-and-state.md`
- `docs/build-order/04-usage-accounting.md`
- GitHub schema/API research confirmed native parent/sub-issue and
  blocker/dependent relationships, plus the 100-direct-child limit.
- Maintained layout-engine and Claude Code telemetry sources are linked in the
  technical decision and accounting documents.
