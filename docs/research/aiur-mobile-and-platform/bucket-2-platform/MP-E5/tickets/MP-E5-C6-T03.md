---
ticket_id: MP-E5-C6-T03
feature_id: MP-E5
chunk_id: MP-E5-C6
bucket: 2-platform
title: Show the real delivery state after Send, taken from the send path, not invented by voice
status: blocked
blocked_by: [DESIGN-E5, MP-E5-C6-T01, MP-E7-C3-T4, MP-E4-C6, MP-E2]
prior_units: [U8]
prior_boundaries: [VOX, WEB, MSG, DEC]
prior_features: [ui-07]
prior_findings: []
size_owner: WEB
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C6-T03 — Delivery indicator

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C6.
- **User value:** after pressing Send on dictated text, the operator sees whether it was
  queued, reached the agent, or failed — the same states typed text shows.
- **Deliverable:** the voice component does **not** own delivery. It renders the composer's
  existing delivery state (MP-E4-C6 delivery overlay for messages; the Command notice/error
  for answers) next to its status line and sets `data-voice-state="sent"` once the surface
  confirms acceptance. No voice-specific delivery state exists (DESIGN-E5 §4 "not a
  voice-only state").
- **Non-goals:** defining receipts (MP-E7 listener contract §7; MP-E2 dispatch status).

## Dependencies and blockers

- **Owner:** DESIGN-E5 (placement of the mirrored state).
- **Predecessors:** MP-E7-C3-T4 (receipts exposed by `AgentChat.delivery_status/2` and HTTP);
  MP-E4-C6 (shared composer + delivery overlay, consumed by MP-E3-C5); MP-E2 dispatch status
  (already rendered by `answer_notice/1`, `decision_commands.ex:323-330`).

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Message send result today | `send-operator-message` → `send_operator_message/4` and `put_chat_error/3` with `AgentLogModal.format_error/1` texts (`dashboard_live.ex:640-661`; `agent_log_modal.ex:131-145`) |
| Unknown outcome | `{:outcome_unknown, _}` copy "…may still be queued…press Send again to retry without a duplicate." (`agent_log_modal.ex:138-139`); `message_id` idempotency (#2717, `agent_chat.ex:22-25`) |
| Command result | `answer_notice/1` (`decision_commands.ex:323-330`): duplicate, queued, delivered |

## Chosen design

- The surface renders its own delivery element (E4 overlay / Command notice). The voice
  component exposes `attr :delivery, :map` = `%{state: receipt_atom, message_id}` and only
  echoes it into its status line; mapping:
  `accepted|held_async → "Sent — waiting for the agent"`, `harness_queued → "Delivered to
  the agent"`, `in_context → "The agent has it"`, `failed → error copy`,
  `outcome_unknown → today's unknown-outcome copy`. Final strings are DESIGN-E5/E7 copy.
- After a `failed` or `outcome_unknown`, the dictated text stays in the field (the drafts
  map keeps it) so the operator can retry; the retry reuses the same `message_id`
  (`agent_chat.ex:22-25`), so no duplicate is queued.

## Implementation steps

1. `<.voice_input>` `delivery` attr and status echo.
2. Pass the overlay state from the drawer, modal and Executor composer (E4-C6 assign) and
   from the Command forms (`notice`/`error`).
3. Docs: `concepts/units.md` one sentence: voice uses the same delivery states as typing.

## Non-happy paths

- Overlay unavailable (E4-C6 not landed): no echo; status stays `ready` → `idle`. Never a
  guessed "delivered".
- Receipt unknown to this client: render the `unknown` copy (collapsed-cause rule).

## Compatibility and rollout

Visible; ships with DESIGN-E5 after E4-C6/E7-C3. Rollback: revert.

## Verification

| Test (LiveView) | Expected |
| --- | --- |
| "dictated text shows the overlay's harness_queued state" | stub overlay state → status text mapping |
| "a failed send keeps the dictated text and the same message id on retry" | first send `failed`; field still has text; second send carries the same `message_id` (fake orchestrator records ids) |
| "an unknown receipt renders unknown, not delivered" | receipt `:weird` → unknown copy |

```bash
env -C src mise exec -- mix test test/aiur_web/components/voice_input_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Map the fallback receipt to the `harness_queued` copy: the unknown test
fails.

## Completion and handoff

- [ ] Delivery echoed from the send path on every voice surface; docs in PR.
- **Dependents:** MP-E5-C7-T01.
