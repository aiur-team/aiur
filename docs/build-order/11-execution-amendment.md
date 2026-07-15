# DEC-015 — Build Order execution amendment

**Status:** authorized by the operator's 2026-07-15 Executor directive; inert
until its uniquely marked GitHub comments and execution receipt validate.

**Scope:** execution ownership, integration, and acceptance-tail consolidation
only. This amendment does not add, remove, supersede, or rename a feature
ticket. The approved publication remains the immutable authority for ticket
bodies and the native dependency graph.

## Immutable baseline

This amendment is layered on publication receipt
`b8db1794c57ba01bd724cc44b8d4ee6de0b79cad` and preserves:

- exactly 54 direct members;
- exactly 105 internal native `blockedBy` edges;
- member fingerprint
  `f8ea55d2c600ece7a4f09b2d264a47b33b4bfd564ded089cf6c959b3deece9f6`;
- edge fingerprint
  `07ac5dd8fa9fb28b2bfd89d7f0b363fd9f738d3a95425640bec7b08de87d0a3b`;
- ticket/GitHub mapping fingerprint
  `d93ada2652581418e7299412c301e4db21e8350158ca5cdd8102668654eef974`;
- the 20 BO and 34 DASH ticket titles, approved bodies, complexity, model,
  phase-hint, and build-lane routing metadata; and
- BO-015 as the sole root-closure capstone.

`10-late-wave-consolidation.md` remains the research record. This document is
the binding correction and enactment. In particular, it rejects that draft's
suggestions to create five coordination issues, add lane labels, or carry one
stale long-lived branch. Existing tickets remain the evidence units and the
five existing anchor tickets coordinate ownership.

## Current-`develop` execution contract

The following paragraph is additive to every remaining ticket contract:

> Start from the current `origin/develop` tip recorded at dispatch and target
> `develop`. The Build Order staging decision and configured base branch
> override generic `main` wording. Before CI handoff, the worker—not the
> reviewer—integrates current `develop`, proves the pushed head descends from
> it, runs compile/format plus the contract's focused tests, and pushes one
> coherent head. Review begins only on that exact current head with fresh CI.
> Full-suite CI is centralized; do not loop locally on the full suite or ask a
> reviewer to repair a stale branch.

Additional binding rules:

1. One worker owns one ticket or one declared lane integration head. Every
   owned file and shared seam has one writer at a time.
2. A lane may land a small number of coherent PRs. After each squash merge,
   the owner refreshes or recuts from exact current `develop`; a branch may not
   carry an unchanged stale base through the lane.
3. Preserve every per-ticket agent acceptance assertion. Collapse repeated
   rebase, full-CI, browser, and manual tails to one class-complete lane packet;
   close each member only when its own evidence is recorded.
4. The worker performs one coherent self-review before PR handoff. The
   Executor does not review a head behind `develop` and does not repair a
   worker's stale branch for it.
5. One consolidated recovery packet and one bounded repair attempt are the
   default. Long-running, repeatedly restarted, ownerless, non-shrinking, or
   stale-base work may be taken over directly under the Executor policy landed
   by PR #1183; catastrophic Aiur failure is not required.
6. Phase is presentation metadata. Dispatch critical-path work first, then
   earlier ready work, and only use a deeper-phase ticket when all higher-value
   work is genuinely blocked and the file/seam budget permits it.
7. Generic stability fixes land in `main`; immediately merge that exact tip
   into `develop`. Feature review and dispatch stop while `main` is not an
   ancestor of `develop`.
8. Intermediate feature PRs use focused acceptance and fresh centralized CI.
   The complete `develop` head receives the single comprehensive review, full
   suite, browser proof, and real CLI/TUI acceptance before promotion.

## Reopened acceptance seam

BO-016/#1103 is reopened because the merged snapshot exposes only an Issue URL
and cannot satisfy the operator's separately modeled **Issue** and **Pull
request** destinations. BO-016 owns the root-independent, configured-repository
detail provider and its distinct optional Issue/PR links. BO-018 consumes those
links in the accessible base ticket context, and BO-011 composes them into
Build Order relationship context. No consumer performs its own GitHub fetch.
The existing BO-016 → BO-018 native edge provides the gate; no graph edit is
required.

The refreshed design is preserved at
`prototype/Aiur Operator Control Center.2026-07-13-refresh.html` and supplies
the complexity-weighted phase-progress reference. The immutable DESIGN-001
artifact remains at its approved canonical path. Analytics remains excluded.

## Individually owned pre-lane contracts

These nineteen tickets retain individual ownership. The corrections below are
additive implementation anchors; they do not replace their acceptance
matrices.

| Ticket | Binding correction |
|---|---|
| BO-003 | Extend the shipped `GitHubGraph` catalog/selected-root and `TicketDetailCache` Configuration/Policy patterns plus `Config.Schema.BuildOrder`; do not create a parallel graph schema or cache. |
| BO-005 | Project content-free `TicketObservation` metadata through `Events.Exchange`, keyed by `TrackerIdentity`; use `CurrentRunMembership` as projection/PubSub precedent and never expose the raw event message. |
| BO-006 | Consume BO-005's exact public snapshot/subscription API. Move activity ownership without removing the debug ticker, `RenderState`, selection, completed-runner, replacement, or status behavior. |
| BO-016 | Extend the merged detail provider with separately modeled Issue and Pull-request destinations; configured-repository identity is mandatory and consumers perform no I/O. |
| BO-019 | Use only `IssueLog.event_history/2` plus typed Exchange events. Forbid transcript-bearing history APIs and add typed known-empty versus unavailable state. |
| DASH-001 | Consume the shipped `src/browser` Playwright/axe harness. Own the responsive route registry/shell; later Build Order work only registers through its seam. |
| DASH-007 | Consume current `DecisionProvider.list/2`, `detail/2`, and `counts/1`; do not rebuild retained queries or refactor `DecisionStore`. |
| DASH-008 | Publish one copyable `UsageEnvelope` and relationship registry contract. Bind a trusted provider-account generation; reject decoded floats in exact-money paths. |
| DASH-009 | Follow `DecisionLog`, `JsonStore`, and `CurrentRunMembership.Store/Recovery/Paths`; own a dedicated usage state directory and the exact append/ack/replay API DASH-024 consumes. |
| DASH-010 | Remains gated on DASH-008, DASH-019, and GATE-003. Own mapping only, not transport or correlation, and use sanitized pinned fixtures without a Claude turn. |
| DASH-011 | Keep pricing pure in `Aiur.Usage.Pricing`/`PriceTable`; use string-valued prices, exact effective-date boundaries, and pickup-time source provenance. No ledger, provider, LiveView, or supervision writes. |
| DASH-012 | Extend the merged `ProviderAccountGeneration` APIs; never add a second generation owner. Own pure meter reconciliation plus one store/PubSub child placed immediately after that owner. |
| DASH-013 | Remains behind DASH-012 and GATE-004. Serialize Claude adapter/protocol writes with DASH-029 and any transport selected by the gate; use synthetic fixtures and no Claude tokens. This is not a new native edge. |
| DASH-016 | Consume `CurrentRunMembership.snapshot/1`, `TrackerIdentity`, the current presenter, and BO-005 activity. Normalize trusted URLs once and never join on a bare issue number. |
| DASH-019 | Recreate from `develop`. Own a dashboard-independent loopback OTLP receiver, launch wiring, correlation registry, and child placement before Orchestrator. Inject REPL capability with a non-logging tmux environment API. |
| DASH-020 | Extend the shipped Codex account-generation/rate-limit/session APIs and their allowlist. Correlate account generation before meter emission; do not own raw cost/token ingestion. |
| DASH-021 | Own a server-side financial policy, protected query/cache/PubSub facade, and `on_mount` contract. Publish a content-free capability assign; do not compose `DashboardLive`. |
| DASH-026 | Qualify both ordinary and queued `MessageHandler` paths with `TrackerIdentity`, run, attempt, session, and worker/containment generation. Serialize after BO-005 and before DASH-029; register before Orchestrator. |
| DASH-029 | Treat BO-017 as a pattern, not automatic financial qualification. Attach full trusted identity/generation context and serialize after DASH-026. GATE-004 must preserve Claude exact decimals before JavaScript float conversion. |

Initial safe fan-out is BO-003, BO-005, DASH-001, and DASH-008. The next fan-out
is BO-006/BO-019, DASH-007, DASH-009, DASH-011, DASH-012, DASH-016, and
DASH-021 as their native blockers and single-writer seams clear. DASH-010,
DASH-013, and later Claude meter presentation remain gated; their delay must
not idle unrelated ready streams.

## Five-lane late execution overlay

The lane mapping fingerprint is
`5082c48efb2a41f5935f0b6c6ba20a05304c1c20edd3ed049c58b86704a6fdcd`.
The mapping uniquely partitions exactly 23 existing tickets:

| Lane / anchor | Members | Sole-writer boundary and corrections |
|---|---|---|
| L1 — Build Order graph surface / BO-007 | BO-007, BO-011, BO-012, BO-013, BO-014, BO-020, DASH-023 | One dedicated `BuildOrderLive` vertical and namespaced CSS/harness surface. Extend shipped Graph/EdgeState/Readiness/Icon contracts; BO-011 waits for reopened BO-016 via BO-018; BO-013/014 consume the shipped browser harness and one focus hook; BO-020 consumes the versioned refreshed design; DASH-023 consumes accounting contracts and completes all existing blockers. |
| L2 — Companion operator dashboard / BO-018 | BO-018, DASH-003, DASH-005, DASH-015, DASH-022, DASH-027, DASH-028, DASH-031, DASH-034 | Sole writer for `DashboardLive`, OCC CSS/components, and the shared focus hook. BO-018 performs no provider I/O; DASH-005 consumes final DASH-004 applied controls; DASH-022 may land before gated financial panels; DASH-027 reuses the hook; DASH-028 consumes authoritative Slots APIs; DASH-015/031 remain protocol-gated; DASH-034 remains a root member. |
| L3 — Runtime run-state projections / DASH-014 | DASH-014, DASH-032 | Pure projections plus one runtime child. DASH-032 is a locator/index consumer, not a second merge ledger. Preserve semantic `child_specs/1` ordering. |
| L4 — Usage storage/query / DASH-024 | DASH-024, DASH-025, DASH-030 | Accounting modules plus one accounting child. DASH-024 consumes DASH-009's state-dir/store API; DASH-025 follows validated durable coverage; DASH-030 is a pure grouped query and adds no extra top-level child. |
| L5 — Convergence capstone / BO-015 | DASH-033, BO-015 | Consume the shipped harness and all lane evidence; do not own new harness configuration. DASH-033 is a root member. BO-015 validates execution state through this amendment rather than requiring the original all-open publication state. |

There are eighteen concrete cross-lane edges in eight dependency categories;
do not describe them as eight edges. A native hard blocker must be merged and
closed before its blocked consumer starts—an unmerged branch is not evidence.
L1/L2 share a CSS seam, L1/L2 touch `layouts.ex`, and the browser harness has
central files: the lane packet names one integration-seam owner at a time.
L2 waits for DASH-001, DASH-007, and DASH-021 where their public seams are
consumed. L3 and L4 each append one reserved child in semantic order; the
Executor sequences those two app-tree merges. Undefined `claims_to_verify`
references from the research draft carry no authority.

## Claude gates without Claude-token spend

- **GATE-003:** static evidence is sufficient for the operator to ratify the
  loopback OTLP/auth/correlation architecture using Claude Code 2.1.210 and
  `aiur-claude@0f4bea8`. Acceptance uses synthetic transport fixtures. No
  Claude execution is required.
- **GATE-004:** remains unresolved. The sibling declares
  `rate_limit_event` but does not forward it, and current JSON parsing converts
  cost through a JavaScript `Number`. One operator-authorized Codex revision in
  the sibling must both forward a sanitized structured rate-limit event and
  preserve the exact decimal/source version before float conversion. The gate
  records that protocol; it does not create another Build Order member.

No DASH-019 → DASH-013 native edge is added. If GATE-004 later selects a
DASH-019-owned transport, the Executor must explicitly revise the graph to 106
edges rather than hiding that change in serialization metadata.

## Receipt and live reconciliation

Before dispatch:

1. Validate the immutable publication statically at zero errors/warnings.
2. Commit this amendment and preserve the refreshed design at its versioned
   path.
3. Record one uniquely marked DEC-015 authorization comment on root #1084.
4. Record one deterministic current-`develop` amendment comment on every
   remaining issue. Lane anchors receive the full owner packet; followers
   receive a pointer to the anchor packet. Do not edit immutable ticket bodies.
5. Reopen BO-016, clear stale lifecycle labels, and leave every remaining
   ticket undispatched.
6. Materialize `execution-amendment.json` with exact comment URLs, authors,
   hashes, immutable fingerprints, and the amendment commit.
7. Run the execution validator against two stable GitHub snapshots. It must
   accept normal open/closed-completed lifecycle evolution while rejecting
   membership, edge, mapping, title, body, static-label, comment, or trusted-ref
   drift.
8. Verify `main` ancestry, `develop` push CI, configured base branch, Codex-only
   routing, and a fresh prewarm image before adding any `agent:todo` label.

The five lane anchors are BO-007/#1095, BO-018/#1105,
DASH-014/#1120, DASH-024/#1128, and BO-015/#1102. No coordination issue or
lane label is created.
