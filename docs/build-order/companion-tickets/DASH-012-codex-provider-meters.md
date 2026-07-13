# DASH-012 — Normalize Codex account meters

**Kind:** executable

**Provenance:** planned in plan v1 after provider-meter adversarial review

**Complexity:** 4 — Versioned snapshot/patch semantics and structured Codex account integration

**Risk:** high

**Depends on:** DASH-008

**Serializes with:** Codex account/rate-limit protocol and `ModelAvailability` integration changes

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-012

**Researched at:** `1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur exposes a redacted, versioned Codex provider-meter projection in
DASH-008's shared opaque provider-account namespace that truthfully represents
subscription and API-key account modes, multiple quota/rate windows, plan tier,
sparse updates, reset times, freshness, and health without treating scheduling
fallback as financial truth.

## Context and evidence

Codex supplies structured account/rate-limit data, including the current `account/rateLimits/read` path, but current availability state is optimized for scheduling and may collapse windows or provider identity. The refreshed prototype requires session and weekly meters plus account-mode-specific presentation. API-key accounts do not necessarily have subscription session/weekly windows and must not receive fabricated bars.

## Scope

- Define a versioned `ProviderMeterSnapshot` keyed by provider/backend and DASH-008's exact opaque `provider_account_generation`, with auth mode, plan/tier and source, update kind (`snapshot` or `patch`), observed/ingested times, source/version, health, and windows keyed by stable `limit_id`.
- Define each window/control with kind, name, used/remaining percent or absolute limit where actually reported, duration, reset time, credit/spend-control facts, source, observed time, expiry, and support/coverage state. Preserve multiple arbitrary limit IDs rather than hard-coding only primary/secondary.
- Define update semantics: a full snapshot is authoritative for its account generation and tombstones previously known windows absent from that full snapshot; a patch changes only supplied windows; an explicit tombstone removes one window. Failure never acts as an empty snapshot.
- Consume the sole DASH-008 account-generation owner. The Codex adapter reports trusted login/logout/credential/account-binding lifecycle changes to that owner and uses the returned generation for both usage and meter output; it must not mint a meter-only generation. Never merge last-known-good windows across generations or accounts, and do not persist raw account identity to accomplish this.
- Ingest current structured Codex camelCase schemas, subscription/ChatGPT windows, API-key/rate/credit controls when exposed, reset times, and plan tier. Retain per-window last-known-good state with independent freshness/expiry and projection health.
- Provide snapshot/lookup/change APIs and a migration/compatibility feed for scheduling availability. `ModelAvailability` may consume a conservative subset but is not the canonical financial/quota store.
- Strip email, account/organization/project IDs, credentials, API/OAuth material, raw responses, endpoint/capability URLs, and unrelated account fields at ingestion.

## Non-goals

- Attribute usage to tickets, ingest token/cost observations, call organization billing APIs, calculate spend, render cards, or scrape Codex CLI/TUI/credential/browser output.
- Fabricate session/weekly windows, credits, or unlimited quota for API-key accounts when the structured source does not report them.
- Use one provider's update to overwrite another provider or
  `provider_account_generation`, or substitute a quota reset/projection version
  for the shared account generation.

## Existing owner and reuse target

Extend the Codex account/rate-limit protocol client/normalizer and add a dedicated provider-meter projection. Reuse protocol versioning, app-server lifecycle, trusted auth-mode detection, health/PubSub patterns, and DASH-008's provider-account-generation owner. Treat `Aiur.ModelAvailability` as a compatibility consumer only.

## Contract and invariants

- Snapshot, patch, tombstone, failure, stale, unsupported, and empty-supported are distinct states.
- Provider, backend, exact opaque `provider_account_generation`, and limit ID
  are part of identity. Sparse updates cannot delete unrelated windows; full
  snapshots cannot leave removed windows alive.
- Freshness/expiry is per window/control and also summarized at projection level. Failed fetch preserves stale last-known-good facts with their original observation time.
- Subscription and API-key modes use only fields supported for that mode. Unsupported/unknown is not zero usage, full availability, or an empty healthy meter.
- Only allowlisted numeric/enumerated/plan facts cross the provider boundary; plan tier includes source/freshness and is not inferred from token usage.
- Plan/tier and every quota fact are correlated only to their exact known
  provider-account generation. Unknown generation is explicit and cannot be
  joined to known-generation usage by provider/backend alone.

## Refreshable implementation notes

- Capture sanitized fixtures from the installed Codex schema at pickup, including multiple limit IDs and known 300-minute/10,080-minute windows, but do not make those durations the only allowed contract.
- Wire trusted Codex process/auth lifecycle into DASH-008's shared generation
  owner. Do not derive, increment, or persist a second meter-local generation,
  email/account ID, or stable public account fingerprint.
- Keep provider fetch cadence daemon-owned and shared across browser clients; no LiveView fetches.

## Acceptance and verification

### Agent gate

- Fixture/property tests cover camelCase normalization, multiple/arbitrary IDs, full snapshot removal, sparse patch, explicit tombstone, shared usage/meter generation, account-generation change, quota reset without account rotation, subscription and API-key modes, reset/credit fields, per-window stale/expiry, failure/recovery, and provider isolation.
- Migration tests preserve conservative scheduling behavior while proving `ModelAvailability` cannot overwrite or masquerade as canonical meter data.
- Security tests prove all account/email/org/project/credential/raw-response/capability fields are dropped before projection/logging.

### At-merge gate

- Rebase on DASH-008 and current Codex protocol work; run shared-generation,
  account/rate-limit fixture, app-server lifecycle, availability compatibility,
  provider projection, redaction, packaging, and full CI suites.

### Human/manual evidence

- Using synthetic/redacted fixtures or safe local accounts, compare a subscription snapshot and API-key snapshot and show that only supported windows/controls appear, account changes do not merge, and no identity is exposed.

## Failure, security, migration, and accessibility cases

- Protocol drift, timeout, auth change, and malformed updates preserve safe last-known-good data with health/freshness or clear it only through a valid new generation/full snapshot.
- Never persist/log credentials, raw responses, email/account/org/project identity, environment values, or capability URLs.
- Version normalized snapshots and migrate current availability input without dual canonical writers.
- No direct UI; window/control names, reset semantics, coverage, and health are human-readable for DASH-015.

## Surfaces

- Reads: structured Codex account/rate-limit protocol, trusted auth/process
  lifecycle, and DASH-008's shared opaque provider-account-generation contract.
- Writes: provider-meter schema/projection, Codex adapter, health/PubSub, availability compatibility, fixtures/tests.
- Contracts: snapshot/patch/tombstone semantics, shared opaque account
  generation consumption, per-window freshness, subscription/API-key truth.

## Sibling boundaries and open gates

DASH-008 is the sole owner of the opaque account-generation namespace.
DASH-013 implements Claude against this meter contract, and DASH-015 renders
both. DASH-011 exposes a generation-qualified usage key but does not ingest or
join meter data; DASH-015 owns the exact-generation tier composition.
