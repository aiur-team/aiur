---
ticket_id: MP-E2-C3-T04
feature_id: MP-E2
chunk_id: MP-E2-C3
bucket: 2-platform
title: Stream Deck shows who won when an answer loses the race
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C3-T02]
prior_units: [U6]
prior_boundaries: [WEB #34]
prior_features: [MP-R6 (Stream Deck), DESIGN-R6]
prior_findings: [D11, DESIGN-E2 §3 Stream Deck row]
size_owner: "WEB / DECK_WEB (streamdeck_channel.ex 609 — already over 500: net growth must be ≤ 0, move helpers out) + packages/streamdeck"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C3-T04 — Stream Deck shows who won when an answer loses the race

## Identity and outcome

- Bucket 2, MP-E2, chunk C3. **Visible surface — blocked on DESIGN-E2.**
- **User value:** pressing an option key after someone else already answered shows
  "answered by …" on the key instead of a raw error atom.
- **Deliverable:** `answer_command` goes through `Aiur.Commands.Answering.answer/3` and
  replies with a structured outcome; the plugin renders the already-answered / withdrawn /
  stale outcomes. No supersede on the deck (unless DESIGN-E2 adds it).
- **Non-goals:** v2 multi-question support on the deck (C7-T05).

## Dependencies and blockers

- DESIGN-E2 §3 (Stream Deck row: confirm the flow and the key copy) and DESIGN-R6.
- Predecessor C3-T02.
- May run concurrently with C3-T03.

## Verified starting point (`45a290e3`)

- `src/lib/aiur_web/streamdeck_channel.ex:151-168` `handle_in("answer_command", …)`
  (focused-ticket check, exact `version`, idempotency key); `:567-579`
  `record_command_answer/2` calls `DecisionStore.answer/4` with
  `StreamdeckCommands.actor/0`; `:581-585` `answer_result/1`; errors become
  `%{reason: reason_text(reason)}` (`:163`, `:459-460` → `inspect/1` for tuples, so a
  conflict reaches the device as an Elixir term string). File is 609 lines.
- `src/lib/aiur_web/streamdeck_commands.ex` (`actor/0` `:19,73`, `item/1`).
- Plugin: `packages/streamdeck/src/channel.ts:238-270,417-429,572` (reply types),
  `controller.ts:1061` (applies an `answer_command` reply).
- Tests: `src/test/aiur_web/streamdeck_channel_test.exs`, `streamdeck_commands_test.exs`.

## Chosen design

- `record_command_answer/2` → `Answering.answer(decision_id, answer, actor: StreamdeckCommands.actor(), client: %{surface: :streamdeck})`.
- Reply mapping (moved into `streamdeck_commands.ex` to keep the channel from growing):
  - `:accepted | :duplicate` → `{:ok, %{"status" => …, "decision" => item}}` (as today).
  - `:already_answered` → `{:error, %{reason: "already_answered", winner: %{"actor_kind",
    "summary", "accepted_at"}}}`.
  - `:withdrawn` → `{:error, %{reason: "withdrawn", status: …}}`; `:stale` →
    `{:error, %{reason: "stale"}}`.
- Plugin: on `already_answered`, show the winner summary on the pressed key for the
  existing transient-message duration and refresh the page; copy per DESIGN-E2.
- Typed reply: extend the TS reply union in `channel.ts` with the three reasons.

## Implementation steps

1. `streamdeck_commands.ex`: `answer_reply/1` (outcome → reply).
2. `streamdeck_channel.ex`: call the facade + `answer_reply/1`; delete the now-unused
   `answer_result/1` (net line change ≤ 0).
3. `packages/streamdeck/src/channel.ts`, `controller.ts`: handle the reasons.

## Non-happy paths

- Device retry after a dropped reply: same key → `:duplicate` → treated as success.
- Store unavailable: `reason: "store_unavailable"` (existing behaviour kept).
- Older plugin build: unknown `reason` strings fall back to its generic error face
  (check `controller.ts` error path at implementation time and keep that fallback).

## Compatibility and rollout

- Wire: additive reasons in error replies. The sidecar must be rebuilt/flashed after merge
  (memory "Restart services after changes": flash the deck if the sidecar changed).

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur_web/streamdeck_channel_test.exs test/aiur_web/streamdeck_commands_test.exs
npm --prefix packages/streamdeck test
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| `streamdeck_channel_test` "answer after another answer replies already_answered with winner" | `reason == "already_answered"`, `winner.actor_kind == "operator"` | `answer_reply/1` |
| "duplicate key reply is ok" | `{:ok, %{"status" => "duplicate"}}` | mapping |
| "expired Command replies withdrawn" | `reason == "withdrawn"` | mapping |
| plugin unit test "already_answered shows winner summary" | key title equals summary | controller handling |

Mutation check per row. Device check (manual): a physical or emulated deck answering a
Command already answered on the dashboard shows the winner.

## Completion and handoff

- [ ] Facade used; channel not grown; plugin handles reasons.
- Docs: `website/docs-app/guide/stream-deck.md` (one line on the new
  message).
- Dependents: C7-T05.
