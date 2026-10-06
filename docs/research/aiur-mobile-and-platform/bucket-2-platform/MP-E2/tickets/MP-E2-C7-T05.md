---
ticket_id: MP-E2-C7-T05
feature_id: MP-E2
chunk_id: MP-E2-C7
bucket: 2-platform
title: Stream Deck compatibility with v2 Commands
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C3-T04, MP-E2-C1-T04]
prior_units: [U6]
prior_boundaries: [WEB #34]
prior_features: [MP-R6 (Stream Deck), DESIGN-R6]
prior_findings: [DESIGN-E2 §3 Stream Deck row]
size_owner: "WEB / DECK_WEB (streamdeck_commands.ex; streamdeck_channel.ex 609 — no net growth) + packages/streamdeck"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C7-T05 — Stream Deck compatibility with v2 Commands

## Identity and outcome

- Bucket 2, MP-E2, chunk C7. **Visible — blocked on DESIGN-E2 §3 and DESIGN-R6.**
- **User value:** the deck keeps working for every Command: single-question Commands
  (including native ones) answer by option key as today; multi-question Commands say
  "answer on the dashboard" instead of offering a wrong one-key answer.
- **Deliverable:** `StreamdeckCommands.item/1` exposes `answerable_on_deck` (false when
  `questions` has > 1 entry or any multi-select) and `short_label`; the plugin shows the
  approved "answer on dashboard" face for non-deck Commands and refuses option keys for
  them; the server refuses `answer_command` for them (`reason: "dashboard_only"`).
- **Non-goals:** supersede on the deck (not requested by DESIGN-E2).

## Dependencies and blockers

- DESIGN-E2 §3 (confirm the flow), DESIGN-R6 (deck face copy); C3-T04 (facade on the
  deck), C1-T04 (fields).

## Verified starting point (`45a290e3`)

- `src/lib/aiur_web/streamdeck_commands.ex` (`item/1`, `actor/0` `:19,73`).
- `src/lib/aiur_web/streamdeck_channel.ex:151-168` `answer_command`; `:587-600`
  `build_answer_payload/1` (exactly one of `option_id` / `custom_response`).
- Plugin `packages/streamdeck/src/channel.ts:238-270`, `controller.ts:1061`.
- Tests: `src/test/aiur_web/streamdeck_commands_test.exs`,
  `streamdeck_channel_test.exs`, `streamdeck_key_face_contract_test.exs`.

## Chosen design

- Single-question v2 (native with one question): options map to keys exactly as v1;
  the answer is sent as today (`option_id`) and C3-T02 converts it to
  `question_answers` for the native reply.
- Server guard in `streamdeck_commands.ex` (called from the channel) so the channel
  does not grow.

## Implementation steps

1. `streamdeck_commands.ex`: `answerable_on_deck/1`, item fields, guard.
2. Channel: one call to the guard before `record_command_answer/2`.
3. Plugin: face + key refusal; key-face contract test update.

## Non-happy paths

- Older plugin without the field: server guard still refuses (`dashboard_only`), the old
  plugin shows its generic error face.

## Compatibility and rollout

- Rebuild/flash the sidecar after merge (operator step).

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur_web/streamdeck_commands_test.exs test/aiur_web/streamdeck_channel_test.exs test/aiur_web/streamdeck_key_face_contract_test.exs
npm --prefix packages/streamdeck test
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "multi-question Command is not answerable on deck" | item `answerable_on_deck: false` | step 1 |
| "answer_command for a multi-question Command replies dashboard_only" | reason string | guard |
| "single native question answers by option key" | `{:ok, …}`; native reply path receives `question_answers` | C3-T02 conversion |
| plugin "dashboard-only face rendered" | approved face text | plugin |

Mutation check per row. Device check (manual) on a physical deck.

## Completion and handoff

- [ ] Guard + face; contract test updated.
- Docs: `guide/stream-deck.md`.
- Dependents: none.
