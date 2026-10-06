---
ticket_id: MP-N1-C3-T02
feature_id: MP-N1
chunk_id: MP-N1-C3
bucket: 3-mobile-watch
title: Capability cache and refresh policy keyed by instance_id, boot_id and revision, with typed write-error patching
status: blocked
blocked_by: [DESIGN-N1, MP-N1-C3-T01, MP-N1-C2-T05, MP-R1-C3-T3, MP-R1-C3-T5, MP-N2-C6-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-R1, MP-N2, MP-R2]
prior_findings: []
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C3-T02 — Capability cache and refresh (TS)

Candidate tickets merged: N1-C3-T1 (cache + triggers) and N1-C3-T4 (typed write-error
mapping into the cache).

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C3.
- **User value:** screens show fresh capability state without polling in the background,
  and a server-side "this is off now" error immediately updates every affected control.
- **Deliverable:** `src/capability/store.ts` (PROPOSED): a per-instance store holding
  `{report, fetchedAt, bootId, revision, reachability, transportMode}`, a React hook
  `useAffordance(instanceId, affordanceId)` that calls the MP-N1-C3-T01 resolver, and the
  refresh rules of `client-capability-model.md` §6.
- **Non-goals:** the meta-dashboard's instance list fetch (MP-N3-C4 uses the gateway registry);
  events subscription (only used when `events.export` is available; MP-R2-C7; the polling
  fallback below is the v1 path).

## Dependencies and blockers

- DESIGN-N1; MP-N1-C3-T01 (resolver); MP-N1-C2-T05 (`signedFetch`).
- **MP-R1-C3-T3** (`GET /api/v1/capabilities` route), **MP-R1-C3-T5** (revision persistence,
  change event; carries `boot_id` per RC-04), **MP-N2-C6-T01** (the device-auth plug that lets
  a device token call `:dashboard_auth` routes; `identity-and-capabilities.md` §2.1 assumption).
- Concurrent with MP-N1-C3-T03.

## Verified starting point (base 45a290e3)

- The endpoint will sit in the `:dashboard_auth` pipeline next to `GET /api/v1/state`
  (`identity-and-capabilities.md` §2.1, citing `router.ex:186-189`) and before the
  catch-all `get("/api/v1/:issue_identifier", …)` (`router.ex:193`).
- Contract rules implemented: `client-capability-model.md` §6 table (pairing completes,
  app foreground, `system.capabilities.changed`, reconnect, before a write: cached < 10 s,
  write returns `capability_unavailable`, polling every 30 s foreground only) and the
  freshness budget (stale when client-observed age > 60 s foreground or server `freshness:
  stale`), and §8 (parallel fetch cap 4 per machine; restart → new `boot_id` → stale until refetch;
  render debounce 2 s).
- AGENTS.md "If a surface computes an age, it renders the age": the store exposes `ageMs` to
  every consumer.

## Chosen design

- **Cache key** `(machine_id, instance_id, boot_id, revision)`. A new `boot_id` marks the old
  entry `stale` immediately and triggers a refetch.
- **Refresh triggers** wired to: `AppState` change to `active` (React Native `AppState`),
  screen focus, a 30 s interval only while a consuming screen is focused and the app is
  `active`, `onMachineEvent` (revoked/endpoints changed), and explicit `refresh(instanceId)`.
  No background timers (brief N4: no reliance on background execution).
- **Pre-write check:** `ensureFresh(instanceId, maxAgeMs = 10_000)` before answer/send/mic.
- **Typed write errors:** a write returning `{error: "capability_unavailable", capability,
  state, reason}` (RC-04 / C-A7) patches that capability in the cached report (keeping
  `revision`, setting a `patched: true` marker), re-renders, then schedules a refetch.
  `401 device_revoked` → the machine's entries become `revoked`. `401` on an instance with
  `device_auth_disabled` → `unavailable` (reason `device_auth_disabled`).
- **Reachability classification** comes from `signedFetch` error codes; transport errors keep
  their `kind` (no collapse).
- Concurrency limiter: max 4 in-flight report fetches per machine.

## Implementation steps

1. `store.ts` (zustand-free plain module with a subscription set; no new state library
   unless DESIGN-N1 or another ticket introduces one).
2. `refresh.ts` (triggers, limiter, interval lifecycle).
3. `errors.ts` (typed error → patch).
4. `useAffordance.ts` hook with 2 s render debounce of state changes (cache updates are not
   debounced).
5. Tests with Jest fake timers and a fake `signedFetch`.

## Non-happy paths

- **Endpoint 404** (old daemon without the route): store records `report: null, cause:
  "endpoint_missing"` → resolver yields `needs_update` (contract §8).
- **Flapping capability:** cache updates every time; render debounced 2 s.
- **Concurrent refreshes for one instance:** coalesced (single flight per instance).
- **Background:** intervals cleared on `background`; on return, stale entries render with age
  until refetched.
- **Clock skew:** server `age_ms` preferred (identity contract §4).

## Compatibility and rollout

- Client-only. Works against a daemon that has the R1 endpoint; older daemons → `needs_update`.
- Rollback: n/a.

## Verification

- Command: `npm --prefix packages/aiur-mobile test -- test/capability/store.test.ts`.
- Cases:
  - `new boot_id marks cached report stale and refetches` — mutation: ignore `boot_id` in the
    key → fails.
  - `polling stops within one interval after AppState background` (fake timers, count fetches).
    Mutation: never clear the interval → fails.
  - `capability_unavailable write error patches the cache before refetch` — affordance flips
    to `unavailable` synchronously. Mutation: only refetch → assertion on the synchronous
    state fails.
  - `device_revoked marks every instance of that machine revoked`.
  - `404 endpoint yields needs_update, not unavailable`. Mutation: map 404 to `unavailable` →
    fails.
  - `no more than 4 concurrent fetches per machine` (10 instances).
  - `ensureFresh refetches when older than 10 s and not otherwise`.
- Unknown-path guard: replace the `stale` computation with "always fresh" → the 61 s fixture
  case fails.

## Completion and handoff

- [ ] All cases pass; mutations fail.
- **Docs:** none user-facing.
- **Dependents:** MP-N1-C4-T06, MP-N1-C5 (diagnostics reads the store), MP-N3-C4, MP-N6.
