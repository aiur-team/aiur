---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
date: 2026-10-01
---

# Refresh Stale Codex Usage Before Blocking the Fleet - Plan

## Summary

Aiur's model-usage ledger (`~/.aiur/model-usage.json`) can become stale after a provider resets usage quotas. When this happens, cached limits from before the reset persist and block dispatch indefinitely, even though the provider has capacity. This plan adds automatic probing of the provider's authenticated usage endpoint when a cached limit is stale or after a reset, distinguishes fresh from stale readings in status output, and ensures ready dispatch resumes without manual ledger editing.

---

## Problem Frame

**Context:** In run `khala-sol-20260927`, all Codex fallback workers were declared usage-limited and the fleet stayed at 0/16 agents even after the operator reset Codex tokens. The active `~/.aiur/model-usage.json` still showed Codex weekly `used=100/limit=100`, but a fresh `codex app-server --stdio` `account/rateLimits/read` reported weekly `usedPercent=4` with no active rate limit. A manual one-entry atomic refresh from the provider response immediately resumed ticket workers.

**Failure modes:**
- Cached limit persists across provider reset; operator has no way to refresh without manual file edits
- No observable distinction between fresh provider-confirmed limit and stale cached limit
- Stale readings block dispatch silently with no visibility into when the next refresh will occur
- Manual workaround required; no automatic recovery

**Expected Behavior:**
- Probe provider's authenticated usage endpoint when cached limit is stale
- Retry bounded probes on failure; retain last-known-good reading if probe fails
- Distinguish fresh vs stale in status output with observation time and next probe time
- Restore dispatch as soon as provider confirms new capacity after reset

---

## Requirements

**R1. Detect stale usage limits.** Track observation time for each cached usage entry. Declare a cached limit stale when age exceeds five minutes.

**R2. Probe provider when stale.** When admission detects a stale cached limit before blocking dispatch, schedule one short-lived Codex app-server probe to read current `account/rateLimits` from the authenticated provider. Non-blocking; execute in background.

**R3. Persist bounded retry state.** If a probe fails, retain the cached reading and schedule a retry after two minutes. Do not re-probe continuously; bound retries to prevent resource exhaustion.

**R4. Surface freshness in status.** Distinguish fresh provider-confirmed limit from stale cached limit in `status` output and decline reasons. Include observation time and next scheduled probe time.

**R5. Restore dispatch on refresh.** Once a probe succeeds with a new reading from the provider, dispatch immediately resumes from the refreshed capacity (assuming no other holds).

**R6. Integration test coverage.** Add a regression test: cached limit at 100%, provider returns 4% with a new reset timestamp, and ready dispatch resumes without ledger editing.

---

## Key Technical Decisions

**KTD1. Probe strategy — short-lived, non-blocking.**
The admission path schedules one short-lived Codex app-server probe after a cached limit ages five minutes. Failed probes retain the ledger and retry after two minutes. This bounds cost while keeping dispatch unblocked on stale reads.
(session-settled: user-directed — chosen to balance freshness and resource cost)

**KTD2. Freshness signal in status.**
Status output will show observation time and next-probe-scheduled timestamp alongside the limit values, so the operator can see both the age of the cached reading and when the next refresh attempt is due. This gives visibility without requiring manual intervention.

**KTD3. Base branch.**
Integration branch is `main`.

---

## Implementation Units

### U1. Add observation timestamp and retry schedule tracking to model-usage ledger

**Goal:** Extend the ledger schema to track when each usage entry was observed and when the next retry is scheduled, enabling stale detection and bounded retries.

**Requirements:** R1, R3

**Dependencies:** None

**Files:**
- `src/aiur/model_availability.ex` (read ledger schema, understand current structure)
- `src/aiur/model_usage.ex` (add timestamp and retry fields to persisted entry)
- `src/test/aiur/model_usage_test.exs` (test scenarios below)

**Approach:**
The ledger currently stores `{provider, limit_info}` tuples with usage amounts. Extend each ledger entry to include `observed_at` (Unix timestamp when the reading was fetched from the provider) and `retry_scheduled_at` (Unix timestamp when the next probe should fire, `nil` if no retry is pending). On first load, entries without these fields get backfilled with `observed_at = now()` and `retry_scheduled_at = nil`.

**Patterns to follow:**
- Mirror the ledger persistence pattern in `model_usage.ex` — read/write atomic, no partial state
- Follow timestamp conventions used elsewhere in the codebase for provider timestamps

**Test scenarios:**
- New ledger entry has both `observed_at` and `retry_scheduled_at = nil`
- Ledger round-trip preserves timestamp fields
- Legacy ledger without timestamps gets backfilled on load
- Stale detection: entry older than 5 minutes is correctly identified as stale
- Retry scheduling: after failed probe, `retry_scheduled_at` is set to 2 minutes from now

---

### U2. Detect stale limits in dispatch-admission gates and schedule probes

**Goal:** When a cached limit is about to block dispatch, check if it is stale. If stale, schedule a background probe instead of blocking immediately.

**Requirements:** R2, R5

**Dependencies:** U1

**Files:**
- `src/aiur/dispatch_policy.ex` (read provider gate logic)
- `src/aiur/model_availability.ex` (modify admission logic to detect stale + schedule probe)
- `src/aiur/codex_prober.ex` (new — lightweight probe executor; see U3)
- `src/test/aiur/model_availability_test.exs` (test scenarios below)

**Approach:**
In `DispatchPolicy.provider_gate/1` or its call path, before declining dispatch due to usage limit, check whether the cached limit is stale (age > 5 minutes). If stale and no retry is currently scheduled, emit an event or call to schedule a Codex app-server probe to run in the background. The probe fires once, asynchronously; if it succeeds, the ledger is refreshed immediately. If it fails, a retry is scheduled for 2 minutes later.

The admission path does not wait for the probe. Dispatch proceeds as if the stale reading were unknown (if other capacity exists, dispatch uses it; if no other capacity, the stale reading still blocks, but a future resolution is in flight). Subsequent checks will see the refreshed reading once the probe completes.

**Patterns to follow:**
- Use the existing event system or timer mechanism to schedule the background probe
- Follow error handling conventions — probe failure logs but does not escalate
- Mirror the read-and-update pattern used for other ledger refreshes

**Test scenarios:**
- Stale limit (>5 min old) detected during admission → probe scheduled
- Fresh limit (≤5 min old) does not trigger probe
- Probe not scheduled if one is already pending (`retry_scheduled_at` is future)
- Multiple stale readings for different providers → multiple probes scheduled (one per provider)
- On subsequent admission check after probe succeeds, refreshed reading is visible

---

### U3. Implement Codex app-server probe for usage limits

**Goal:** Fetch current usage from the Codex provider's authenticated endpoint and update the ledger atomically.

**Requirements:** R2, R3

**Dependencies:** U1

**Files:**
- `src/aiur/codex_prober.ex` (new — probe implementation)
- `src/aiur/model_availability.ex` (called from U2 to execute probe)
- `src/test/aiur/codex_prober_test.exs` (test scenarios below)

**Approach:**
New module `Codex Prober` spawns a short-lived app-server session to `codex app-server --stdio`, reads `account/rateLimits`, and atomically updates the ledger with the new observation time and clears any retry schedule. On failure (no response, invalid response, app-server error), logs the failure, retains the cached reading, and sets `retry_scheduled_at` to 2 minutes from now. Probe times out after 5 seconds to avoid holding resources on stale/hung sessions.

**Patterns to follow:**
- Use existing app-server spawning and communication patterns (likely in `src/aiur/codex_*` or `src/aiur/app_server*` modules)
- Mirror error handling and logging conventions — transient provider failures should not escalate

**Test scenarios:**
- Successful probe: fetches new limit from provider, updates ledger atomically, clears retry schedule
- Provider returns lower usage (4% after reset) → ledger updated, dispatch resumes on next check
- Provider unreachable → ledger unchanged, retry scheduled for 2 minutes later
- Malformed response → treated as failure, retry scheduled
- Probe times out after 5 seconds
- Concurrent probes for the same provider: second one cancels or deduplicates the first

---

### U4. Display freshness and retry schedule in status output

**Goal:** Update `status` and decline-reason output to show when a usage limit was last observed and when the next refresh attempt is scheduled.

**Requirements:** R4

**Dependencies:** U1

**Files:**
- `src/aiur/status.ex` or equivalent status-rendering module (read current output)
- Status rendering code (update format to include freshness info)
- `src/test/aiur/status_test.exs` (test scenarios below)

**Approach:**
For each provider limit shown in status, append freshness metadata:
- `observed_at: <ISO timestamp>`
- `age_seconds: <elapsed time since observation>`
- `freshness: fresh | stale | probing` (based on age and retry schedule)
- `next_probe: <ISO timestamp or "none">`

Format depends on the output medium (CLI vs. dashboard). CLI should remain terse; dashboard can show full timestamps. Stale readings include a note that a refresh is in progress or pending.

**Patterns to follow:**
- Match existing status output conventions (field names, timestamp formats)
- Use existing freshness indicators or enums if they exist

**Test scenarios:**
- Fresh limit (≤5 min old) shows `freshness: fresh` with current timestamp
- Stale limit (>5 min old) shows `freshness: stale` with last-observed timestamp and next-probe time
- Limit with pending retry shows `freshness: probing` and next-probe timestamp
- Age is rendered in human-readable form (e.g., "5 minutes ago", "23 seconds ago")
- Decline reason includes freshness info when usage limit is the cause

---

### U5. Integration test: cached limit → provider reset → dispatch resumes

**Goal:** Verify the complete flow: high cached limit blocks dispatch, provider resets and returns new low limit, probe fetches new reading, dispatch resumes.

**Requirements:** R6

**Dependencies:** U1, U2, U3, U4

**Files:**
- `src/test/aiur/model_availability_integration_test.exs` (new or extend existing)

**Approach:**
Set up a test fixture where:
1. Cached ledger shows Codex weekly `used=100/limit=100` (stale, older than 5 minutes)
2. Attempt dispatch → blocked by usage limit
3. Mock Codex provider to return `usedPercent=4, rateLimitReachedType=null, resetTime=<new future time>`
4. Trigger or wait for background probe to run
5. Verify ledger is refreshed with new observation time and empty retry schedule
6. Verify dispatch on the same ticket now proceeds (no usage block)

**Test scenarios:**
- Covers R2–R5: stale detection, probe scheduled, success, dispatch resumes
- Covers R3: if probe fails, retry is scheduled and dispatch remains blocked until retry succeeds
- Covers R4: status output shows refreshed `observed_at` and cleared `next_probe` after success

---

## Scope Boundaries

**In Scope:**
- Stale detection and background probing of Codex usage limits
- Atomic ledger updates from probe results
- Freshness visibility in status and decline reasons
- Integration test for the scenario described in the issue
- Documentation updates to reflect new behavior (see below)

**Out of Scope:**
- Probing other providers (e.g., OpenAI, OpenRouter) — Codex-only for this PR
- Automatically forcing provider resets or quota management
- Dashboard UI changes (status rendering assumes CLI-first; dashboard can follow)
- Historical telemetry or audit logs of probes (observability can be a follow-up)

**Deferred to Follow-Up Work:**
- Extend probing to other providers once Codex pattern is proven
- Configurable probe interval and retry timing (currently hard-coded to 5 min / 2 min)
- Metrics and alerting on probe failures

---

## Acceptance Examples

**AE1. Khala run scenario (from issue #2832):**
- Cached limit shows 100/100 (stale, 2+ hours old)
- Attempt to dispatch worker → blocked by usage
- Codex provider has been reset; `codex app-server` reports 4/100
- Probe fetches new reading within 5 minutes
- Ledger refreshed; dispatch resumes immediately
- No manual ledger editing required

**AE2. Retry on probe failure:**
- Cached limit stale
- Probe scheduled, attempt fails (provider unreachable)
- Ledger unchanged, retry scheduled 2 minutes later
- Status shows `next_probe: <2 minutes from now>`
- Dispatch remains blocked until retry succeeds

**AE3. Freshness visible in status:**
- Run `aiur status` with stale and fresh limits in the ledger
- Fresh limit shows `freshness: fresh, observed_at: <now>`
- Stale limit shows `freshness: stale, observed_at: <2 hours ago>, next_probe: <pending>`

---

## Dependencies & Constraints

- Requires write access to `~/.aiur/model-usage.json` (existing)
- Requires `codex app-server --stdio` to be available and authenticated (already a requirement)
- Non-blocking probe must not starve other dispatch work; use timeout to prevent hangs

---

## Definition of Done

- [ ] U1 implemented and tested (ledger schema extended, backfill on load)
- [ ] U2 implemented and tested (stale detection, probe scheduling in admission)
- [ ] U3 implemented and tested (Codex prober, atomic ledger refresh, retries)
- [ ] U4 implemented and tested (status output shows freshness and next-probe time)
- [ ] U5 integration test passes (cached 100% → provider 4% → dispatch resumes)
- [ ] All affected tests pass (`mix aiur.affected_tests` green)
- [ ] Docs updated: `website/docs-app/reference/configuration.md` (if any new config keys), `website/docs-app/guide/` (if operator behavior changed, note the automatic probe and retry cadence)
- [ ] Self-review: diff is sound, test coverage is adequate, no extraneous changes
- [ ] Draft PR opened against `main`, ready for human review

---

## Verification Contract

- Compile: `cd src && mix compile --warnings-as-errors`
- Format: `cd src && mix format --check-formatted`
- Affected tests: `cd src && mix aiur.affected_tests` (run with `--max-cases 4`)
- Manual verification: start aiur, verify status output shows freshness metadata

---

## Sources & Research

- Issue: https://github.com/aiur-team/aiur/issues/2832
- Related: #2896 (Capture Codex startup exits and show retry state), #2910 (Refresh stale graphs)
- Khala incident: run `khala-sol-20260927`, 2026-09-29, 0/16 agents after Codex reset
