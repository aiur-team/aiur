# DASH-010 — Normalize Claude Remote usage

**Kind:** executable

**Provenance:** planned in plan v1 after companion-boundary review

**Complexity:** 3 — Versioned Claude request-event mapping and exact trusted attribution onto a fixed envelope contract

**Risk:** high

**Phase hint:** 4

**Depends on:** DASH-008, DASH-019

**Serializes with:** none

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-010

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex`, `phase:4`, `build-lane:accounting`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Authenticated Claude REPL and Remote Control `claude_code.api_request` events
become exactly attributed DASH-008 usage/provider-cost envelopes with
deterministic identity, explicit coverage, and a pinned Claude relationship
revision that treats base input, cache creation, and cache read as additive
request dimensions.

## Context and evidence

Current HookTurn and Remote Control DisplayTailer paths do not provide authoritative request tokens/cost. DASH-019 separately owns the authenticated bounded local telemetry receiver and trusted process/session correlation. This ticket is the accounting adapter over that fixed transport, avoiding transcript, StatusLine, or `/usage` scraping.

Anthropic's [official pricing contract](https://docs.anthropic.com/en/docs/about-claude/pricing)
defines base input, cache creation, and cache read as distinct input categories
with separate prices, and defines API total input as `input_tokens +
cache_creation_input_tokens + cache_read_input_tokens`. That provider semantic
is durable evidence; the Claude Code OTel attribute names remain
source-versioned adapter evidence that must be refreshed at pickup.

## Scope

- Define a versioned allowlisted adapter for official structured `claude_code.api_request` events emitted by DASH-019.
- Map authenticated source identity, Claude session ID, event sequence/request
  ID, model, exact `cost_usd`, input/output/cache token fields, query source,
  effort, occurrence time, and source version into DASH-008 `UsageEnvelope`.
- For the currently evidenced telemetry revision, map its allowlisted base
  `input_tokens`, `cache_creation_tokens`, and `cache_read_tokens` attributes to
  raw base-input, cache-creation-input, and cached-input dimensions. Later
  source versions require a reviewed mapping and may use different attribute
  names. Pin the DASH-008 relationship revision that declares those three
  dimensions disjoint/additive for a request. A derived request total adds each
  once plus output; a structured provider total wins only if the exact source
  contract separately declares provider-total authority.
- Use DASH-019's trusted run, repository-qualified ticket, attempt, backend/transport, session, and worker-generation correlation. Reject an event when required correlation is absent or stale; never guess from session ID alone.
- Classify the source as request-scoped delta measurement and preserve raw supported dimensions. Exact monetary decoding must occur before binary float conversion.
- Derive deterministic envelope idempotency identity from official request/event identity plus authenticated producer/session generation. DASH-009 remains the sole durable deduplication owner.
- Cover Claude REPL, Remote Control, reconnect, resume, replacement attempt, and model/effort change. A resumed session retains attribution only when DASH-019 proves continuity.
- Emit bounded content-free coverage events for unsupported source or
  relationship revisions, missing required identity, ambiguous measurement
  semantics, and optional-field absence. Never fall back to Codex-style cache
  subset semantics.
- Ensure HookTurn, transcript, DisplayTailer, StatusLine, and browser state cannot create or alter accounting envelopes.

## Non-goals

- Implement or configure the local OTel receiver, capability/socket lifecycle, process/session registry, rate limiting, or sibling launch protocol; DASH-019 owns those.
- Persist/deduplicate envelopes, calculate prices, fetch Claude account meters, render UI, or treat Remote Control accounting as optional acceptance.
- Scrape `/usage`, terminal output, transcript, StatusLine, browser storage, credentials, or account pages.

## Existing owner and reuse target

Add a Claude OTel usage adapter beside existing Claude event normalizers. Consume DASH-019's authenticated allowlisted event/correlation contract and DASH-008's envelope builder, exact-money, validation, and redaction rules.

## Contract and invariants

- Only a DASH-019-authenticated, allowlisted event with trusted current-generation correlation can emit an envelope.
- Request/event identity plus producer/session generation is deterministic across exporter retry. Receipt time never replaces missing occurrence or source identity.
- `cost_usd` remains a provider-reported request estimate represented exactly; it is not billed spend or subscription allocation.
- Unsupported/partial/missing input is explicit coverage, never zero usage.
- Claude base input, cache creation, and cache read remain separate additive
  dimensions under the pinned relationship revision; no adapter consumer may
  relabel either cache dimension as a subset of base input.
- No raw content, account identity, endpoint capability, header, credential, path, or unrelated OTel attribute reaches an envelope, log, or error.

## Refreshable implementation notes

- Refresh the official Claude Code monitoring schema and the gate-approved DASH-019 source version at pickup; keep sanitized fixtures per source version.
- If official source identity is absent in an installed version, reject that version until a reviewed deterministic contract exists.
- Keep the adapter pure where possible: validate/allowlist, map correlation, classify, and produce an envelope or bounded error.

## Acceptance and verification

### Agent gate

- Fixture/property tests cover REPL and Remote Control, retry/replay, session
  resume, new attempt/generation, model/effort changes, nonzero base-input plus
  cache-creation plus cache-read dimensions, exact additive request totals,
  exact decimal cost, missing optional fields, unsupported source/relationship
  version, and unattributable events. One fixture proves base `100` + cache
  creation `20` + cache read `30` + output `10` yields `160`, not `110` or
  `130`.
- Integration tests prove trusted DASH-019 correlation reaches the correct run/ticket/attempt and stale/wrong generation cannot cross ticket boundaries.
- Negative tests prove HookTurn/DisplayTailer/transcript/StatusLine/browser data cannot affect totals and raw disallowed attributes are absent before publication/logging.

### At-merge gate

- Rebase on DASH-008/019 and current Claude lifecycle; run Claude REPL/Remote Control, telemetry-contract, correlation, usage-normalizer, exact-money, redaction, packaging, and full CI suites.

### Human/manual evidence

- From the Executor repository root, drive one synthetic-safe Claude REPL and
  one Remote Control request through the real DASH-019 path and show correctly
  attributed envelopes with stable identity and additive cache dimensions
  after reconnect, without displaying prompts or account identity.

## Failure, security, migration, and accessibility cases

- Malformed, unsupported, partial, or uncorrelated input produces bounded visible coverage failure and never fabricated/zero usage.
- Redact content, account/email/org, credentials, headers, capability values, environment values, and paths before logs, bug reports, envelope publication, or persistence.
- Version the source adapter and envelope/relationship mapping. Legacy
  uncovered runs remain uncovered rather than retroactively inferred.
- No direct UI. Coverage failures use stable human-readable source/adapter classes.

## Surfaces

- Reads: DASH-019 authenticated allowlisted Claude request events and trusted correlation; DASH-008 envelope contract.
- Writes: Claude request-event adapter, DASH-008 envelopes, coverage events, fixtures/tests.
- Contracts: required Claude REPL/Remote Control event-to-envelope accounting
  coverage and source-versioned additive base/cache-create/cache-read mapping.

## Sibling boundaries and open gates

DASH-019 owns the local transport and `GATE-003`. DASH-009 owns durability/deduplication, DASH-011 owns pricing/grouping, and DASH-013 owns Claude account meters. This ticket cannot weaken required Remote Control coverage to “unsupported.”

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-010`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
