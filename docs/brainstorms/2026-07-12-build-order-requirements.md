---
date: 2026-07-12
topic: build-order-dashboard
---

# Build Order Dashboard Requirements

## Summary

Build Order gives an Executor a truthful, selectable dependency view of one
bounded feature while Aiur executes it. GitHub remains authoritative for order
identity, current membership, ticket facts, lifecycle, planning metadata and
native blockers. Aiur contributes current activity, progress and event evidence
without being allowed to clear a GitHub dependency.

The Build Order implementation is nineteen tickets. Twenty-five standalone
dashboard companions align Units, Commands, controls and usage/accounting with
the refreshed prototype; they are not Build Order members or completion
blockers.
The split follows independently testable backend/protocol/browser boundaries,
not the opening ten-ticket estimate.

## Product decisions

- V1 reads only the configured GitHub repository and one direct-child order at
  a time, up to 100 members.
- Build Order does not mutate GitHub planning data or invoke mutating Aiur
  runtime actions. Existing actions remain governed by their own authenticated
  destination surfaces and acknowledgement contracts.
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
- No implementation dispatch begins until the configured integration branch is
  proven to contain the completed OCC baseline and the bounded Executor skill
  revision from PR #1065 commit `a9a2142f` (or a reviewed compatible successor)
  is installed. These gates do not enter the feature denominator.

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
- **BOREQ-004 — Complete bounded provider generations.** Root catalog and
  selected graph have separate bounded paginated health domains. The catalog
  defaults to at most 100 roots and enforces explicit page and provider-call
  ceilings; selected roots retain GitHub's 100-direct-member limit. Detect the
  bound-plus-one case instead of truncating. Publish complete validated
  candidates atomically, retain visibly stale last-known-good data, distinguish
  structural invalidity from provider failure, and never let one bad root hide
  the catalog. Default catalog and selected-root freshness are 60 and 15
  seconds; selection/reconnect coalesces a refresh when the demanded snapshot
  is older than 5 seconds. All bounds and intervals are configurable.

### Aiur identity and runtime

- **BOREQ-005 — Trusted ticket identity.** Ticket-scoped lifecycle/events carry
  or resolve a repository-qualified tracker identity at a trusted boundary.
  Bare issue topics, display names and transient agent prose cannot be join
  keys.
- **BOREQ-006 — Shared typed runtime inputs.** Existing daemon-owned
  StatusReport remains canonical for running, queued, retrying, paused,
  waiting, backend/model and worker lifecycle. A separate daemon-owned
  projection, not interactive AgentList state, retains progress, active stage,
  and latest safe cross-ticket evidence with source/time and honest restart
  unknowns. Both use the same trusted identity; AgentList migrates only its
  duplicate event-derived fold.
- **BOREQ-007 — Pure planning/runtime join.** Compose immutable GitHub and Aiur
  snapshots without provider I/O, log parsing or guessed defaults. Planned
  phase, dependency readiness, GitHub outcome, execution state, agent stage and
  progress remain distinct fields.

### Browser and Executor experience

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
- **BOREQ-011 — Reusable all-state ticket context.** Provide root-independent,
  repository-qualified, bounded on-demand ticket detail, sanitized recent
  activity history, caching, and an accessible base context for any typed
  configured-repository ticket. Adapt that base to selected Build Order
  upstream/downstream relationships, diagnostics, and truthful read-only
  GitHub, chat and Commands destinations. Cached progress/evidence, bounded
  Logs history, destination availability, partial/error states and focus
  trap/replacement/restoration remain explicit. Build Order itself exposes no
  mutating runtime action in v1 and rejects a different repository before I/O.
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

- **DREQ-001 — Responsive route shell.** After the shared BO-008 real-route
  browser harness exists, provide URL-backed Units, Commands, Build
  Order and existing Analytics navigation; desktop/sidebar and mobile/bottom
  layouts, safe areas, theme, live status and `aria-current`; sequence after
  #1034 terminology work.
- **DREQ-002 — Recoverable current-run membership.** Journal and project every
  typed ticket identity observed in the active run, retain terminal membership
  through that run, and rebuild the exact same-run set after a projection crash
  without turning event activity into a lifecycle owner or retaining prior-run
  history.
- **DREQ-003 — Units presentation.** URL/count/zero-result filter behavior,
  exact backend/model/effort/complexity/lane/progress with unknowns, responsive
  table/cards and adoption of shared all-state ticket context.
- **DREQ-004 — Applied runtime-control protocol.** Pause/resume uses correlated
  request, accepted, worker-applied/rejected/expired facts with idempotency,
  conflict and audit semantics. Request acceptance is not worker confirmation.
- **DREQ-005 — Unit and capacity controls.** Authenticated capability-gated
  pause/resume and positive-integer max-agent UI waits for authoritative state,
  handles concurrency/timeouts/errors and uses named 44px controls.
- **DREQ-006 — Complete Decision lookup.** Direct old-record lookup, bounded
  cursor pagination/search and complete retained counts remain separate from
  the priority overview and preserve sanitization/provider failure semantics.
- **DREQ-007 — Commands catch-up.** Apply current Commands vocabulary/cards/
  filters while preserving every Decision lifecycle, deep link, confirmation,
  retry, revision, follow-up, sanitization and partial-history state.
- **DREQ-008 — Provider-neutral usage envelope.** Consume the shared opaque
  provider-account generation and normalize raw delta/absolute
  measurements with trusted occurrence time, UTC occurrence-price date, scope,
  independent counter epoch, source identity, full/partial
  coverage, non-overlapping token semantics, currency and exact decimal
  provider cost. Do not derive cross-message deltas in an ephemeral producer.
- **DREQ-009 — Durable attributed usage ledger.** A single-writer append-only
  NDJSON authority plus crash-safe absolute-counter checkpoints survives
  restart, retry, fallback and completion. The writer alone derives deltas from
  absolute counters and owns deterministic replay; bounded aggregate queries
  and retention/compaction are separate consumers. This supersedes #132's
  storage/accounting portion and deliberately defers #845's database/BI
  program.
- **DREQ-010 — Remote Control usage normalization.** Convert authenticated,
  correlated Claude Code request telemetry into exact provider-neutral usage
  envelopes without scraping interactive output. The required Remote Control
  path cannot finish with `claude-repl` coverage unsupported.
- **DREQ-011 — Versioned cost/grouping projection.** Consume the crash-safe
  aggregate/query projection and report tokens and
  separately labelled provider/API-equivalent estimate bases by run/build,
  ticket, agent family, backend, exact model, currency and opaque account
  generation with occurrence-time pricing revision, coverage and earliest
  retained time; never sum unlike bases, currencies or generations. Meter
  joining remains a presentation-composition responsibility.
- **DREQ-012 — Provider-meter foundation.** Consuming the shared opaque
  provider-account generation, define full snapshot versus sparse patch,
  tombstone/expiry, per-window freshness/LKG and subscription/API-key
  plan/quota/rate/credit coverage without embedding either provider adapter.
- **DREQ-013 — Claude plan-meter parity.** Provide structured Claude
  subscription and API-key account meters without interactive-output or
  credential scraping; protocol unavailability is an explicit external gate,
  not fabricated session/weekly bars. The human-owned source/authority gate
  resolves before worker dispatch.
- **DREQ-014 — Canonical current-run summary.** Define live/remaining universe,
  complexity-weighted progress with unknown denominator, wall-clock elapsed and
  evidence-based ETA with provenance/confidence/freshness.
- **DREQ-015 — Authenticated usage/provider UI.** Compose live provider cards
  and ticket/model/backend/agent breakdowns from cached snapshots. Join usage to an
  actual plan tier only by provider, backend and exact known opaque account
  generation; render unknown, mixed and mismatch states explicitly. Show
  estimate asterisks/popovers, scope/basis/currency/coverage/freshness and
  accessible meter semantics, consuming DREQ-021 so no usage/account-meter fact
  is available to an unauthenticated connection.
- **DREQ-016 — Units row and filter policy.** Join recoverable membership with
  canonical lifecycle and event activity into provenance-rich rows; define
  Live/Unfinished/All/None scope plus overlapping Active/Alert/Paused/Stuck/
  Queued/Finished predicates, counts and a versioned URL codec as pure APIs.
- **DREQ-017 — Trusted Decision provenance.** Version and migrate optional
  backend/requested-model/resolved-model/session/attempt provenance from
  trusted runtime paths. Reuse the existing persisted supervising confidence
  scale unchanged (`0..100`) and let Commands present it; legacy and
  human-authored provenance remain unknown.
- **DREQ-018 — Opaque provider-account generation.** One trusted provider/auth
  lifecycle owner mints a random, non-derivable generation shared by usage and
  meter adapters, rotates it on account-binding changes or lost continuity, and
  keeps it distinct from resettable counter epochs and quota resets.
- **DREQ-019 — Authenticated local telemetry transport.** Provide a bounded,
  permissioned local OTLP receiver and trusted Claude session-to-run/ticket/
  attempt correlation with replay/rate controls, redaction-before-logging and a
  human-owned protocol-authority gate for any required sibling change.
- **DREQ-020 — Codex provider-meter adapter.** Normalize supported structured
  Codex subscription/API-key account, plan, limit, reset, credit and spend facts
  into DREQ-012, keep `ModelAvailability` a conservative compatibility consumer,
  and expose no account identity or fabricated window.
- **DREQ-021 — Enforced financial-data boundary.** Only an authenticated,
  enforced dashboard connection may query, subscribe to, cache, assign, emit or
  render usage, cost or provider-account facts; unlocked local mode receives a
  value-free named locked state while nonfinancial run facts remain available.
- **DREQ-022 — Accessible run-summary UI.** Render DREQ-014 live/remaining/
  terminal counts, weighted progress coverage, wall elapsed and evidence-based
  ETA independently of usage/provider availability, with truthful unavailable
  states, responsive semantics and pushed updates.
- **DREQ-023 — Selected-Build-Order usage integration.** Join the URL-selected
  root's current GitHub member identities to retained Aiur usage without
  creating a second membership store. On membership-generation changes, push
  recomputed totals that include retained pre-membership observations for
  current members, exclude removed members, and preserve coverage/health.
- **DREQ-024 — Crash-safe usage aggregate/query projection.** Project the
  append-only ledger into bounded, atomically published grouping snapshots and
  exact caller-supplied run/ticket queries. Preserve every pricing, currency,
  account-generation, attribution and coverage dimension through restart and
  replay without scanning the ledger per browser.
- **DREQ-025 — Usage retention and compaction.** Rotate and compact the durable
  store under configurable limits while preserving the dimensions required to
  reproduce retained aggregates, earliest-retained coverage and audit/replay
  behavior. Crash recovery, corruption quarantine and deterministic proof are
  part of this storage lifecycle.

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
9. Subscription usage with an exact account-generation match shows `$…*`, its
   actual tier and an explanation that the value is an API-equivalent estimate,
   never billed spend; unknown, mixed or mismatched generations do not guess a
   tier.
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
