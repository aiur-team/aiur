# DASH-007 — Project provider account meters

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Multi-provider subscription/API account normalization

**Risk:** high

**Depends on:** none

**Requirements:** DREQ-007

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur exposes independent Codex and Claude account-meter snapshots for subscription and API-token modes, preserving multiple quota windows, reset times, sparse updates, plan/auth mode, health, freshness, and explicit unsupported coverage.

## Context and evidence

Codex already supports structured `account/rateLimits/read`, but current state collapses provider windows and can overwrite one provider. Headless Claude exposes usage/cost but no complete structured quota method; direct Remote Control coverage is also incomplete. Unsupported must remain visible, not scraped or zeroed.

## Scope

- Normalize agent family/backend/auth mode/plan type, multiple limit IDs/windows, used percent, duration, reset time, credits/spend control, source/version, observed time, and health.
- Preserve Codex primary/secondary and arbitrary sparse multi-limit updates including camelCase schema fields; merge by provider+limit ID into LKG snapshots.
- Support subscription and API-key layouts without fabricating session/weekly bars for API accounts.
- Represent Claude/Remote Control supported, partial, unsupported, stale, and error states; make any cross-repository adapter change an explicit external gate.
- Redact account emails/IDs, credentials, raw responses, OAuth/API material, and capability URLs at ingestion.

## Non-goals

- Attribute usage to tickets, compute cost totals, scrape CLI status/credential/browser/transcript content, or render summary cards.
- Conflate scheduling availability fallback with financial/quota truth.

## Existing owner and reuse target

Extend the Codex account/rate-limit integration and add a dedicated provider-meter projection. `Aiur.ModelAvailability` may supply migration input but is not the canonical meter store.

## Contract and invariants

- Sparse updates merge without deleting unrelated windows; fetch failure preserves stale LKG with health.
- Different providers and limit IDs cannot overwrite each other.
- Unsupported/partial/error is not zero consumption or unlimited quota.
- Only normalized numeric/plan facts survive the provider boundary.

## Refreshable implementation notes

- Refresh installed Codex/aiur-claude schemas at pickup; protocol drift is expected.
- If complete Claude quota needs sibling-repo work, record a human/external gate and ship explicit unsupported state rather than blocking Codex.

## Acceptance and verification

### Agent gate

- Fixtures cover Codex camelCase, multiple IDs, 300/10080-minute windows, sparse merge, ChatGPT/API-key modes, reset/credits, stale/error/recovery, Claude unsupported/partial, RC incomplete, and redaction.
- Migration tests preserve current availability fallback without treating it as meter truth.

### At-merge gate

- Provider protocol/projection/security and full current-base CI pass, including sibling protocol compatibility when authorized.

### Human/manual evidence

- Operator verifies subscription and API-key accounts show different truthful meter layouts without exposed identity.

## Failure, security, migration, and accessibility cases

- Never persist/log credentials, emails, account IDs, raw responses, or capability URLs.
- Version normalized schema and preserve LKG through upgrade.
- No direct UI; output includes named windows and reset semantics.

## Surfaces

- Reads: structured Codex/Claude account and rate-limit protocols.
- Writes: provider meter LKG snapshots and health.
- Contracts: ProviderMeterSnapshot and coverage states.

## Sibling boundaries and open gates

DASH-008 renders meters. DASH-005/006 own ticket usage/cost. Unsupported Claude coverage does not block Build Order.

