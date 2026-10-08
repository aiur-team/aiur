---
ticket_id: MP-E7-C4-T02
feature_id: MP-E7
chunk_id: MP-E7-C4
bucket: 2-platform
title: "Codex native steer: deliver steer-mode messages with turn/steer"
status: blocked
blocked_by: [DESIGN-E7, MP-E7-C3-T02, MP-E7-C3-T03, MP-R7-C2-T01, MP-R7-C2-T02]
repo: aiur-team/aiur
wave: 4
prior_units: [U3, U4]
prior_boundaries: [MSG (16), RUN (18), CA (20), CDX (21)]
prior_features: [MP-R7]
prior_findings: [MP-R7 plan F3, F4; MP-E7 plan E7-F2]
size_owner: AGENT_TURN (app_server/*), CODEX (codex/*)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C4-T02 — Codex native steer through `turn/steer`

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C4 native steer primitives.
- **User value:** with an agent in `steer` mode, a message sent mid-turn
  reaches a Codex agent inside the running turn, without cancelling the work
  in flight. Today the only urgent path is `turn/interrupt` then a new turn
  (`app_server/interrupts.ex:40-53`), which throws work away.
- **Deliverable:** (1) the shared app-server steer path (one new wake value,
  one new `OperatorDelivery` branch, one new response clause), (2) the Codex
  adapter's `steer/3` callback and frame, (3) `mid_turn_inject: :native` for
  `codex` in the derived delivery primitives, which makes the effective mode
  `steer` (support `experimental`) instead of `emulated_interrupt`/`sync`.
- **Non-goals:** headless Claude (no native steer; MP-E7-C4-T01 records why),
  Muse (C4-T03), `claude-repl` (C4-T04), any UI (C7). No change to Command
  answers or orchestrator digests — they keep `interrupt_requested`
  (contract §2).

## Dependencies and blockers

- **DESIGN-E7** (feature gate). Steer is only reachable once a mode can be set
  (C2) and routing honours it (C3); default `:listener_send_routing` stays
  `:legacy` until MP-E7-C7-T04, so this path is dormant in production until
  then.
- **MP-E7-C3-T02** (DeliveryPolicy respects modes) and **MP-E7-C3-T03**
  (entry points enqueue `:listener` items with `listener_mode_at_claim`).
- **MP-R7-C2-T01** (`delivery_primitives/1`) and **MP-R7-C2-T02** (reserved
  optional `steer/3` callback in `Aiur.CodingAgent.Backend`).
- **May run concurrently with** C4-T03, C4-T04, C5-*, C6-*. It touches
  `app_server/operator_delivery.ex` and `app_server/turn_loop.ex`; C4-T03
  touches only `muse/*`, so no file conflict. C4-T03 reuses the wake value
  this ticket introduces — land this first or agree the atom (`:steer`).

## Verified starting point (at `45a290e3`)

- Wake decision: `DeliveryPolicy.notify_running_queue_update/3` sends
  `{:agent_queue_updated, identifier, item_id, deliver_now?}` where
  `deliver_now?` is a boolean (`orchestrator/operator_messages/delivery_policy.ex:50-60,124-143`).
- App-server loop: `{:agent_queue_updated, id, _item, true}` →
  `Interrupts.handle_operator_queue_update/2` → `turn/interrupt`
  (`app_server/turn_loop.ex:31-33`, `app_server/interrupts.ex:40-53`). Any
  other value is ignored (`turn_loop.ex:35-37`).
- Single-writer lock: no checkpoint claim while `outstanding_turns > 0`
  (`app_server/operator_delivery.ex:41-51`). Codex checkpoints:
  `item/tool/call` → `%{kind: :tool_result}`, else `%{kind: :notification}`
  (`codex/notification_policy.ex:40-42`), invoked from
  `codex/notifications.ex:55-98`.
- Active turn id: `state.current_turn_id` (`app_server/adapter.ex:117`, used
  by `interrupts.ex:19,41`).
- Operator response handling expects `result.turn.id`
  (`app_server/operator_delivery.ex:78-111`); an error response restores the
  item through `on_failure` (`:113-125`).
- Frames: `Aiur.Codex.Frames.operator_turn_frame/3` builds `turn/start`
  (`codex/frames.ex:92-104`); there is no `turn/steer` frame.
- Claim callbacks: `CheckpointDelivery.safe_checkpoint_handler/5`
  (`agent_runner/checkpoint_delivery.ex:67-78`); restore on failure via
  `Aiur.Orchestrator.restore_queue_item_pending/2` (`:53-56`).
- Tests: `src/test/aiur/app_server/operator_delivery_test.exs`,
  `src/test/aiur/app_server/interrupts_test.exs`,
  `src/test/aiur/codex/frames_test.exs`, `src/test/aiur/codex/turn_loop_test.exs`.

**RQ-E7-1 — resolved with evidence.**

- aiur pins no Codex version (`git grep` of `src/lib`, `packaging`,
  `mise.toml` at `45a290e3` finds none; `providers/codex.ex:21`
  `default_command: "codex app-server"`). Installed locally: `codex-cli
  0.160.0`.
- Schema: `codex app-server generate-json-schema --out <dir>` with codex-cli
  0.160.0 (run 2026-10-06; reproduces byte-for-byte the scratchpad copy
  `codex-schema/v2/TurnSteerParams.json`). `TurnSteerParams` requires
  `threadId`, `input: UserInput[]`, `expectedTurnId` ("Required active turn id
  precondition. The request fails when it does not match the currently active
  turn."); optional `clientUserMessageId`. `TurnSteerResponse` is
  `{ "turnId": string }`. `turn/steer` is in the v2 `ClientRequest` set, not
  behind an experimental flag in this schema.
- Docs (https://learn.chatgpt.com/docs/app-server, accessed 2026-10-06; a
  hosted page with no version pin, T-11. **Re-verify at implementation start**
  against the `openai/codex` repository at a pinned SHA — the app-server
  protocol source under `codex-rs/app-server-protocol/` — and cite that
  SHA in the PR; the generated schema above stays the primary evidence):
  fails when there is no active turn or `expectedTurnId` does not match;
  "turn/steer doesn't emit a new turn/started notification"; no turn-level
  overrides (model, cwd, sandboxPolicy, outputSchema).
- **Still unverified:** whether steered input emits a `userMessage` item event
  (the docs page does not say). This only affects transcript anchoring
  (MP-E4); the receipt stays `harness_queued` until an `in_context` signal is
  proven. The manual test below records the answer.

## Chosen design

1. **Wake value.** `DeliveryPolicy.wake_now?/2` (`delivery_policy.ex:139-143`;
   the private `deliver_now?/3` calls it for unpaused entries at :133-137 and
   passes its value through unchanged) returns the atom `:steer`
   (instead of `true`) when the item was claimed under effective mode `steer`,
   the running entry's `delivery_primitives.mid_turn_inject == :native`, and a
   turn is active (`not no_active_turn?/1`). Idle → `true` (start a turn now,
   contract §3 rule 1). Paused rules unchanged (`delivery_policy.ex:124-137`).
   Backends that do not know `:steer` hit their catch-all clause and ignore it,
   so the message falls back to the turn boundary — safe by construction.
   The queue item records the intent as `delivery: %{steer_requested: true}`
   (set by the C3 `:listener` builder; this ticket adds the key).
2. **App-server loop.** New clause in `Aiur.AppServer.TurnLoop.receive_loop/2`:
   `{:agent_queue_updated, id, _item, :steer}` →
   `OperatorDelivery.steer_pending(session, state)`.
3. **`OperatorDelivery.steer_pending/2`** (new). Bypasses the single-writer
   lock deliberately: `turn/steer` does not start a second writer (no new
   `turn/started`), which is the hazard the lock guards
   (`operator_delivery.ex:42-47`). It calls `state.on_steer_claim.()`
   (new callback, built in `TurnCallbacks.build/3` from a new
   `CheckpointDelivery.steer_claim_handler/4`, which claims only
   `steer_requested` items). On `{:deliver_text, text, ok, fail}` it calls
   `state.backend.steer(session, %{kind: :text, body: text},
   state.current_turn_id)` and records the request in
   `pending_operator_requests` with `kind: :steer`. A second steer while one
   is pending is held (one in flight per turn).
4. **Response handling.** New `handle_claimed_operator_response` clause for
   `%{"result" => %{"turnId" => turn_id}}` with `kind: :steer`: call
   `on_success` (item → `:delivered`, receipt `harness_queued`), emit
   `:operator_steered` with the turn id. Do **not** call
   `record_accepted_provider_turn` (no new turn).
5. **Fallback.** Error response (`-32600` / no active turn / mismatch) →
   `on_failure` → `restore_queue_item_pending`; the item is delivered at the
   turn boundary by the existing drain, i.e. as `sync`. Log
   `steer_fallback reason=…`. Never escalate to `turn/interrupt`
   (contract §1: cancellation is not a mode).
6. **Codex adapter.** `Aiur.Codex.CodingAgent.steer/3` (optional callback
   from MP-R7-C2-T02) builds `Frames.turn_steer_frame(session, request_id,
   text, expected_turn_id)` →
   `%{"method" => "turn/steer", "id" => id, "params" => %{"threadId" =>
   session.thread_id, "input" => [%{"type" => "text", "text" => text}],
   "expectedTurnId" => expected_turn_id}}` and sends it with the existing
   `send_frame`. Returns `{:ok, id}` | `{:error, :no_active_turn}` when
   `expected_turn_id` is nil.
7. **Primitives.** `codex` reports `mid_turn_inject: :native` once its
   adapter exports `steer/3` (MP-R7-C2-T01 owns the derivation; R7 already
   reports `:native` for OpenAI-compat, whose tool loop inserts operator text
   after each tool result, `open_ai_compat/coding_agent.ex:222-244`, so no C4
   ticket is needed there). Claude headless never exports `steer/3`.
   Module names follow R7 (no `Aiur.Harness.*` rename): `Aiur.CodingAgent.*`,
   `Aiur.AgentTools.*`.

State transition for a steer item:
`pending (steer_requested) → [claim] delivered (in-flight steer) →
{turnId ok} delivered/harness_queued → [turn end sweep] consumed` or
`→ {error} pending → [turn boundary drain] delivered → consumed`.

## Implementation steps

1. `delivery_policy.ex`: `wake_now?/2` returns `:steer` per rule 1; add
   `@spec` update (`boolean() | :steer`).
2. C3 `:listener` builder (in `agent_queue.ex`): set `steer_requested: true`
   when the claim-time effective mode is `steer` and primitive is `:native`.
3. `agent_runner/checkpoint_delivery.ex`: `steer_claim_handler/4` (claims
   `steer_requested` pending items only; reuses `immediate_operator_delivery/5`).
   File is 1 module; keep the addition < 40 lines.
4. `agent_runner/turn_callbacks.ex`: add `on_steer_claim` to the map;
   `app_server/adapter.ex`: thread it into loop state next to
   `on_safe_checkpoint` (`adapter.ex:52-58,111`).
5. `app_server/turn_loop.ex`: `:steer` clause.
6. `app_server/operator_delivery.ex`: `steer_pending/2` + response clause.
7. `codex/frames.ex`: `turn_steer_frame/4`; `codex/coding_agent.ex`:
   `@impl true def steer/3`.
8. Tests below.

## Non-happy paths

- **Race: turn ends between claim and steer** → Codex rejects
  (`expectedTurnId` mismatch / no active turn) → restore → turn-boundary
  delivery. Exactly once: the restore happens before the drain claims.
- **Turn interrupted for pause while a steer is pending:** the pending steer's
  error/absent response is failed by
  `TurnState.fail_pending_operator_requests/2` (`turn_state.ex:9`) → restore.
- **Fallback transport / RC promotion:** the running entry's primitives
  decide; Codex has neither. Effective mode recompute is MP-E7-C2-T04.
- **Turn-level overrides:** none are sent (docs forbid them on steer).
- **Gemini/ACP (RC-22, draft PR #2870 head `c1fc6f84`, unmerged):** if it
  merges, its adapter has no non-cancelling input (urgent update → ACP
  `session/cancel` then a new turn, `gemini/turn.ex:103-112,220-223` at that
  head). It does not export `steer/3`, so `:steer` never reaches it and its
  `steer` stays `emulated_interrupt`-only. No Gemini steer ticket in C4.
- **Privacy:** steer text is not logged beyond the existing 500-byte preview in
  `AgentChat` (`agent_chat.ex:32,63-65`).

## Compatibility and rollout

No config key. Dormant until a mode can be `steer` and routing is
`:listener` (C3-T03 flag, flipped by C7-T04). Rollback: revert; `:steer`
values stop being produced and every item falls back to the boundary drain.
Support status for `(codex, steer)` = `experimental` until the manual test
below passes on a tagged Codex version, then `proven` (recorded in the shared
support map via MP-E7-C1-T05).

## Verification

New/extended ExUnit tests:

- `delivery_policy_test.exs` — `"steer item with native primitive mid-turn
  wakes with :steer"`; `"steer item while idle wakes with true"`;
  `"steer item on harness without native primitive never yields :steer"`.
  Mutation: make `wake_now?/2` return `true` for steer items → first test
  fails.
- `app_server/operator_delivery_test.exs` — `"steer_pending sends turn/steer
  with current_turn_id while outstanding_turns > 0"` (asserts the exact frame
  through a fake backend); `"steer response with turnId marks delivered and
  does not register a new provider turn"` (asserts `outstanding_turns`
  unchanged); `"steer error restores the item to pending"`. Mutation: route
  `steer_pending/2` through `maybe_process_safe_checkpoint/3` → first test
  fails (lock returns state unchanged).
- `app_server/turn_loop` (in `src/test/aiur/codex/turn_loop_test.exs`) —
  `"agent_queue_updated :steer does not send turn/interrupt"`. Mutation: map
  `:steer` to `Interrupts.handle_operator_queue_update/2` → fails.
- `codex/frames_test.exs` — `"turn_steer_frame carries threadId, input and
  expectedTurnId"` (exact map equality).
- Harness contract test from MP-R7-C1-T01 — `codex` reports
  `mid_turn_inject: :native`.

Commands (do not run `mix test` against a live HOME; per AGENTS.md memory,
isolate HOME and unset GH tokens):
`env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test
test/aiur/orchestrator/operator_messages test/aiur/app_server
test/aiur/codex/frames_test.exs test/aiur/codex/turn_loop_test.exs`.

Manual (AGENTS.md "Manual testing", wrapper-tmux recipe, `aiurdev --test`
with `:listener_send_routing` set to `:listener` in a dev config): set a Codex
agent to `steer`, give it a long multi-tool task, open its chat pane (`0.1`),
type a message mid-turn. Expected in `capture-pane`: the message appears
before the turn completes; no "interrupted" marker; the agent's next tool call
reflects it. Record whether a `userMessage` item appeared (closes the open
part of RQ-E7-1).

## Completion and handoff

- [ ] Tests above green; mutation checks reported in the PR body.
- [ ] Manual capture attached to the PR.
- [ ] Parent updates harness-adapter §3 (`codex mid_turn_inject: native`,
  derived from `steer/3`) and listener-mode §9 (`codex steer: experimental via
  turn/steer; falls back to sync on rejection`).
- Docs: none in this ticket (C7-T05 documents modes).
- Dependents: C4-T03 (reuses `:steer`), C7-T01 (shows steer as native).
