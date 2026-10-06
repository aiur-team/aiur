---
ticket_id: MP-E6-C7-T03
feature_id: MP-E6
chunk_id: MP-E6-C7
bucket: 2-platform
title: Draft cards with Confirm, Edit and Discard
status: blocked
blocked_by: [DESIGN-E6, E6-OQ1, MP-E6-C7-T02, MP-E6-C5-T03, MP-E6-C5-T05]
prior_units: []
prior_boundaries: [VOX, WEB]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C7-T03 — Draft cards

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C7.
- **User value:** it is impossible to mistake discussion for an instruction: a draft looks
  different from a spoken turn and goes nowhere without the operator's Confirm (DESIGN-E6 §6).
- **Deliverable:** draft cards in the panel for `instruction`, `command_answer` and `consult`
  drafts: exact text, target, kind; Confirm, Edit (inline textarea, ≤ 4,000 chars), Discard;
  status after confirm (`sent/delivered/failed/stale` with reason) from `draft` and `delivery`
  events.

## Dependencies and blockers

- **Owner:** DESIGN-E6, E6-OQ1 (button-only confirm recommended).
- **Predecessors:** C7-T02, C5-T03, C5-T05.

## Verified starting point

New UI. Delivery state wording aligns with MP-E5-C6-T03's mapping (same receipts).

## Chosen design

- Confirm sends `confirm_draft{draft_id, edited_text?}`; the button disables until the
  `draft` event shows `confirmed` or an error (no optimistic "sent").
- Stale cards keep the text selectable with a Copy button.
- Command-answer card shows the chosen option label or the custom text and the Command
  question.

## Implementation steps

Card component, JS handlers, tests, docs (C9-T01).

## Non-happy paths

Confirm on a now-stale draft → `target_stale` error shown on the card; double click → one
event (button disabled).

## Compatibility and rollout

Ships with DESIGN-E6. Rollback: revert.

## Verification

| Test (browser, fake channel) | Expected |
| --- | --- |
| "a draft card sends confirm once" | one `confirm_draft` push on double click |
| "edited text is sent as edited_text" | — |
| "a stale draft shows its reason and keeps the text" | — |
| "no card ever shows sent before the server says so" | status text after click equals "Confirming…" until event |

```bash
env -C src/browser npm run test:units
```

**Mutation check.** Set status to `sent` on click: the last test fails.

## Completion and handoff

- [ ] Cards for three kinds; docs in PR.
- **Dependents:** MP-N6/N7 adopt the same card semantics.
