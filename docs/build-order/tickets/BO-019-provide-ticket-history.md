# BO-019 — Provide bounded recent ticket history

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Bounded structured history projection with sanitization, freshness, and restart semantics

**Risk:** high

**Phase hint:** 4

**Depends on:** BO-005

**Serializes with:** BO-003, BO-016, DASH-002, DASH-009, DASH-012, DASH-018, DASH-019, DASH-024, DASH-025, DASH-026 — application supervision tree

**Requirements:** BOREQ-006, BOREQ-011

**Decisions:** DEC-001, DEC-006

**Design evidence:** DESIGN-001

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-sol`, `phase:4`, `build-lane:plan-graph`; never `agent:todo`

## Outcome

A daemon-owned provider supplies configured-repository current progress, latest
safe evidence, and bounded recent structured activity/history with explicit
freshness, restart, missing, known-empty, stale, and unavailable states.

## Context and evidence

The prototype's Logs area implies recent activity beyond one latest event.
LiveView must not tail or parse `agent.md`, NDJSON, terminal output, or raw model
transcripts. BO-005 owns current event-derived activity but not a bounded recent
timeline. Existing structured event and IssueLog seams are the supported source
for a reusable provider that BO-018 can render without I/O.

## Scope

- Define a snapshot keyed by BO-005/BO-004 configured-repository identity with
  current progress/source/time, latest safe evidence, ordered recent entries,
  source health, generation, and observation/freshness metadata.
- Consume BO-005 current activity plus supported typed event and IssueLog APIs.
  Use normalized fields only; never parse raw log files, markdown transcripts,
  NDJSON text, terminal panes, or arbitrary model output in LiveView.
- Normalize an allowlisted set of safe event kinds into concise timestamped
  entries with source/attempt/session provenance when available.
- Bound timelines to a configurable default 50 entries and hard maximum 100,
  with deterministic newest-retention, ordering, deduplication, and pagination/
  truncation indication.
- Distinguish `available`, `known_empty`, `missing_source`, `stale`,
  `unavailable`, and `restart_unknown`. Absence never becomes `0%` or a
  fabricated no-activity claim.
- Publish immutable monotonic snapshots/notifications after current activity or
  supported structured history changes; bound retained identities and sanitize
  before storage/publication.
- Document restart behavior for in-memory activity and whatever durable
  guarantees the supported IssueLog API actually provides; never claim replay
  beyond that contract.

## Non-goals

- Parse raw logs/transcripts in LiveView, expose full prompts/tool output, or
  create a general log-search system.
- Re-own BO-005 current activity, StatusReport lifecycle, ticket detail, usage/
  spend accounting, or UI rendering.
- Infer repository identity, progress, or latest evidence from prose.

## Existing owner and reuse target

Compose BO-005 snapshots with supported structured `Aiur.EventBus`/IssueLog
query seams and existing redaction/event vocabulary. Keep the provider
supervised/headless-safe; LiveView is only a subscriber/consumer.

## Contract and invariants

- Identity is the exact configured-repository key from BO-005/BO-004. Other
  repositories and unqualified records are rejected/nonjoinable.
- Timeline entries are allowlisted, typed, bounded, ordered, deduplicated, and
  sanitized before retention. Raw log text is never an input contract.
- `known_empty` requires a healthy authoritative query; missing/unavailable/
  restart state cannot be collapsed into empty.
- Progress/latest preserve source, observed time, and freshness. History never
  changes GitHub lifecycle/readiness or financial totals.
- Restart and source degradation remain visible; no snapshot invents continuity.

## Refreshable implementation notes

- Reinspect BO-005, event bus, IssueLog structured APIs, retention/redaction,
  supervision, and PubSub seams at pickup. If IssueLog lacks a supported typed
  query, expose `missing_source` rather than parsing files.
- Reconcile application supervision edits with BO-003 and BO-016 before
  overlapping branches merge.
- Use injected clocks and deterministic barriers; avoid sleep/poll tests.
- Keep the provider query/snapshot API small enough for BO-018 to render without
  knowing storage mechanics.

## Acceptance and verification

### Agent gate

- Tests cover default 50/hard 100 bounds, lower config, invalid config,
  ordering, duplicate IDs, late events, attempts, truncation, sanitization,
  current progress/latest composition, and configured-repository collisions.
- State tests cover healthy empty, missing source, stale, unavailable,
  restart-unknown, recovery, subscriber churn, and retained-identity eviction.
- Negative tests prove no raw markdown/NDJSON/file/terminal parsing, prompts,
  model output, credentials, local paths, or other-repository records enter the
  timeline.

### At-merge gate

- BO-005, structured event/IssueLog, provider/supervision/PubSub, security,
  compile/lint/spec, and repository CI pass on the configured integration
  branch.
- BO-018 consumes snapshots only and performs no log I/O.

### Human/manual evidence

- None separately; BO-015 proves bounded Logs rendering from live structured
  activity and explicit missing/restart states.

## Failure, security, migration, and accessibility cases

- Allowlist/sanitize before retention; never expose secrets, prompts, raw
  output, capability URLs, account identity, private bodies, or local paths.
- No new durable migration unless the selected supported IssueLog seam already
  requires one; document actual restart guarantees.
- Every state and entry kind includes concise accessible non-color text.

## Surfaces

- Reads: BO-005 configured-repository activity; supported typed event and
  IssueLog query APIs; injected clock/configuration.
- Writes: TicketHistoryProvider snapshots/PubSub; bounded allowlist,
  sanitization, freshness/restart, retention, and tests.
- Safety: structured activity-history privacy and application supervision tree.
- Contracts: bounded recent history; progress/latest projection; available/
  empty/missing/stale/unavailable/restart states.

## Sibling boundaries and open gates

BO-005 owns current activity, BO-017 owns event envelopes, BO-018 renders the
base context/Logs timeline, and usage companions own financial events. This
ticket must report a missing structured history source rather than bypass it
with raw-log parsing. BO-003 and BO-016 share only the application supervision
tree with this ticket and serialize on that seam.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-019`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
