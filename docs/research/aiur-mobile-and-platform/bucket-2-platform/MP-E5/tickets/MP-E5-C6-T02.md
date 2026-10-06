---
ticket_id: MP-E5-C6-T02
feature_id: MP-E5
chunk_id: MP-E5-C6
bucket: 2-platform
title: Cancel control and Escape key that restore the field's pre-recording text
status: blocked
blocked_by: [DESIGN-E5, E5-OQ5, MP-E5-C6-T01, MP-E5-C2-T02]
prior_units: [U8]
prior_boundaries: [VOX, WEB]
prior_features: [ui-07]
prior_findings: []
size_owner: BROWSER
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C6-T02 — Cancel

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C6.
- **User value:** a mistaken or garbled dictation is discarded in one action, and the message
  the operator had already typed comes back exactly as it was.
- **Deliverable:** a Cancel control visible in `listening` and `finishing`, and `Escape`
  (E5-OQ5 recommendation: "toggle stays; add Escape to cancel") while focus is inside the
  voice component or the textarea; both push `cancel` (C2-T02), dispose capture, restore the
  field to its pre-recording value, and enter `cancelled → idle`.
- **Non-goals:** hold-to-talk (E5-OQ5 recommends no).

## Dependencies and blockers

- **Owner:** DESIGN-E5 (control placement, copy), E5-OQ5 (keyboard).
- **Predecessors:** MP-E5-C6-T01 (states), MP-E5-C2-T02 (server cancel).

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Pre-recording text | `baseText` captured at start (`conversation-voice-controller.js:167`) but it is the *append base*, mutated on each final (`:348`) — not a restore point |
| Escape in the drawer | the drawer hook handles keydown (`conversation-drawer-hook.js:7,14`) and Escape closes the dialog (`units.browser.spec.mjs:309` "manages focus, Escape, and focus return") |

## Chosen design

- New `this.restoreText` captured at the start of `start()` (before any partial) and never
  mutated; Cancel writes it back and dispatches `input` (so `phx-change` stores it).
- **Escape conflict:** in the drawer, Escape today closes the dialog. While the voice state is
  `listening` or `finishing`, the voice component's keydown handler calls
  `event.stopPropagation()` and cancels instead; in any other state Escape keeps closing the
  dialog. This preserves today's behaviour outside recording.
- Cancel also applies to the C4 Command forms; under E5-OQ3 "replace", Cancel restores the
  replaced text.

## Implementation steps

1. Component: Cancel button `data-voice-cancel`, visible per state.
2. Controller: `cancel()` → `transport.push("cancel")`, `capture.stop()`, restore,
   `transition("cancelled")`, then `idle`.
3. Keydown handling with the stop-propagation rule.
4. Docs: `concepts/units.md` (Cancel and Escape).

## Non-happy paths

- Cancel while the channel is already gone: local restore still happens; no push.
- A `transcript` arriving after cancel: the server drops it (C2-T02) and the client ignores
  any event for a stale `generation` (`:191-193`).

## Compatibility and rollout

Visible control; ships with DESIGN-E5. Rollback: revert.

## Verification

| Test (browser) | Expected |
| --- | --- |
| "Cancel restores the text typed before recording" | field "draft", dictate partial+final "hello", Cancel → field "draft"; `cancel` pushed; no `stop` pushed |
| "Escape cancels while listening and does not close the drawer" | drawer stays open; field restored |
| "Escape closes the drawer when not recording" | existing behaviour (`:309` test still passes) |
| "late transcript after Cancel is ignored" | fake channel emits `transcript` after cancel → field unchanged |

```bash
env -C src/browser npm run test:units
```

**Mutation checks.** Restore from `baseText` instead of `restoreText`: the first test fails
(the field would contain "draft hello"). Remove `stopPropagation`: the Escape test fails.

## Completion and handoff

- [ ] Cancel and Escape per DESIGN-E5/E5-OQ5; docs in PR.
- **Dependents:** MP-N6-C4-T02 (same cancel semantics on the phone).
