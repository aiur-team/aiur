---
ticket_id: MP-R7-C1-T02
feature_id: MP-R7
chunk_id: MP-R7-C1
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Delivery-policy matrix characterization (entry point x harness)
status: ready
blocked_by: [DESIGN-R7]
prior_units: [U4]
prior_boundaries: [MSG (16), RUN (18), CA (20)]
prior_features: []
prior_findings: [MP-R7 plan F3, F4; new finding R7-C1-F1 (control flags taken from the dispatched backend, not the running transport)]
size_owner: n/a (new test files only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C1-T02 — Delivery-policy matrix characterization

## Identity and outcome

- Bucket 1, MP-R7, chunk C1, ticket T02.
- **User value:** none visible. Pins *who chooses* delivery today, so MP-E7-C3
  (which replaces sender-chosen policy with the listener mode) and every R7
  move can prove what changed and what did not.
- **Deliverable:** two test files: (a) entry-point defaults — the payload each
  sender puts on the wire; (b) the normalization matrix from requested policy ×
  running-entry control flags → queue item `delivery` map and wake decision.
- **Non-goals:** no production change; no listener mode; no fix for R7-C1-F1
  (recorded below, owned by MP-E7-C2-T04).

## Dependencies and blockers

- Blocked by **DESIGN-R7**. No predecessor. Concurrent with C1-T01, C1-T03,
  C5-T01.
- Consumed by MP-E7-C3 (its "non-message rows unchanged" proof, RC-05) and
  by C1-T04 (suite tag).

## Verified starting point (base `45a290e3`)

Entry points and the policy each sends:

| Entry point | Code | Policy sent |
| --- | --- | --- |
| `AgentChat.send/3` default | `agent_chat.ex:27-28` | `:interrupt`, fallback `:queue_next` |
| Dashboard drawer | `aiur_web/live/dashboard_live.ex:2689-2694` | none → AgentChat default (passes only `message_id`) |
| Stream Deck | `aiur_web/streamdeck_channel.ex:464-469` | none → AgentChat default |
| `aiur message` CLI | `agent_control_cli.ex:1478-1482` | none → AgentChat default |
| HTTP `POST /api/v1/:id/messages` | `observability_api_controller.ex:186-193` | omits policy → `operator_messages.ex:572` default `:checkpoint` |
| TUI OpenCode pane | `opencode/chat_completions/operator_dispatch.ex:46-50` | `:auto` |
| Decision answer | `decision_dispatch.ex:51-63` | `:interrupt`, `:queue_next` (correlated path) |
| Decision revision | `decision_revision_dispatch.ex:128` | `:interrupt` |

Normalization: `orchestrator/operator_messages/delivery_policy.ex:14-48`;
capabilities read from the running entry's `:control` map
(`operator_messages/capabilities.ex:45-54`, accepted sets :79-81); item builder
`agent_queue.ex:6-32`; enqueue path `operator_messages.ex:791-811`; wake
decision `delivery_policy.ex:50-62,124-143,177-185`.

**New finding R7-C1-F1.** The `:control` delivery flags are computed once, at
dispatch, from `CodingAgent.backend_for(issue)` (`orchestrator/dispatcher.ex:2549,2660-2672`),
which is the *requested* backend. The running transport can differ:
(a) a failed `claude-repl` spawn falls back to `claude`
(`agent_runner/session_lifecycle.ex:955-988`); (b) remote control on a
`claude` route runs on `claude-repl` (`session_lifecycle.ex:661,868-870`), and
`model:remote` selects no backend (`coding_agent.ex:53`, test
`coding_agent_test.exs:220-226`). The real transport arrives later as
`running_entry.session_execution.backend` (`orchestrator/state.ex:441-461`,
sent by `session_lifecycle.ex:33-47`) but `:control` is never recomputed.
Consequence today: a TUI (`:auto`) message to a REPL that fell back to headless
Claude is normalized to `:immediate`, and `deliver_now?` then makes the
app-server loop send `turn/interrupt` (`app_server/turn_loop.ex:31-33`,
`app_server/interrupts.ex:40-53`) — a hard cut where the pane expected a native
queue. R7 is behaviour-preserving, so this ticket **pins** it with a test named
for the defect; MP-E7-C2-T04 (recompute on transport change) changes it and
must update that row.

Existing coverage (checked): `delivery_policy_test.exs:7-38` covers
`normalize_delivery_request/3`; `capabilities_test.exs:8-65` covers accepted
sets; `agent_queue_test.exs:93-127` covers item flags. **Not covered:** any
entry point's chosen policy (`agent_chat_test.exs:15-18` only checks an error
reply), the composed matrix, and R7-C1-F1. T02 adds only those.

## Chosen design

1. `src/test/aiur/delivery_entry_points_test.exs` (PROPOSED), `async: false`.
   Reuse the recording-fake pattern of `agent_chat_broadcast_test.exs:6-56`
   (re-register `Aiur.Orchestrator` to a GenServer that records the
   `{:send_operator_message, id, payload}` call and replies `{:ok, 1}`).
   - AgentChat default: call `AgentChat.send("MT-R7", "x")`; assert recorded
     payload has `delivery_policy: :interrupt, fallback: :queue_next`.
   - OpenCode: `OperatorDispatch.send_operator/3` (public, tested at
     `operator_dispatch_test.exs:79-80`) with real text; assert `:auto`.
   - Dashboard / Stream Deck / CLI: inject `:agent_chat_send_fun` (Endpoint
     config) or `:agent_control_cli_message_fun` (app env) as a 3-arity fun that
     records opts; assert opts are exactly `[message_id: _]` (no policy), so the
     AgentChat default governs. Existing tests already use these seams; follow
     their setup.
   - HTTP: put `Endpoint.config(:orchestrator)` (`observability_api_controller.ex:159-161`)
     to the recording fake; POST via `Phoenix.ConnTest`; assert payload has no
     `:delivery_policy` key.
   - DecisionDispatch: pass `send_fun:` (`decision_dispatch.ex:40`) that
     records; assert `delivery_policy: :interrupt, fallback: :queue_next`.
2. `src/test/aiur/orchestrator/operator_messages/delivery_matrix_test.exs`
   (PROPOSED), `async: true`. Table over
   requested ∈ {`:auto`, `:checkpoint`, `:interrupt`, `:immediate`} ×
   control profile ∈ {codex, claude, claude-repl, muse, openai-compat, fake},
   where each profile is built **from the registry entry** exactly as
   `dispatcher.ex:2660-2672` does (`CodingAgent.can_interrupt?/1`,
   `safe_checkpoints/1`, `immediate_delivery?/1`). Through
   `OperatorMessages.send_operator_message_call/3` on a `%State{}` with one
   running entry (fixture helper as `capabilities_test.exs`), assert:
   normalized policy or error, queue item `delivery` map
   (`priority`, `consume_at`, `interrupt_requested`, `immediate`, `fallback`),
   and the `{:agent_queue_updated, id, item_id, deliver_now?}` message received
   by a test pid standing in for the runner (`pid:` in the entry) for running
   entry states `:working` with an active turn, `:working` idle, `:sleeping`,
   `:paused`.
3. R7-C1-F1 rows: profile `claude-repl` control flags with
   `session_execution.backend = "claude"` and requested `:auto` → item
   `immediate: true`, `deliver_now? = true`. Test name states the defect.

## Implementation steps

1. Add both files with `@moduletag :r7_characterization`.
2. Write the fixture table as a module attribute list of maps
   `%{harness:, requested:, entry_state:, expect: %{...}}`, one assertion loop
   that reports every mismatching row.
3. For active-turn rows, register an active turn with `Aiur.Opencode.ActiveTurns`
   as `delivery_policy_test.exs` does (it aliases `ActiveTurns`, :4).
4. No production changes.

## Non-happy paths

- `:immediate` requested on a non-immediate profile → `{:error, :immediate_not_supported}` row.
- `:interrupt` with no fallback on a non-interruptible profile (OpenAI-compat)
  → `{:error, :interrupt_not_supported}`; with `:queue_next` → `:checkpoint`.
- Paused entry: `deliver_now?` false unless `paused_reason: :agent_pause_request`
  and no pending pause (`delivery_policy.ex:124-131`) — one row each.
- No running entry → `{:error, :no_running_agent}` (`operator_messages.ex:600-602`).
- Global-name swap must restore `Aiur.Orchestrator` (copy the cleanup helper).

## Compatibility and rollout

n/a — test-only.

## Verification

Tests and expectations (all pass at `45a290e3`):

- `AgentChat.send defaults to interrupt with queue_next fallback`
- `dashboard, Stream Deck and aiur message pass no delivery policy`
- `HTTP messages endpoint leaves the checkpoint default`
- `TUI chat pane requests auto`
- `Decision answers request interrupt with queue_next fallback`
- `delivery matrix: requested policy x harness profile x entry state`
- `R7-C1-F1: control flags follow the dispatched backend, not the running transport`

Commands (from `src/`):
`mise exec -- mix test test/aiur/delivery_entry_points_test.exs test/aiur/orchestrator/operator_messages/delivery_matrix_test.exs`

**Regression guards** (pass on main by design). Mutation witnesses, run in a
worktree with `git status --porcelain` showing only the hunk:

- `agent_chat.ex:27` `:interrupt` → `:checkpoint`: entry-point default test fails.
- `operator_messages.ex:572` `:checkpoint` → `:interrupt`: HTTP test and matrix rows fail.
- `delivery_policy.ex:18-20` `:auto` → `:interrupt`: matrix `:auto` rows fail.
- `agent_queue.ex:22` `consume_at` swap: matrix item-map assertions fail.
- In `operator_messages/capabilities.ex:47`, read `immediate_delivery` from
  `CodingAgent.immediate_delivery?(running_entry.session_execution.backend)`
  when present (a production edit, not a fixture edit): the R7-C1-F1 test fails.
  This proves the test reaches the defect, not only the fixture.

## Completion and handoff

- [ ] Two test files, tagged, green on main; five mutation witnesses in PR body.
- [ ] R7-C1-F1 recorded in the PR body and linked from MP-E7-C2-T04.
- Docs: none (test-only).
- Dependents: C1-T04, C2-T03 (byte-identical check reuses the profiles),
  MP-E7-C3-T03 (updates the entry-point rows deliberately).
