# BO: DASH-012 — Project canonical provider meters

**Kind:** executable

**Provenance:** planned in plan v1 after companion-boundary review

**Complexity:** 3 — One versioned snapshot/patch/LKG contract with account-generation isolation and health semantics

**Risk:** high

**Phase hint:** 2

**Depends on:** DASH-018

**Serializes with:** BO-003, BO-005, BO-016, BO-019, DASH-002, DASH-009, DASH-019, DASH-024, DASH-025, DASH-026 — application supervision tree

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-012

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-terra`, `phase:2`, `build-lane:accounting`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Aiur exposes one provider-neutral, redacted `ProviderMeterSnapshot` projection with account-generation isolation, arbitrary windows/controls, sparse-update semantics, per-field freshness, last-known-good retention, health, and bounded change APIs.

## Context and evidence

Provider account meters differ from request usage and scheduling availability. Codex and Claude both need the same rules for full snapshots, patches, tombstones, stale values, auth modes, and privacy-safe account correlation. This ticket establishes that public contract once; DASH-020 and DASH-013 implement provider adapters in parallel.

## Scope

- Define a versioned `ProviderMeterSnapshot` keyed by provider, backend, and DASH-018 opaque `provider_account_generation`.
- Include auth mode, optional plan/tier with source/freshness, update kind (`snapshot`, `patch`, or tombstone), observed/ingested times, source/version, projection health, and windows keyed by stable `limit_id`.
- Define each window/control with kind, human name, reported used/remaining percentage or absolute limit, duration, reset time, credit/spend-control facts, source, observed time, expiry, and support/coverage state.
- Preserve arbitrary limit IDs rather than hard-coding session/weekly. Subscription and API-key modes expose only supported facts.
- Define update semantics: a full snapshot is authoritative for one exact account generation and tombstones omitted prior windows; a patch changes only supplied windows; an explicit tombstone removes one; failure never acts as empty.
- Retain per-window last-known-good state with independent freshness/expiry and generation-safe projection health. Never merge values across provider/backend/account generation.
- Expose adapter ingestion, snapshot/lookup, generation, health/freshness, and bounded PubSub change APIs. Provider polling/subscription is daemon-owned, not browser-owned.
- Allow provider adapters to supply only allowlisted numeric/enumerated/plan facts. Reject or strip account/email/org/project/credential/raw payload/capability fields before projection.

## Non-goals

- Implement Codex or Claude protocol adapters, mutate `ModelAvailability`, attribute ticket usage, calculate spend, join usage to tier, render cards, or call organization billing APIs.
- Fabricate session/weekly/API windows, treat unsupported as zero/unlimited, or let one provider update another.
- Mint or infer account generation; DASH-018 is the sole owner.

## Existing owner and reuse target

Add a dedicated provider-meter behavior/projection using DASH-018 identity and existing daemon health, PubSub, clock, and last-known-good patterns. Keep `Aiur.ModelAvailability` and provider protocol modules as future consumers/adapters, not canonical owners.

## Contract and invariants

- Snapshot, patch, tombstone, failure, stale, partial, unsupported, and empty-supported are distinct.
- Provider, backend, exact known account generation, and stable limit ID are identity. Sparse updates cannot delete unrelated windows; full snapshots cannot leave removed windows alive.
- Freshness/expiry is per window/control and summarized at projection level. Failure preserves only same-generation LKG with original observation time.
- Unknown generation cannot join known-generation usage or inherit another generation's facts.
- Only allowlisted content-free values cross the boundary; plan/tier is source-backed and never inferred from usage or scheduling fallback.

## Refreshable implementation notes

- Refresh current health/PubSub/LKG conventions at pickup and keep adapter input as a strict typed boundary.
- Model arbitrary windows and controls first; use 300-minute/10,080-minute examples only as fixtures.
- Keep pure update/reconciliation policy separate from the supervised store so full/patch/tombstone properties are deterministic.
- Reconcile the central application supervision tree with every declared
  serialization peer before either overlapping branch executes or merges.

## Acceptance and verification

### Agent gate

- Property tests cover arbitrary limit IDs, full-snapshot removal, sparse patch, tombstone, duplicate/out-of-order update, per-window stale/expiry, failure/recovery, unknown generation, account rotation, and provider/backend isolation.
- Mode tests prove unsupported subscription/API facts remain unsupported rather than zero, empty, or unlimited.
- Security tests prove account/email/org/project/credential/raw-response/header/capability/content fields are rejected before state, PubSub, or logging.

### At-merge gate

- Rebase on DASH-018 and the resolved configured integration target; run generation lifecycle, projection/LKG/PubSub, schema/property, redaction, packaging, and full CI suites.

### Human/manual evidence

- With synthetic fixtures, show independent full and patch updates, stale LKG, account rotation isolation, and subscription/API capability differences without using real account identity.

## Failure, security, migration, and accessibility cases

- Malformed/provider failure preserves safe same-generation LKG with explicit health or begins empty for a new generation; it never presents fabricated healthy values.
- Never persist/log raw provider responses, account/email/org/project identity, credentials, environment values, or capability URLs.
- Version normalized snapshots and update semantics so adapters can migrate independently.
- No direct UI. Window/control names, bounds, resets, coverage, freshness, and health have human-readable fields for DASH-015.

## Surfaces

- Reads: DASH-018 provider-account generation and typed adapter updates.
- Writes: provider-meter schema/behavior/projection, LKG/health/PubSub, tests.
- Contracts: `ProviderMeterSnapshot`, update/tombstone semantics, per-window freshness and account isolation.
- Safety: account-generation isolation, provider redaction, and the application
  supervision tree.

## Sibling boundaries and open gates

DASH-020 implements Codex and scheduling compatibility; DASH-013 implements
Claude behind its human gate. DASH-021 protects query/subscription access, and
DASH-015 performs the only exact-generation usage/tier composition. The
declared serialization peers share only the central application supervision
tree and gain no provider-meter dependency.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-012`
- [Graph waves, critical path, and parallelism](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
