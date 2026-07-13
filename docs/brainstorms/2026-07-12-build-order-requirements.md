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

The Build Order implementation is nineteen tickets. Thirty-four standalone
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
- A compatible-currency API-equivalent run/build total may span Codex, Claude
  and multiple account generations, but must preserve every contributor and
  never synthesize a cross-generation tier or mix monetary bases.
- Build totals include every retained Aiur observation for current member
  tickets, including observations from before membership.
- Claude REPL/Remote Control accounting is required standalone work, not an
  accepted unsupported state.
- Linear parity remains separate human-blocked issue #1067.
- No implementation dispatch begins until the configured integration branch is
  proven to contain the completed OCC baseline and the bounded Executor skill
  revision from PR #1065 commit
  `afd9828c61005a84ee316e3b2c995c0122b896ff` (or a reviewed compatible
  successor) is installed. These gates do not enter the feature denominator.

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
  table/cards and adoption of shared all-state ticket context. Row activation
  opens ticket context only; the named Chat conversation destination is owned
  by DREQ-027 and runtime capacity control by DREQ-028.
- **DREQ-004 — Applied runtime-control protocol.** Pause/resume uses correlated
  request, accepted, worker-applied/rejected/expired facts with idempotency,
  conflict and audit semantics. Request acceptance is not worker confirmation.
- **DREQ-005 — Applied unit controls.** Authenticated capability-gated
  pause/resume UI waits for authoritative worker-applied state, handles
  concurrency/timeouts/errors and uses named 44px controls. Positive-integer
  max-agent capacity UI is DREQ-028.
- **DREQ-006 — Complete Decision lookup.** Direct old-record lookup, bounded
  cursor pagination/search and complete retained counts remain separate from
  the priority overview and preserve sanitization/provider failure semantics.
- **DREQ-007 — Commands catch-up.** Apply current Commands vocabulary/cards/
  filters while preserving every Decision lifecycle, deep link, confirmation,
  retry, revision, follow-up, sanitization and partial-history state.
- **DREQ-008 — Provider-neutral usage envelope.** Define the provider-neutral
  `UsageEnvelope` schema and registry, consuming the shared opaque
  provider-account generation: raw delta/absolute measurements carry trusted
  occurrence time, UTC occurrence-price date, scope, independent counter
  epoch, source identity, full/partial coverage, currency and exact decimal
  provider cost. Own a versioned per-provider/source registry that classifies
  token dimensions as additive, subset, mutually exclusive, or unknown and
  declares provider-total authority. Unknown or contradictory relationships
  fail closed, and no ephemeral producer derives cross-message deltas. The
  Codex/Claude headless source adapters are DREQ-029.
- **DREQ-009 — Durable attributed usage ledger.** A single-writer append-only
  NDJSON authority plus crash-safe absolute-counter checkpoints survives
  restart, retry, fallback and completion. The writer alone derives deltas from
  absolute counters, preserves source version and pinned token-relationship
  revision unchanged in canonical records and replayed deltas, and owns
  deterministic replay; bounded aggregate queries and retention/compaction are
  separate consumers. This supersedes #132's storage/accounting portion and
  deliberately defers #845's database/BI program.
- **DREQ-010 — Remote Control usage normalization.** Convert authenticated,
  correlated Claude Code request telemetry into exact provider-neutral usage
  envelopes without scraping interactive output. Map Claude base input,
  cache-creation input, and cache-read input as separate additive request
  dimensions under the exact supported source version. The required Remote
  Control path cannot finish with `claude-repl` coverage unsupported.
- **DREQ-011 — Exact usage pricing.** Resolve exact versioned effective-dated
  token prices and reconcile each billable dimension according to the DREQ-008
  relationship contract: additive dimensions contribute separately, subset
  dimensions replace the matching parent slice rather than double count it,
  and unknown/contradictory relationships produce unknown API-equivalent
  coverage. Use exact decimal/currency arithmetic, never mix currencies or
  provider-reported and API-equivalent bases, and expose a
  generation-qualified tier join key without joining meter data. Run/ticket/
  build grouping and roll-ups are DREQ-030; meter joining remains a
  presentation-composition responsibility.
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
- **DREQ-015 — Authenticated provider-meter UI.** Compose live Codex and
  Claude provider-meter cards from cached snapshots with plan/quota/rate/reset
  facts, per-window freshness/LKG states and accessible meter semantics;
  render unknown, mixed and mismatch account-generation states explicitly.
  Consume DREQ-021 so no account-meter fact is available to an
  unauthenticated connection. The usage/cost summary, breakdowns and
  drill-down are DREQ-031.
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
  creating a second membership store, supplying the member set as an explicit
  typed scope to the DREQ-030 grouped query and composing on the DREQ-031
  summary contract. On membership-generation changes, push recomputed totals
  that include retained pre-membership observations for current members,
  exclude removed members, preserve coverage/health, and reconcile the
  compatible-currency API-equivalent build total to its provider,
  account-generation, ticket, model and agent-family contributors.
- **DREQ-024 — Crash-safe usage aggregate/query projection.** Project the
  append-only ledger into bounded, atomically published grouping snapshots and
  exact caller-supplied run/ticket queries. Preserve every pricing, currency,
  token-relationship-revision, account-generation, attribution and coverage
  dimension through restart and replay without scanning the ledger per browser;
  distinct or unknown relationship revisions never merge.
- **DREQ-025 — Usage retention and compaction.** Rotate and compact the durable
  store under configurable limits while preserving the dimensions required to
  reproduce retained aggregates, earliest-retained coverage and audit/replay
  behavior, including exact separation of known/unknown token-relationship
  revisions. Crash recovery, corruption quarantine and deterministic proof are
  part of this storage lifecycle.
- **DREQ-026 — Bounded live conversation projection.** Project allowlisted
  structured runtime conversation events into a versioned, bounded, sanitized
  `LiveConversationSnapshot` keyed by exact configured-repository identity
  plus run/attempt/session/worker generation. Only allowlisted normalized
  fields enter a snapshot — raw JSON, prompts, reasoning, credentials,
  capability URLs and local paths are forbidden — and bounds/redaction apply
  before retention. Live, ended, known-empty, stale, unavailable and
  restart-unknown source states stay distinct, and snapshot queries perform no
  workspace, log-file, process or provider I/O.
- **DREQ-027 — Read-only conversation drawer.** Provide an explicit named
  `Read conversation` Units action that opens a responsive,
  keyboard-accessible, read-only drawer over the exact DREQ-026 snapshot with
  focus trap, Escape/close behavior and deterministic focus return. The drawer
  contains no message, pause, capacity or mutation handler; ticket context and
  conversation remain separate destinations, and rendering performs no
  filesystem, log, process, GitHub or provider read. Generation identity is
  pinned while open, so a replacement worker's conversation never silently
  appears under the old heading.
- **DREQ-028 — Authoritative runtime capacity control.** Render and mutate
  positive-integer max-agent capacity only through the existing authoritative
  Orchestrator Slots contract, with named controls that recheck auth/writable
  state on every invocation. The Orchestrator-returned snapshot alone proves
  application — a requested value or dashboard-local row count never does —
  and lowering capacity drains dispatch without pausing, resuming or killing
  any individual unit. Pending, applied, invalid, unavailable,
  concurrent-change and draining states remain visibly and programmatically
  distinct.
- **DREQ-029 — Headless usage source adapters.** Normalize every supported
  Codex and Claude headless protocol source into exactly attributed DREQ-008
  usage envelopes during normal runs, preserving true counter scope, source
  version, account generation and pinned token-relationship revision. Each
  accepted source event produces at most one raw envelope identity; a source
  revision never falls forward to a newer mapping, and unknown version, scope,
  model, generation or attribution stays explicit rather than becoming zero or
  a guess. Emission is daemon-owned and independent of dashboard clients, TUI
  mode or debug telemetry, and provider payloads are dropped after
  normalization.
- **DREQ-030 — Grouped usage scopes.** Expose bounded, exact, scope-labelled
  token and estimate summaries for caller-supplied `this_run` and/or explicit
  configured-repository ticket-set scopes over the DREQ-024 aggregates and
  DREQ-011 pricing. Every value preserves scope, basis, currency, generation,
  pricing/relationship revisions, attribution coverage and retained interval;
  roll-up arithmetic is exact, reconciles in both directions and never
  combines unlike bases or currencies. Tier-join keys exist only for exact
  known provider/backend/account generations, and the projection never
  discovers, retains or mutates Build Order membership.
- **DREQ-031 — Authenticated usage/cost summary UI.** Render live token and
  API-equivalent estimate totals for `this run` or an explicit selected-build
  scope, reconciled by ticket, provider, agent family, backend, model,
  currency and account generation with truthful coverage and bounded
  accessible drill-down. Subscription estimates always carry `*` with an
  accessible explanation, tier annotations join only on exact known
  generations, and unlike bases/currencies remain separate with unknown cost
  never shown as `$0.00`. All delivery flows through the DREQ-021 protected
  facade so denied connections receive no protected value anywhere, including
  hidden DOM, assigns, events or caches.
- **DREQ-032 — Truthful current-run outcomes.** Project a bounded current-run
  outcome snapshot containing only repository merges associated with an exact
  current-run member through canonical branch-derived ticket locators, unique
  membership resolution and merge time inside the canonical run window.
  `observed_run_id` is observation provenance only — never a join key or
  causality evidence — and backfilled and live-observed facts use identical
  qualification rules. Partial or unavailable sources never produce a
  confidently complete empty list, and a new run generation cannot inherit
  prior outcomes.
- **DREQ-033 — Existing-dashboard parity capstone.** Prove the composed
  Executor Control Center end to end — shell, Units, conversations, controls,
  Commands, run/provider/accounting summaries, Recent outcomes,
  authentication, accessibility and responsive layouts — on one exact
  configured integration SHA with real CLI/browser operator-visible evidence.
  Failed prerequisite acceptance routes back to the owning ticket as contained
  rework and nonblocking discoveries go to the deferred ledger; current
  Fleet/Decision/Recent/Analytics behavior is preserved or explicitly replaced
  by an accepted tested contract.
- **DREQ-034 — Current-run Recent UI.** Render the `Finished this run` region
  from DREQ-032 qualified outcomes only, describing cards as repository merges
  associated with current-run member tickets without claiming Aiur or agent
  authorship or causality. Presentation never recomputes membership, window
  qualification or branch linkage, and the global RecentMerge audit, complete
  Decision history and real Analytics destination remain available on their
  proper surfaces. Healthy-empty, partial, stale, unavailable, restart/new-run
  and truncated states render explicitly.

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
