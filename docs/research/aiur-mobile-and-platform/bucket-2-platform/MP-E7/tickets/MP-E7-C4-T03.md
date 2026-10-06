---
ticket_id: MP-E7-C4-T03
feature_id: MP-E7
chunk_id: MP-E7-C4
bucket: 2-platform
title: "Muse native steer: deliver steer-mode messages with MSP turn/steer"
status: blocked
blocked_by: [DESIGN-E7, MP-E7-C4-T02, MP-R7-C2-T02]
repo: aiur-team/aiur
wave: 4
prior_units: [U4]
prior_boundaries: [CA (20), RUN (18)]
prior_features: [MP-R7]
prior_findings: [MP-R7 plan F2 (muse row)]
size_owner: AGENT_TURN (muse/* has no dedicated U8 owner; files are < 500 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C4-T03 — Muse native steer through MSP `turn/steer`

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C4.
- **User value:** `steer` mode on a Muse agent lands a message inside the
  running turn without cancelling it; today an urgent Muse message cancels the
  turn (`muse/turn_loop.ex:85-97` → `TurnControl.interrupt/2`).
- **Deliverable:** `Aiur.Muse.CodingAgent.steer/3`, a
  `Protocol.turn_steer_frame/5`, result validation, the Muse turn loop's
  handling of the `:steer` wake value introduced by MP-E7-C4-T02, and
  `mid_turn_inject: :native` for `muse`.
- **Non-goals:** Muse `async` (C5 covers the tool; see Non-happy paths),
  changing the existing `ifBusy: "queue"` operator path
  (`muse/coding_agent.ex:21-27`).

## Dependencies and blockers

- **DESIGN-E7**; **MP-E7-C4-T02** (introduces the `:steer` wake value, the
  `steer_requested` item flag and `CheckpointDelivery.steer_claim_handler/4`);
  **MP-R7-C2-T02** (reserved `steer/3`).
- **May run concurrently with** C4-T04 and C5/C6 once C4-T02 has merged.

## Verified starting point (at `45a290e3`)

- Adapter: `send_operator_message/2` sends `turn/start` with
  `if_busy: "queue"` (`muse/coding_agent.ex:21-27`).
- Frames: `Protocol.turn_start_frame/4` maps `if_busy` → `"ifBusy"`
  (`muse/protocol.ex:50-59`); `turn_interrupt_frame/4` (`:61-66`).
  Receipts accept dispositions `started | queued | steered`
  (`muse/protocol.ex:86-91`).
- Turn loop state carries `session`, `turn_id`, `interrupt`
  (`muse/turn_loop.ex:10-28`); queue updates for this issue call
  `operator_wake(state, urgent)` (`:63-64`), which interrupts when `urgent`
  is truthy (`:85-97`) — a `:steer` atom is truthy, so **without this ticket
  a `:steer` wake would cancel the Muse turn.** This ticket must land before
  any Muse agent can have effective mode `steer` (enforced by the primitive
  staying `:none` until here).
- Registry: `providers/muse.ex` `safe_checkpoints: []`, `can_interrupt: true`,
  `resumable: true`.
- Tests: `src/test/aiur/muse/protocol_test.exs` (asserts `"ifBusy" =>
  "queue"` at `:62`), `src/test/aiur/muse/turn_test.exs`.

**RQ-E7-2 — resolved.** `muse schema generate-json-schema --out <dir>` with
**Muse Code 1.4.3 (1.4.3-R5018.1)** (run 2026-10-06; the help text states the
export "is exact for this binary") contains:

- `$defs/IfBusy` enum `["queue", "steer", "replace"]`, default `queue`.
- method `turn/steer`: "Injects input into the turn the caller names,
  failing if that turn is no longer active". `TurnSteerParams` requires
  `commandId` (UUIDv7 idempotency handle), `expectedTurnId` ("an id that is
  not the running turn is refused"), `input` (same parts as `turn/start`),
  `sessionId`; optional `reasoningEffort`. `TurnSteerResult` =
  `{commandId, status, turnId}`.
- `Item.properties.steered`: `userMessage` items carry `steered: true` when
  injected via `turn/steer` or `ifBusy: "steer"` — an observable `in_context`
  signal.

aiur pins no Muse version (`providers/muse.ex` install hint names none).

## Chosen design

- Use exact-target **`turn/steer`**, not `turn/start` with `ifBusy:
  "steer"`: the `expectedTurnId` precondition closes the turn-ended race
  (schema text), matching the Codex path in C4-T02.
- `Protocol.turn_steer_frame(id, session_id, turn_id, text, opts)` →
  `request(id, "turn/steer", %{"commandId" => command_id(), "sessionId" =>
  session_id, "expectedTurnId" => turn_id, "input" => [%{"type" => "text",
  "text" => text}]})`.
- `Protocol.turn_steer_result(result, command_id)` → `{:accepted, result}`
  when `status == "accepted"` and `turnId` is a binary, else
  `{:error, :invalid_turn_steer_receipt}`.
- `CodingAgent.steer(session, %{kind: :text, body: text}, expected_turn_id)`
  sends the frame via `Transport.send_frame/2`, returns `{:ok, %{request_id,
  command_id}}`.
- Turn loop: new clause before the generic one —
  `{:agent_queue_updated, issue_id, _item, :steer}` → `steer_wake(state)`:
  call `state.steer_claim.()` (new opt `:on_steer_claim`, default
  `fn -> :noop end`); on `{:deliver_text, text, ok, fail}` send the frame and
  keep `%{steer: %{request_id, command_id, ok, fail}}` in state. One steer in
  flight; further `:steer` wakes while one is pending are no-ops (the item
  stays pending and is retried on the next wake or at the boundary).
- `handle_frame` clause for the steer response id: accepted → `ok.(…)`;
  `{"error", _}` → `fail.(reason)` (restore to pending → turn boundary).
- Effective support `(muse, steer)` = `experimental` until the manual test
  passes, then `proven`.

## Implementation steps

1. `muse/protocol.ex`: `turn_steer_frame/5`, `turn_steer_result/2`.
2. `muse/coding_agent.ex`: `@impl true def steer/3`.
3. `muse/turn_loop.ex`: `:on_steer_claim` opt, `:steer` clause placed above
   `:63`, response clause, state key `steer: nil`.
4. `muse/turn.ex`: pass `on_steer_claim` from the runner opts into
   `TurnLoop.await/6` (`muse/turn.ex:45`).
5. Tests.

## Non-happy paths

- **Turn completed before the steer arrives:** MSP refuses (`expectedTurnId`
  not running) → restore → delivered as the next turn (sync semantics).
- **Pause while steer pending:** pause wins; the steer response may still be
  accepted (input absorbed before cancel). Treat accepted as delivered; the
  turn-end sweep consumes it. If the response never arrives before close,
  `close/2` fails it → restore (no loss, possible duplicate is prevented by
  the `commandId` only within Muse; aiur's restore makes the boundary drain
  re-send — **known edge**: a steer accepted by Muse whose response was lost
  could be delivered twice. Accept and document; MSP `commandId` idempotency
  cannot be reused for a different method.)
- **Muse `async`:** Muse sessions get aiur tools over session MCP
  (`muse/turn_loop.ex:4` aliases `Aiur.AgentTools.MCP`; `muse/protocol.ex:73`
  requires the `sessionMcp` grant), so `pull_tool` becomes `true` once
  MP-E7-C5-T01 registers the tool. Parent should update harness-adapter §3
  `muse pull_tool: RQ → yes (session MCP)`.

## Compatibility and rollout

No config. Dormant until routing is `:listener` and a Muse agent is set to
`steer`. Rollback: revert; primitive returns to `:none`, effective mode for
`steer` falls back per contract §4.

## Verification

- `muse/protocol_test.exs`: `"turn_steer_frame names the expected turn and
  carries a command id"` (exact keys); `"turn_steer_result rejects a receipt
  without turnId"`.
- `muse/turn_test.exs` (fake transport, existing pattern):
  `"steer wake sends turn/steer and does not interrupt"` — assert no
  `turn/interrupt` frame written. **Mutation:** delete the new `:steer`
  clause so the message falls to `operator_wake(state, :steer)` → the test
  fails because an interrupt frame is written.
  `"rejected steer restores the item"` — fake error response → `fail` called
  once.
- Harness contract test (MP-R7-C1-T01): `muse` reports
  `mid_turn_inject: :native`.
- Command: `env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec --
  mix test test/aiur/muse`.
- Manual (AGENTS.md wrapper-tmux recipe, `agent.routing` with `muse`): long
  task, `steer` mode, type in chat pane `0.1` mid-turn; expect the message in
  the pane before the turn ends and a transcript item with `steered: true`.

## Completion and handoff

- [ ] Tests and mutation check reported in the PR.
- [ ] Manual capture attached.
- [ ] Parent updates listener-mode §9 `muse steer: unknown → experimental
  (MSP turn/steer, Muse 1.4.3)` and `muse async: unknown → proven once
  read_messages exists (session MCP)`.
- Docs: none here (C7-T05).
