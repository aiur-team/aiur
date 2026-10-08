---
ticket_id: MP-N6-C2-T03
feature_id: MP-N6
chunk_id: MP-N6-C2
bucket: 3-mobile-watch
title: Existing-conversation detection and anchor scroll on tap
status: blocked
blocked_by: [DESIGN-N6, DESIGN-E4, DESIGN-N1 (conversation surface native vs WebView), MP-N6-C2-T02, MP-E4-C3-T02, MP-E4-C5-T03]
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
DESIGN-N1 / MP-N1 surface boundary; anchor highlight design is DESIGN-E4; MP-E4-C3-T02
(anchors), MP-E4-C5-T03 (conversation view with jump to position) must exist.

## Verified starting point

Anchors contract §10: anchor → `EntryRef {conversation_id, pos}`, `placement: at|after`,
`precision`; Command anchors are `exact` via `decision_source`.

## Chosen design

Fixed now (independent of the DESIGN-N1 surface decision):

- "Same conversation" is identified by `conversation_id` (anchors contract §10), never by a
  title or ticket label.
- `conversationTarget(command, anchor) → {conversation_id, pos | null, placement,
  role: "worker" | "executor"}` is a pure function; `pos: null` means "open at end with
  'position unavailable'".
- Executor-originated Commands open the Executor conversation as a secondary view
  (pushed, never the landing screen; brief §3).
- On tap while that conversation is the visible screen: scroll to `pos` with `placement`
  and open the response sheet (C3-T01) as a modal over it; no second screen is pushed.
- Conversation entry bodies are held in memory only (plan §5.6, security M5); anchors and
  positions may be cached.

Surface-dependent (DESIGN-N1): `ConversationNavigator` has two implementations behind one
interface, `openAt(target)`: native (MP-E4 History API list) or WebView (dashboard route
with `#pos=` fragment). Only the one DESIGN-N1 picks is built; the interface and its tests
are fixed now.

## Implementation steps

1. `packages/aiur-mobile/src/commands/conversationTarget.ts` (pure).
2. `packages/aiur-mobile/src/conversations/ConversationNavigator.ts` (interface) and the
   chosen implementation.
3. Extend `landOn` (C2-T02) with the "already visible" branch.
4. "Open conversation" button handler on `CommandScreen` (C3-T01).
5. Docs: covered by the C2-T02 section of `website/docs-app/guide/mobile.md` ("Opening a
   notification"); add one sentence on "Open conversation" and "position unavailable".

## Non-happy paths

- Anchor `unanchored` or `pos` missing → open at end with "position unavailable".
- Conversation not found (purged) → stay on the Command with a note; never an unrelated chat.
- Executor conversation capability unavailable (`executor.conversation`) → button disabled
  with reason.

## Compatibility and rollout

Highlight look is DESIGN-E4 (design-pending).

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/commands/conversationTarget.test.ts test/landing/landOn.test.ts
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `sameConversationScrollsInsteadOfStacking` (V-N2) | navigator receives `scrollTo(pos)` + sheet; stack depth unchanged | the visible-screen branch (push a second screen → fails) |
| `identityIsConversationIdNotTitle` | two conversations with equal titles are distinct | the id rule |
| `missingAnchorOpensAtEndWithNote` | `pos: null` → open at end, note set | the unknown-path rule (plausible default `pos: 0` → fails) |
| `executorCommandOpensSecondary` | executor role → pushed secondary view, not landing | the role branch |
| `executorConversationUnavailableDisablesButton` | capability unavailable → disabled with reason | the gate |

Device: V-N2.

## Completion and handoff

- [ ] Each test fails with its hunk reverted in a worktree.
- Dependents: none.
