---
ticket_id: MP-N4-C2-T07
feature_id: MP-N4
chunk_id: MP-N4-C2
bucket: 3-mobile-watch
title: (Optional) Cloudflare Workers deployment of the relay
status: blocked
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C2-T06, RQ-N4-8, OQ-N4-1]
prior_units: []
prior_boundaries: [relay service (separate deployable)]
prior_features: []
prior_findings: [MP-Q2 resolution: Cloudflare optional]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C2-T07 — Cloudflare Workers adapter (optional)

## Identity and outcome

Bucket 3, MP-N4, chunk C2. Optional second deployment target for the relay with KV/D1
storage. Value: cheaper hosting for the default relay. Not required for any acceptance
criterion; Cloudflare stays optional (brief §3, MP-Q2).

## Dependencies and blockers

- **RQ-N4-8 (new):** can a Worker reach APNs, which requires HTTP/2 to
  `api.push.apple.com` (E-A2 / C2-T02 evidence), and sign ES256 JWTs within Worker CPU
  limits? Not verified in Phase C; needs Cloudflare documentation evidence or a spike.
  The answer decides whether this ticket is a port (TypeScript re-implementation of
  contract §7–§8) or is closed as infeasible.
- OQ-N4-1 and MP-N4-C2-T06 decide whether the default relay is hosted on Cloudflare at all.
- C2-T05 (the reference container exists first) and C2-T06 (default deployment decision).

## Verified starting point

- No Cloudflare Worker code in the repo; the only Cloudflare piece is the inbound
  `cloudflared` tunnel for webhooks (`website/docs-app/apis/github.md:744-760`), which
  shares nothing with this.

## Chosen design

Deferred until RQ-N4-8 is answered. Constraint if pursued: identical HTTP contract and
test suite (contract tests run against both deployments), same privacy limits
(no body logging, 7-day retention).

## Implementation steps

n/a — blocked on RQ-N4-8 and OQ-N4-1; do not start.

## Non-happy paths

n/a until the design exists.

## Compatibility and rollout

Would be a deployment option only; daemon and apps are unaware of the host.

## Verification

Contract test suite from C2-T01..T04 run against the Worker (`wrangler dev`), once the
ticket is unblocked.

## Completion and handoff

- [ ] RQ-N4-8 answered with dated evidence; ticket either specified or closed.
