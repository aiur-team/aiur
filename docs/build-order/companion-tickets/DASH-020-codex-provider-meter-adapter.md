# BO: DASH-020 — Normalize Codex account meters

**Kind:** executable

**Provenance:** planned in plan v1 after companion-boundary review

**Complexity:** 3 — Structured Codex protocol integration plus conservative scheduling compatibility

**Risk:** high

**Phase hint:** 3

**Depends on:** DASH-012

**Serializes with:** none

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-020

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-terra`, `phase:3`, `build-lane:accounting`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Structured Codex account/rate-limit data produces generation-scoped DASH-012 snapshots for subscription and API-key modes, while existing scheduling availability remains conservative and cannot masquerade as canonical financial/quota truth.

## Context and evidence

Codex exposes structured `account/rateLimits/read` data, but `ModelAvailability` is optimized for scheduling and may collapse windows or identity. The prototype needs actual supported session/weekly or API controls and plan tier. DASH-012 supplies the provider-neutral projection; this ticket owns only Codex protocol mapping and compatibility.

## Scope

- Consume current structured Codex camelCase account/rate-limit schemas and normalize provider/backend, auth mode, plan/tier and source, arbitrary windows/limit IDs, used/remaining facts, duration/reset, API credit/rate/spend controls, source version, and observation time into DASH-012 updates.
- Report trusted Codex login/logout/credential/account-binding lifecycle through DASH-018 and use the returned generation for every adapter update. Never mint a Codex-local meter generation.
- Correctly classify full snapshots, sparse patches, and explicit removals according to actual protocol semantics; provider failure is not an empty snapshot.
- Support subscription/ChatGPT and API-key modes without fabricating fields absent from the structured source.
- Add sanitized fixtures for installed and compatible protocol versions, including multiple arbitrary limit IDs and unknown new fields.
- Provide a migration/compatibility feed for `ModelAvailability`. Scheduling may consume a conservative subset but cannot overwrite DASH-012 or be queried as the canonical meter.
- Strip account/email/org/project/credential/API/OAuth/raw response/header/endpoint/capability fields before adapter output or logging.

## Non-goals

- Define provider-meter semantics, attribute usage, calculate spend, render cards, scrape CLI/TUI/browser/credential output, or call organization billing APIs.
- Fabricate session/weekly windows, credits, unlimited quota, or plan tier for API accounts.
- Let `ModelAvailability` become a second meter writer or use quota reset as account rotation.

## Existing owner and reuse target

Extend the Codex account/rate-limit client and normalizer, app-server lifecycle, trusted auth-mode detection, DASH-018 lifecycle adapter, and `ModelAvailability` compatibility boundary. Emit only DASH-012 typed updates.

## Contract and invariants

- Every meter update carries current DASH-018 generation or explicit unknown; account/provider generations never merge.
- Codex source semantics determine full/patch/tombstone classification. Failure preserves LKG through DASH-012 rather than deleting facts.
- Subscription and API-key modes expose only structured supported facts. Unknown/unsupported is not zero or unlimited.
- Plan/tier includes source/freshness and is never inferred from tokens or scheduling state.
- `ModelAvailability` may derive conservative scheduling state but cannot write or override canonical meter facts.

## Refreshable implementation notes

- Capture sanitized fixtures from the installed Codex protocol at pickup and record source method/version and update semantics.
- Keep camelCase/source-version parsing in a thin adapter; reuse DASH-012 validation/update policy rather than duplicating it.
- Preserve current rate-limit fallback behavior through characterization tests before moving its input seam.

## Acceptance and verification

### Agent gate

- Fixture/property tests cover camelCase normalization, arbitrary/multiple IDs, full removal, sparse patch, tombstone, subscription/API modes, reset/credit fields, unknown fields, protocol drift, failure/recovery, and account rotation.
- Lifecycle tests prove usage and meter consumers receive the same DASH-018 generation and quota/counter reset does not rotate it.
- Compatibility tests preserve conservative scheduling behavior while proving `ModelAvailability` cannot overwrite or impersonate DASH-012.
- Security tests prove forbidden account/credential/raw-response/capability fields are removed before projection/logging.

### At-merge gate

- Rebase on DASH-012 and current Codex protocol work; run provider-meter, shared-generation, account/rate-limit fixture, app-server lifecycle, availability compatibility, redaction, packaging, and full CI suites.

### Human/manual evidence

- Using synthetic/redacted fixtures or safe local accounts, compare subscription and API-key snapshots, show only supported controls, rotate the account binding, and confirm scheduling compatibility without exposing identity.

## Failure, security, migration, and accessibility cases

- Protocol drift, timeout, malformed update, and auth change yield explicit adapter/projection health; only a valid new generation/full snapshot clears same-generation LKG.
- Never persist/log credentials, raw responses, account/email/org/project identity, environment values, or capability URLs.
- Version adapter fixtures/mapping and migrate availability input without dual canonical writers.
- No direct UI. Supported facts and adapter coverage use DASH-012's human-readable vocabulary.

## Surfaces

- Reads: structured Codex account/rate-limit protocol, trusted auth/process lifecycle, DASH-012 contract.
- Writes: Codex meter adapter, DASH-018 lifecycle observations, `ModelAvailability` compatibility feed, fixtures/tests.
- Contracts: Codex subscription/API parity on `ProviderMeterSnapshot` and conservative scheduling compatibility.

## Sibling boundaries and open gates

DASH-012 owns the generic projection and DASH-018 owns account identity. DASH-013 can proceed in parallel from DASH-012; DASH-015 consumes both adapters only through DASH-021's protected boundary.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-020`
- [Graph waves, critical path, and parallelism](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
