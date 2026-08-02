# BO: DASH-029 — Normalize headless usage sources

**Kind:** executable

**Provenance:** planned in plan v1 after the shipped-dashboard capability re-audit

**Complexity:** 3 — Two version-pinned provider adapters over one established envelope contract

**Risk:** high

**Phase hint:** 4

**Depends on:** DASH-008, BO-017, DASH-018

**Serializes with:** BO-005 — shared agent-event ingestion and normalization seams

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-029

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-terra`, `phase:4`, `build-lane:accounting`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Every supported Codex and Claude headless protocol source emits a faithful,
exactly attributed DASH-008 `UsageEnvelope` during normal runs, with its true
counter scope, source version, account generation, relationship revision, and
coverage preserved without transient or browser-owned accounting.

## Context and evidence

DASH-008 originally combined the provider-neutral schema and relationship
registry with both provider adapters. Those are different review boundaries:
the contract must remain stable while installed Codex and Claude protocols
drift independently. Current Aiur already folds some headless usage into
running rows, but that fold is transient and does not retain completed-ticket,
retry, fallback, or restart attribution. Claude Remote Control remains the
separate DASH-010 path.

## Scope

- Characterize the exact installed Codex and Claude headless event revisions
  at pickup with synthetic, redacted fixtures and explicit source-version
  identifiers.
- Map supported Codex cumulative thread updates, turn completions, cache and
  reasoning dimensions to DASH-008 without treating overlapping absolute and
  delta streams as independently additive.
- Map supported Claude headless request/turn completion usage and structured
  provider-estimated cost to DASH-008, preserving its request scope and exact
  decimal representation.
- Consume trusted run, repository, ticket, attempt, session, backend, requested
  model, resolved model, effort, auth-mode, counter-epoch, and DASH-018 account-
  generation context already ordered by DASH-008's prerequisites. Missing
  attribution remains missing and cannot be recovered from prose or paths.
- Select only a registry entry whose provider, source, and source version match
  exactly. Pin that relationship revision on the envelope; unsupported or
  ambiguous versions emit bounded coverage evidence rather than current-version
  semantics.
- Preserve provider source event IDs, sequence/order, occurrence time, update
  kind, measurement kind, counter scope, reset evidence, and raw normalized
  dimensions. Do not derive a cross-message delta in either adapter.
- Emit during normal headless runs regardless of dashboard clients, TUI mode,
  or `--debug`; keep existing transient token consumers working through a thin
  compatibility adapter until their planned migration lands.
- Drop provider payloads after normalization and publish only validated,
  redacted envelopes or bounded rejection/coverage reasons.

## Non-goals

- Define the envelope or token-relationship registry, mint account generation,
  persist observations, derive durable deltas, aggregate, price, compact, query,
  or render usage.
- Ingest Claude Remote Control/REPL telemetry, own the OTLP transport, or expose
  provider account meters; DASH-010, DASH-019, and DASH-012/013/020 own those
  paths.
- Scrape transcripts, interactive output, status lines, workspaces, prompts,
  provider dashboards, or billing pages.

## Existing owner and reuse target

Extend the current Codex/Claude message-normalization boundaries around
`AgentRunner.MessageHandler` and the trusted BO-017 identity propagation
consumed by DASH-008. Reuse DASH-008 validation and relationship lookup rather
than embedding provider-specific schema in the ledger or UI.

## Contract and invariants

- Each accepted source event produces at most one raw envelope identity.
  Absolute and delta streams retain their distinct source/scopes so DASH-009
  alone can decide durable additive deltas.
- A source revision never falls forward to a newer mapping. Unknown version,
  relationship, scope, occurrence time, model, generation, or attribution is
  explicit and never becomes zero or a guessed identity.
- Provider cost is decoded as exact decimal/integer minor units before any
  float conversion. Raw payload, prompt, output, credentials, PII, and local
  paths never enter the envelope or diagnostics.
- Normal-run emission is daemon-owned and independent of browser count,
  presentation state, or debug telemetry.

## Refreshable implementation notes

- Capture protocol fixtures from the installed adapters at pickup; do not
  assume the planning-time event names remain current.
- Keep one module per provider/source revision behind a narrow adapter behavior
  so protocol drift does not rewrite the provider-neutral contract.
- Prefer deterministic event/source IDs and injected clocks. Do not use sleeps
  to test ordering, retries, or resets.

## Acceptance and verification

### Agent gate

- Fixture/property tests cover Codex thread absolutes and turn deltas, Claude
  request deltas/cost, duplicates, out-of-order records, partial patches,
  counter reset, account rotation, retry/new attempt, session resume, model/
  backend fallback, and source-version drift.
- Relationship tests prove Claude additive cache dimensions and supported
  Codex subset dimensions pin the exact registry revision; unknown revisions
  cannot publish a canonical derived total or pricing input.
- Attribution/security tests prove typed repository collisions, missing trusted
  identity, exact-decimal cost, normal-run emission, compatibility projection,
  and complete payload/credential/path redaction.

### At-merge gate

- Rebase on DASH-008 and its BO-017/DASH-018 prerequisites, serialize shared
  normalizer work with BO-005, and pass provider protocol, MessageHandler,
  transient-token compatibility, security, and full CI suites.

### Human/manual evidence

- Record sanitized synthetic envelopes from one real Codex and one real Claude
  headless turn, showing exact source revision, scope, identity, relationship
  revision, and coverage without exposing raw provider content.

## Failure, security, migration, and accessibility cases

- Malformed, ambiguous, unsupported, or unattributable events fail closed to a
  bounded reason without crashing the worker or silently dropping healthy
  events from the other provider.
- Never persist or log prompts, transcripts, output, provider bodies, account/
  organization identity, credentials, environment values, capability URLs, or
  workspace paths.
- Version every adapter and fixture. Existing transient consumers receive an
  explicit compatibility projection until their migration; no UI is owned.

## Surfaces

- Reads: supported Codex/Claude headless protocol events; DASH-008 envelope,
  registry, and trusted attribution/account-generation contracts.
- Writes: versioned provider normalizers, envelope publication, compatibility
  projection, redacted fixtures, and tests.
- Contracts: exact source-to-envelope mappings and normal-run emission.
- Safety: provider payload redaction and agent-event ingestion seam.

## Sibling boundaries and open gates

DASH-008 owns the stable provider-neutral contract; DASH-009 owns durable
delta/replay; DASH-010 owns Remote Control; DASH-011/030 own pricing/grouping;
and DASH-012/013/020 own account meters. This ticket owns only the two headless
source adapters.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-029`
- [Graph waves, critical path, and parallelism](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
