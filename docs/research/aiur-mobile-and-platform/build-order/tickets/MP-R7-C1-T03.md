---
ticket_id: MP-R7-C1-T03
feature_id: MP-R7
chunk_id: MP-R7-C1
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Provider-frame golden tests for operator-message delivery
status: ready
blocked_by: [DESIGN-R7]
prior_units: [U4]
prior_boundaries: [CDX (21), CLD (22), OAI (23)]
prior_features: []
prior_findings: [MP-R7 plan F2; RQ-R7-4 resolved here]
size_owner: n/a (new test file and fixtures only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C1-T03 — Provider-frame golden tests for operator-message delivery

## Identity and outcome

- Bucket 1, MP-R7, chunk C1, ticket T03.
- **User value:** none visible. Fixes the exact bytes each harness receives
  for an operator message, so the C4 package move and the MP-E7-C4 steer work
  cannot change them unnoticed.
- **Deliverable:** one golden-fixture test plus JSON fixtures for the
  app-server and MSP frames that are not yet pinned; tag the existing REPL and
  OpenAI-compat tests that already pin theirs.
- **Non-goals:** no new delivery path; no `turn/steer` frame (MP-E7-C4).

## Dependencies and blockers

- Blocked by **DESIGN-R7**. No predecessor. Concurrent with C1-T01/T02, C5-T01.
- Dependents: C1-T04, the C4 package-move tickets, MP-E7-C4.

## Verified starting point (base `45a290e3`)

| Harness | Frame builder | Existing test | Gap |
| --- | --- | --- | --- |
| codex | `codex/frames.ex:92-105` via `codex/operator_delivery.ex:10-23` | `codex/frames_test.exs:56-73` asserts every key | none (tag only) |
| claude (headless) | inline map, `claude/coding_agent.ex:114-139` (`turn/start`, `threadId`, `input`, `cwd`, optional `model` via `maybe_put_model`) | `claude/coding_agent_test.exs:363-370` covers only the closed-port error | **frame shape unpinned** |
| muse | `muse/coding_agent.ex:21-27` → `muse/protocol.ex:50-59` with `if_busy: "queue"` → `"ifBusy"` | `muse/protocol_test.exs` tests receipts and session frames, not the operator frame | **`ifBusy: "queue"` unpinned** |
| claude-repl | `claude/repl/operator_inject.ex:31-43`, sanitizer :103-108 | `claude/repl/operator_inject_test.exs:21-49` asserts sanitized literal + Enter | none (tag only) |
| openai-compat | runtime delivery is **not** `send_operator_message/2`; it is `OpenAICompat.Checkpoint.deliver/3` and `defer/4`+`flush/3` (`open_ai_compat/checkpoint.ex:4-78`) called at `response/completed` and after every tool result (`open_ai_compat/coding_agent.ex:166-175,222-244`) | `open_ai_compat/coding_agent_test.exs:24,503,638` | none (tag only) |

Facts found while checking: `CodingAgent.send_operator_message/2`
(`coding_agent.ex:1157-1160`) has no production caller; the only runtime
caller of an adapter's `send_operator_message/2` is the app-server safe
checkpoint (`app_server/operator_delivery.ex:60`, Codex/Claude) and the REPL
immediate path (`operator_inject.ex:79`). So the Muse and OpenAI-compat
`send_operator_message/2` clauses are currently unreachable from delivery;
Muse delivers queued operator text by starting the next turn from the runner
drain, and urgent wakes interrupt (`muse/turn_loop.ex:63-64,85-96`). Pin the
Muse frame anyway: MP-E7-C4-T03 (Muse steer) starts from it.

**RQ-R7-4 resolved:** OpenAI-compat already delivers a queued operator item
*inside* the running turn without cancelling it, after each tool result
(`Checkpoint.defer` per result, `flush` after the batch,
`coding_agent.ex:226-244`) and at the completion checkpoint, which continues
the loop (`:166-170`). Proven by `coding_agent_test.exs:638`
("checkpoint messages follow every result in a multi-tool batch"). Hence
`mid_turn_inject: :native` for OpenAI-compat in C2-T01.

## Chosen design

Golden fixtures stored as JSON so later moves compare bytes, not Elixir maps:
`src/test/fixtures/harness_frames/{claude_operator_turn_start,muse_operator_turn_start}.json`
(PROPOSED). The test builds the frame through the real adapter with a port
stand-in, decodes, and compares with the fixture after replacing volatile
fields (`id`, Muse `commandId`) with the fixture's placeholders.

Capturing the Claude frame: `send_operator_message/2` writes to a port. Use the
existing fake app-server harness in `claude/coding_agent_test.exs`
(`fake_app_server/1` writes received frames to `frames.jsonl`, used at :360)
and read the last `turn/start` line, as :68 already does for the first turn.

Capturing the Muse frame: call `Aiur.Muse.Protocol.turn_start_frame/4` with
the same arguments `muse/coding_agent.ex:24` passes (`if_busy: "queue"`) and a
fixed `command_id:`; plus one test that `Muse.CodingAgent.send_operator_message/2`
writes that frame through `Aiur.Muse.Transport.send_frame/2` (use the
transport's existing test double if present; if none, a port opened on
`cat > file`, as the Claude fake does).

## Implementation steps

1. Add `src/test/aiur/harness_frames_golden_test.exs` (PROPOSED) with
   `@moduletag :r7_characterization`.
2. Add the two fixtures (hand-written from the code above, then confirmed by
   the test).
3. Add `@moduletag :r7_characterization` to `codex/frames_test.exs`,
   `claude/repl/operator_inject_test.exs` and
   `open_ai_compat/coding_agent_test.exs` (test-only diff, one line each).

## Non-happy paths

- Missing `thread_id` or closed port: existing tests cover `{:error, :invalid_session}`
  / `{:error, :port_closed}`; not duplicated.
- Empty Muse text is rejected by the guard (`muse/coding_agent.ex:22`); one row.
- Claude `model` present vs absent: two fixtures rows (`maybe_put_model`).

## Compatibility and rollout

n/a — test-only.

## Verification

Tests (pass on `45a290e3`, regression guards by design):

- `claude headless operator message is a turn/start with threadId, input and cwd`
- `claude headless operator message carries the session model when set`
- `muse operator message is a turn/start with ifBusy queue`
- `muse send_operator_message writes the golden frame to the transport`

Command (from `src/`):
`mise exec -- mix test test/aiur/harness_frames_golden_test.exs test/aiur/codex/frames_test.exs test/aiur/claude/repl/operator_inject_test.exs test/aiur/open_ai_compat/coding_agent_test.exs`

Mutation witnesses (worktree, porcelain shows only the hunk):

- `muse/coding_agent.ex:24` `if_busy: "queue"` → `"steer"`: muse tests fail.
- `claude/coding_agent.ex:129` drop `"cwd"`: claude test fails.
- `open_ai_compat/coding_agent.ex:227-232` remove the `Checkpoint.defer` call:
  existing `checkpoint messages follow every result in a multi-tool batch`
  fails (confirms the tagged test guards RQ-R7-4's evidence).

## Completion and handoff

- [ ] New test + 2 fixtures; 3 existing files tagged.
- [ ] Mutation witnesses recorded in the PR body.
- [ ] PR body states RQ-R7-4's answer with the test name.
- Docs: none.
- Dependents: C1-T04, C2-T01 (uses the RQ-R7-4 result), MP-E7-C4.
