---
ticket_id: MP-E6-C7-T02
feature_id: MP-E6
chunk_id: MP-E6-C7
bucket: 2-platform
title: Converse panel component and its states
status: blocked
blocked_by: [DESIGN-E6, E6-OQ4, E6-OQ8, MP-E6-C7-T01, MP-E5-C1-T02, MP-E5-C3-T02]
prior_units: []
prior_boundaries: [VOX, WEB]
prior_features: [ui-07]
prior_findings: []
size_owner: n/a (new component + new JS file < 500 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C7-T02 — Converse panel

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C7.
- **User value:** a clear place to talk with the assistant about this ticket or the project:
  who you are talking about, what it is doing, what it heard, what it knows it does not know.
- **Deliverable:** function component `AiurWeb.Components.ConversePanel` (PROPOSED) opened by
  MP-E5-C3-T02's `open-voice-conversation` event, plus `src/priv/static/voice-converse.js`
  (PROPOSED) using `AiurVoiceCapture` and `AiurVoiceTransport` (MP-E5-C1-T02). Renders every
  DESIGN-E6 §4 state: connecting, listening, thinking, speaking, interrupted, consulting,
  reconnecting/error, ended (with reason and transcript link), context gaps; Start and End
  buttons; live transcript of final turns (partials if the spike shows them).
- **Non-goals:** draft cards (C7-T03), playback (C7-T04), history (C8).

## Dependencies and blockers

- **Owner:** DESIGN-E6 (layout, copy), E6-OQ4 (name/voice shown), E6-OQ8 (one target per
  session: switching target closes this panel's session).
- **Predecessors:** C7-T01, MP-E5-C1-T02, MP-E5-C3-T02.

## Verified starting point

- Capture/transport modules from MP-E5-C1-T02 (not at base). Hook registration pattern
  `layouts.ex:245-270`.

## Chosen design

- Opening the panel does **not** start capture (V1); the Start button inside the panel does
  (D16 choice already made by clicking Converse; Start is the explicit begin).
- State comes only from channel `state` events; the panel never infers it.
- Context gaps from the session's `context` gaps list are shown as a persistent note.
- Hook `ConversePanel` registered in `layouts.ex`.
- **Ended and error reasons (Phase D, M7).** The panel renders `ended{reason}` and `error`
  from the voice-session §8.1 table: the copy key and the Retry affordance (`none` / `now` /
  `later`) come from the row, served to the page by
  `Aiur.VoiceConversation.ClientErrors.table/0` (C4-T01) in the panel assigns. `cost_cap`,
  `provider_quota`, `provider_unavailable`, `provider_error`, `transport_lost` and `unknown`
  each have their own copy; none falls back to a generic "error".

## Implementation steps

Component, JS module, hook registration, CSS, docs (concepts page section in C9-T01 links
here; `gui.md` Writable controls row).

## Non-happy paths

Each §4 state has copy; `error` keeps the transcript visible; tab hidden → capture paused
and the session ended after the idle timeout (contract §2 "page/app hide").

## Compatibility and rollout

Ships with DESIGN-E6. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| browser "opening the panel requests no microphone" | `getUserMedia` spy 0 |
| browser "Start joins voice:converse with the panel's target" | payload `mode: "converse"` |
| browser "each server state renders its approved copy" | scripted fake channel through all states |
| browser "context gaps are shown" | gap text visible |
| LiveView "switching target ends the current session" (E6-OQ8 = yes) | `end` pushed |
| browser "each §8.1 end reason renders its copy key and retry affordance" | table-driven over `ClientErrors.table/0`; `cost_cap` and `provider_quota` show no Retry, `transport_lost` shows Retry |

```bash
env -C src/browser npm run test:units
make -C src fmt-check lint
```

**Mutation check.** Render `listening` copy for unknown states: a test with an unknown state
string fails (it must render the unknown copy). Replace the `cost_cap` branch with the generic
error copy: the §8.1 table test fails.

## Completion and handoff

- [ ] Panel with all states; docs in PR.
- **Dependents:** C7-T03, C7-T04, C8-T02.
