---
title: KA5 Warm first poll after restart - Plan
type: feat
date: 2026-10-09
topic: keep-agents-restart
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/keep-agents-restart/brainstorm.md
base_main_sha: 9940eed44
---

# KA5 Warm first poll after restart - Plan

## Goal Capsule

- **Objective:** dispatch resumes within one poll cycle after any restart. The
  first poll reuses persisted dispatch-authorization timelines, and the
  dispatch envelope starts at no less than the number of running (adopted)
  agents.
- **Product authority:** [brainstorm.md](brainstorm.md) (R11, R12).
- **Open blockers:** #3768 (persisted envelope) merged.
- **Product Contract preservation:** unchanged.

---

## Problem Frame

Measured 2026-10-06 on about 130 open tickets: after a restart, status said
"has not polled yet" for more than 20 minutes. The first poll does serial
dispatch-authorization timeline reads per ticket with a cold cache. That cache
(`Aiur.GitHub.DispatchAuthorization`, ETS table
`:aiur_github_dispatch_authorization_timelines`, up to 1,000 entries) is lost
on every restart. ETags already persist in `Aiur.GitHub.ResourceStore`, so a
persisted timeline plus its validator turns most of those reads into free
`304`s. The envelope restarts at 1 slot; #3768 persists a safe level.

## Requirements

- R11, R12 from the brainstorm.
- KA5-R1. Timelines persist across a restart and are revalidated (ETag or
  issue `updated_at`) before use; a stale entry is never trusted without
  revalidation.
- KA5-R2. The first poll after boot completes in under 3 minutes on the aiur
  repo (about 130 open tickets), down from 5-20+.
- KA5-R3. The envelope's boot value is `max(#3768 persisted level, adopted
  count)`.

## Key Technical Decisions

- **Persist through `Aiur.GitHub.ResourceStore`**, resource type
  `:issue_timeline`, keyed by issue identity. It is already restart-durable,
  already holds ETags, and already has a retention policy. A second store
  would duplicate that.
- **Write-behind, bounded.** Store on each successful fetch; cap and evict by
  the existing 1,000-entry bound.
- **Revalidate, do not trust.** On first read after boot, send a conditional
  request with the stored ETag; `304` uses the stored body.
- **Adopted tickets skip authorization** on the first poll; they are running.
  (KA3 marks them; this ticket only reads the mark when present, so it does
  not depend on KA3.)

## Implementation Units

### U1. Persisted timeline cache

**Goal:** timelines survive restart and are revalidated.
**Requirements:** KA5-R1, KA5-R2, R12.
**Dependencies:** none.
**Files:** `src/lib/aiur/github/dispatch_authorization.ex`,
`src/lib/aiur/github/resource_store.ex` (new resource type),
`src/test/aiur/github/dispatch_authorization_test.exs`,
`src/test/aiur/github/resource_store_test.exs`.
**Test scenarios:**
- Fetch, restart the store, read: one conditional request, `304`, cached
  verdict used.
- Changed timeline (`200`): new body stored, verdict recomputed.
- Truncated-page ladder still applies on a `200` after boot.
- Corrupt stored entry: dropped, cold fetch.
**Verification:** suites green; first-poll duration logged at info.

### U2. Envelope floor and adopted skip

**Goal:** dispatch is not throttled below the fleet that is already running.
**Requirements:** KA5-R3, R11.
**Dependencies:** #3768.
**Files:** `src/lib/aiur/orchestrator/slots.ex` (or the envelope module #3768
introduces), `src/lib/aiur/orchestrator/dispatch_policy.ex`,
`src/test/aiur/orchestrator/slots_test.exs`,
`src/test/aiur/orchestrator/dispatch_policy_test.exs`.
**Test scenarios:**
- Boot with 6 adopted entries and persisted level 4: envelope starts at 6.
- Boot with no adopted entries: #3768 behaviour unchanged.
- Adopted tickets are not candidates on the first poll.
**Verification:** suites green.

## Verification Contract

Restart the live aiur daemon (plain restart is enough) and record the time
from boot to the first completed poll; it must be under 3 minutes.

## Definition of Done

U1-U2 merged; first-poll duration measured and recorded on the ticket.
