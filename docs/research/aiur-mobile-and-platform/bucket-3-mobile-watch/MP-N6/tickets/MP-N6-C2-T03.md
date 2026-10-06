---
ticket_id: MP-N6-C2-T03
feature_id: MP-N6
chunk_id: MP-N6-C2
bucket: 3-mobile-watch
title: Existing-conversation detection and anchor scroll on tap
status: blocked
blocked_by: [DESIGN-N6, DESIGN-E4, DESIGN-N1 (conversation surface native vs WebView), MP-N6-C2-T02, MP-E4-C3, MP-E4-C5]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-E4, MP-N1]
prior_findings: [V-N2, anchors contract §10 (EntryRef {conversation_id, pos}, placement)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C2-T03 — Existing conversation and anchor scroll

## Identity and outcome

Bucket 3, MP-N6, chunk C2. If the requester's conversation is already the visible screen
when a Command notification is tapped, scroll to the Command's anchor (`pos`,
`placement`) and open the response sheet instead of stacking a duplicate (V-N2). "Open
conversation" on the Command screen opens the transcript at the anchor; with no anchor, at
the end with "position unavailable". Executor-originated Commands open the Executor
conversation as a secondary view (brief §3).

## Dependencies and blockers

**Blocked**: where the conversation renders on the phone (native vs dashboard WebView) is
DESIGN-N1 / MP-N1 surface boundary; anchor highlight design is DESIGN-E4; MP-E4-C3
(anchors), MP-E4-C5 (conversation view) must exist.

## Verified starting point

Anchors contract §10: anchor → `EntryRef {conversation_id, pos}`, `placement: at|after`,
`precision`; Command anchors are `exact` via `decision_source`.

## Chosen design

Pending surface decision. Fixed: identity of "same conversation" is `conversation_id`, not
a title.

## Implementation steps

n/a until unblocked.

## Non-happy paths

Anchor `unanchored` → open at end with note.

## Compatibility and rollout

n/a.

## Verification

When unblocked: `sameConversationScrollsInsteadOfStacking` (must fail if a second screen is
pushed); device V-N2.

## Completion and handoff

- [ ] Dependents: C3-T01 ("Open conversation" link).
