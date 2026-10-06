---
ticket_id: MP-N6-C6-T01
feature_id: MP-N6
chunk_id: MP-N6-C6
bucket: 3-mobile-watch
title: Live resolution sync on an open Command screen (foreground polling; export feed later)
status: blocked
blocked_by: [DESIGN-N6 (§5 stale/resolved states), MP-N6-C3-T02, MP-N6-C1-T01, RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-R2 (C7-T05 paired-device read scope, later)]
prior_findings: [events-and-replay §7.2 (external clients reconcile by snapshot), identity-and-capabilities §3 rule 5]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C6-T01 — Live sync while open

## Identity and outcome

Bucket 3, MP-N6, chunk C6. While a Command screen is foregrounded, refresh the view every
10 s (`GET /api/v1/device/commands/:id`, compare `version`/status/delivery) and move the
screen to the right state when the Command is answered elsewhere, superseded, withdrawn or
delivered. Polling stops in background. When MP-R2-C7-T05 (paired-device read scope on the
events feed) lands, switch to the feed with polling as fallback — a separate follow-up, not
this ticket.

## Dependencies and blockers

**Blocked** on DESIGN-N6 §5 presentation of "answered elsewhere"/"stale" while the user is
mid-edit (keep draft vs discard is a design call); C3-T02; RQ-TRANSPORT.

## Verified starting point

Events-and-replay §7.2: clients bootstrap from snapshots and treat events as "refresh the
object"; R2-C7-T05 is blocked on MP-N2 today.

## Chosen design (fixed parts)

Decision: polling in v1 (10 s, foreground only) because the paired-device feed scope is
not yet specified (R2-C7-T05 blocked on MP-N2); cost ≤ 6 requests/minute per open screen.

## Implementation steps

After approval.

## Non-happy paths

Poll failure → keep state, show age (AGENTS.md age rule), back off to 30 s.

## Compatibility and rollout

n/a.

## Verification

`answeredElsewhereTransitionsWithinOnePoll` (fake clock); device V-M1, V-M2.

## Completion and handoff

- [ ] Follow-up recorded for the feed switch after R2-C7-T05.
