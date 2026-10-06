---
ticket_id: MP-N4-C2-T06
feature_id: MP-N4
chunk_id: MP-N4-C2
bucket: 3-mobile-watch
title: Default relay deployment for store-distributed apps (publisher credentials, host, URL)
status: blocked
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C2-T05, OQ-N4-1, RQ-N4-7, DESIGN-N1 (distribution, OQ-N1-1)]
prior_units: []
prior_boundaries: [relay service (separate deployable)]
prior_features: [MP-N1]
prior_findings: [E-A6 (APNs key is per Apple team), E-F6, MP-Q2 resolution]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C2-T06 — Default relay deployment

## Identity and outcome

Bucket 3, MP-N4, chunk C2. Operate the relay instance that the published apps use by
default: sandbox and production instances, DNS + TLS, the publisher's APNs `.p8` key and
Firebase service account mounted as files, monitoring of `/healthz`, and the default relay
URL baked into MP-N1 release builds.

## Dependencies and blockers

- **OQ-N4-1 (owner, Kevin) — the main mobile blocker:** who publishes the store apps and
  operates the default relay (aiur-team Apple Developer Program membership and Firebase
  project; a host such as a container platform). Hard constraint: whoever sends to a
  store app's bundle id must hold that publisher's APNs key (E-A6) and Firebase project
  credentials (E-F6), so this cannot be "each user's machine".
- **RQ-N4-7:** hosting cost and provider rate limits for the default deployment, measured
  (relay request counts from C7 soak) — a cost claim follows AGENTS.md "A claimed saving
  must be measured".
- DESIGN-N1 / OQ-N1-1 (private vs public store distribution) changes whether a
  production instance is needed at all or only TestFlight/internal-testing sandbox.
- C2-T05 (image).

## Verified starting point

- No deployed relay, no Apple/Firebase credentials in the repo (and none may be added:
  AGENTS.md "Do not commit secrets").

## Chosen design

Fixed regardless of the answer: two instances (sandbox, production), credentials as files
on the host (never CI env output), image from C2-T05, privacy limits unchanged.
**Open until OQ-N4-1:** account owner, host, domain, budget. Do not implement before the
answer is recorded in DESIGN-N4 / MP-N4 plan §11.

## Implementation steps

n/a until OQ-N4-1 is answered. Then: provision host, DNS, TLS; mount credentials; deploy;
run the C7 smoke (`POST /v1/handles` sandbox → `POST /v1/send`); record URL for N1 config.

## Non-happy paths

- Relay outage: daemons queue in the outbox (C3-T02) and N5 staleness rules prevent a burst
  on recovery (AC-N4-7). Documented in the runbook.
- Key compromise: revoke the `.p8` in the Apple account, rotate; devices are unaffected
  (content is sealed per device; the relay never had content).

## Compatibility and rollout

Apps without a default relay require a user-entered relay URL (self-build). Rollback:
previous image; handles persist.

## Verification

Manual, recorded in the C7 report: V-I1, V-A1 through the deployed sandbox instance;
`/healthz` shows both providers `available`.

## Completion and handoff

- [ ] OQ-N4-1 answered and recorded; RQ-N4-7 numbers recorded with dates.
- [ ] Default relay URL given to MP-N1 release config (N1-C8).
- Dependents: MP-N4-C7-T02, N1-C8.
