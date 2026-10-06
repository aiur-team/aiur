---
ticket_id: MP-N6-C5-T01
feature_id: MP-N6
chunk_id: MP-N6-C5
bucket: 3-mobile-watch
title: Watch Command card — label, requester, question, up to three options, outcome line
status: blocked
blocked_by: [DESIGN-N6 (§3 watch card, D-4, D-5), DESIGN-N7, MP-N7 watch apps (N7-C1..C3), MP-N6-C1-T03, MP-N4-C6-T01]
prior_units: []
prior_boundaries: [mobile-app (watch apps inside packages/aiur-mobile, RC-17)]
prior_features: [MP-N7, MP-N4]
prior_findings: [E-B5 (WatchConnectivity is opportunistic), client-capability-model §7 (watch projection)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C5-T01 — Watch Command card

## Identity and outcome

Bucket 3, MP-N6, chunk C5. On watchOS and Wear OS: a compact card for a Command (short
label, requester, question in two lines, up to three option buttons with the recommended
first, Mic, "Open on phone") and a compact outcome line (accepted / already answered / no
longer needed / can't reach). Answers use the same C1-T03 API and outcomes, sent by the
path MP-N7 chooses (phone broker vs direct).

## Dependencies and blockers

**Blocked** on DESIGN-N6 §3 watch card and D-4 (multi-question → "Answer on phone"
proposed) and D-5 (option details on watch — proposed no); DESIGN-N7; the MP-N7 apps and
watch-link protocol (N7-C1..C3); MP-N4-C6-T01 (how notifications reach the watch).

## Verified starting point

E-B5 (WatchConnectivity "you can't rely on … as your only means"); client capability model
§7 (watch projection sent by the phone).

## Chosen design (fixed parts)

Watch answers carry `surface: "watch"`; an idempotency key is minted on the watch per
action and reused on retry through the phone.

## Implementation steps

After approval and MP-N7.

## Non-happy paths

Phone unreachable from watch → "can't reach"; no queued answers (OQ-N6-1 proposal).

## Compatibility and rollout

watchOS 10 / Wear OS per MP-N7.

## Verification

Watch UI tests per state; device V-W2.

## Completion and handoff

- [ ] Dependents: C5-T02, C5-T03.
