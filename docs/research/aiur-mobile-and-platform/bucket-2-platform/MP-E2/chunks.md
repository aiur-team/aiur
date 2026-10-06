---
feature_id: MP-E2
base_main_sha: 45a290e3
date: 2026-10-06
parent: plan.md
---

# MP-E2 — Chunks and candidate tickets

Every ticket cites `Prior-units: U6` (decisions) unless it says otherwise, and
`Prior-boundaries: DEC` (27) plus the listed extras. `Size-owner: DECISIONS` applies to any
edit of `decision_store.ex`, `decision_projection.ex` or `decision_validation.ex`. Those
edits stay minimal, and new logic goes in new files under `src/lib/aiur/commands/`
(proposed path).

**Gate legend.**

- **[D]** means blocked on DESIGN-E2 approval.
- **[B]** means backend only. It may start after its predecessors and MP-R2/MP-R7, per the
  wave order (D1).
- **[S]** means a Phase C spike must succeed first.

Wave: MP-E2 is wave 2 (`../../value-and-sequencing.md`). It depends on MP-R2's event
contract and MP-R7's adapter contract (plan §9 covers landing before R7).

---

## MP-E2-C1 — Command model v2: requester, origin, routing fields [B]

**Outcome:** the store can persist and project the NEW fields in contract §2–§4, accepts
Executor-originated Commands with no ticket, and warns on the 2–3 suggested-response rule.
No routing behaviour yet; every Command projects `route_state: with_human` (today's
effective behaviour).

**Dependencies:** none inside MP-E2. Cross-feature: MP-CT-identity (the `session_ref` and
`executor_id` shapes).

| Ticket | Scope |
| --- | --- |
| MP-E2-C1-T1 | Add `requester`, `origin`, `native`, `route_*`, `escalations`, `questions[]`, `short_label` to `Aiur.Decision` (`decision.ex`) as optional fields, with `payload_version: 2`. Make `ticket` nullable with `scope: :repo`, and audit every `decision.ticket` caller (`decision_dispatch.ex:65`, `blocked_ticket_ids`, dashboard presenters). |
| MP-E2-C1-T2 | Validation for v2: questions (1–4, options 2–4, header ≤12), `short_label` derivation, and the suggested-response rule as a warning plus a config flag `commands.require_suggested_responses` (default false). Config docs. |
| MP-E2-C1-T3 | New lifecycle event types `routed`, `human_needed`, `native_released` in `decision_projection.ex` (status-neutral), topics in `decision_store.ex:2633-2653`, and a rollback test proving an old reducer tolerates or rejects them predictably (R-Q4). |
| MP-E2-C1-T4 | Read API and `aiur commands --json` expose the new fields. Supervisor API response schema. |

**Tests:**
- Projection round-trip for v2.
- Replay of v1 logs unchanged (fixture: a current `decisions.ndjson` sample).
- `ticket: nil` paths in `blocked_ticket_ids` and expiry.
- A validation table.
- Each test is mutation-checked: revert the field and the test fails.

**Open research:** R-Q4 (rollback); whether `decision_id` for an Executor Command derives
from `executor_id::invocation`.

---

## MP-E2-C2 — Routing and escalation engine [B]

**Outcome:** `Aiur.Commands.Routing` assigns `route_policy` by D9 and escalates by the
contract §5 causes. It is restart-safe and emits `human_needed` once per Command.
Invariant N1 holds.

**Dependencies:** C1. Cross-feature: MP-R2 (topic registration for `human-needed`);
`Aiur.Executor.Roster` (existing).

| Ticket | Scope |
| --- | --- |
| MP-E2-C2-T1 | Pure policy `Routing.Policy.route/2` and `escalation_due/3`. Table tests over authority × reversibility × roster state × requester. |
| MP-E2-C2-T2 | The `Routing` GenServer: subscribe to `ticket.*.agent.decision.requested` and `executor.decision.requested`; record `routed`; run a periodic tick (30 s) that recomputes deadlines from durable `routed_at`; persist escalations through the store API; make them idempotent per `{id, version, cause}`. |
| MP-E2-C2-T3 | Roster integration: the `executor_offline` / `executor_stalled` causes; a roster-snapshot fixture; behaviour when the Executor's claim expires mid-deadline. |
| MP-E2-C2-T4 | Executor acknowledgement signal (R-Q3). Candidate: `executor-wait` delivery of the Command wake, plus `aiur commands <id>` by an Executor identity, plus an explicit `aiur executor-ack <id>`. CLI docs. |
| MP-E2-C2-T5 | Config `commands.escalation.executor_ack_ms`, `executor_answer_ms`, `urgent_factor` with schema, `configuration.md` and `check-config-docs`. Defaults come from DESIGN-E2 §6.1, so the defaults wait on the owner answer while the mechanism does not. |

**Tests:**
- Restart in the middle of a deadline: an overdue Command escalates once, and a second
  boot does not re-emit.
- `human_required` gives one immediate `human_needed`.
- The empty-roster path.
- Clock injection, with no sleeps.

**Open research:** the tick cadence versus the ExecutorWakeInbox debounce (2 000 ms); the
interaction with `decision_expiry.ex` (expiry must win over escalation for a dead ticket).

---

## MP-E2-C3 — Answer resolution and human supersede (D11) [B for store; D for UI]

**Outcome:** contract §6 rules 1–7 are enforced and visible: richer conflict payloads, a
human supersede path, and an Executor-over-human refusal.

**Dependencies:** C1. Coordinates with #3005 (`operator_relayed` actor).

| Ticket | Scope |
| --- | --- |
| MP-E2-C3-T1 [B] | Store: refuse an `:executor` supersede when the active answer's actor is human. Add the winning-answer summary to `{:conflict, {:already_decided, _}}` and map it in `decision_api_controller.ex:114-127` and `executor_command_cli.ex:253-261`. |
| MP-E2-C3-T2 [B] | API: `POST /api/v1/decisions/:id/supersede` (supervisor-auth). Or reuse `decide` with `supersede: true`; choose one in Phase C. CLI and API docs. |
| MP-E2-C3-T3 [D] | Dashboard supersede action with the undelivered guard, the "too late" state, and the "already answered by…" state (DESIGN-E2 §4.4). Relabel `/revise` "Send correction". |
| MP-E2-C3-T4 [D] | Stream Deck: show the conflict result for `answer_command` (no supersede on the deck unless DESIGN-E2 asks for it). |

**Tests:**
- A race test with two answers from two actors: exactly one `answer_recorded`.
- A human supersede after `delivered` gets `answer_delivered`.
- An Executor supersede of a human answer is refused.
- A duplicate key from two devices gets `:duplicate`.
- LiveView tests for the states.

**Open research:** whether an `operator_relayed` answer may itself be superseded by the
Executor (proposed: no; it is human).

---

## MP-E2-C4 — Native capture core and Codex [S][B]

**Outcome:** a Codex `item/tool/requestUserInput` that is a genuine question becomes a
Command and is held in-band. On answer, the reply is the native result. On hold failure,
it is released (contract §7.3). Approval-shaped requests are unchanged (D10).

**Dependencies:** C1, plus C2 for routing (it can ship with C2 off: `with_human`).
Cross-feature: MP-R7 adapter callbacks (contract §10). Spike R-Q1.

| Ticket | Scope |
| --- | --- |
| MP-E2-C4-T0 [S] | Spike: `codex-cli 0.160.0` with `features.default_mode_request_user_input=true` (or the Plan collaboration mode) through aiur's app-server. Capture real `requestUserInput` payloads as fixtures. Confirm the response shape and that there is no client timeout. Record findings. No production change. |
| MP-E2-C4-T1 | `Aiur.Commands.NativeCapture`: classify (approval-shaped → `:policy`, `isSecret` → release plus alert, otherwise a question), map questions to v2 `questions[]`, and `request` the Command with `origin: native_question` and trusted source. |
| MP-E2-C4-T2 | Codex path: replace the `false`-branch auto-answer at `codex/approvals.ex:260-262` with capture-and-hold behind a config gate `commands.native_capture.codex` (default false until the owner approves the feature-flag use). Keep the JSON-RPC id pending in the turn state, and add a `waiting_on_command` turn state that exempts it from stall detection. |
| MP-E2-C4-T3 | In-band delivery: `DecisionDispatch` picks `reply_native_question` when `native.hold == :in_band` and the adapter reports the request pending; otherwise message. Record `delivered` on the reply ack. |
| MP-E2-C4-T4 | Release paths: turn timeout, interrupt, pause and port exit answer the pending request with the release text if the port is alive, emit `native_released`, and keep the Command open. |
| MP-E2-C4-T5 | Codex launch config: pass the feature flag when the gate is on, and document it. |

**Tests:**
- Fixture-driven: a recorded requestUserInput gives one Command; answering gives the
  exact `{"answers": {...}}` frame.
- An approval fixture still auto-approves.
- A secret fixture is not persisted (grep the store files in a temp dir).
- Port-exit release.
- Manual: `aiurdev --test` per AGENTS.md.

**Open research:** R-Q1; whether `isBlocking: false` requests (outside Plan mode) should
be captured as non-blocking Commands.

---

## MP-E2-C5 — Claude native capture through `aiur-claude` [S][B]

**Outcome:** Claude's AskUserQuestion reaches aiur as `item/tool/requestUserInput`. The
`aiur-claude` side uses a permission host plus a `PreToolUse` defer and resume, and aiur
reuses C4's core.

**Dependencies:** C4-T1 and C4-T3. External repo `its-everdred/claude-app-server`
(npm `aiur-claude`). Spike R-Q2.

| Ticket | Scope |
| --- | --- |
| MP-E2-C5-T0 [S] | Spike: `claude -p` 2.1.291 with `--permission-prompt-tool` (an MCP tool on the existing aiur bridge) plus a `PreToolUse` AskUserQuestion hook returning `defer`, under `bypassPermissions`. Verify that `tool_deferred`, `deferred_tool_use`, the resume, and `allow`+`updatedInput.answers` all work, and that Bash, Edit and other permissions are not routed to the host (D10). |
| MP-E2-C5-T1 (aiur-claude) | Add the permission host and the defer hook. On `tool_deferred`, send `item/tool/requestUserInput` with stable question ids (a hash of the question text) and keep the thread awaiting. On the reply, resume with `allow`+answers. On the release text, resume with a `deny` message. Release a new `aiur-claude` version. |
| MP-E2-C5-T2 | aiur: add a `handle_method` clause for `item/tool/requestUserInput` in `claude/coding_agent.ex` (today it falls into the catch-all at `:385-399`) delegating to `NativeCapture`. Add a minimum `aiur-claude` version check through the provider install hint (`coding_agent/providers/claude.ex:19-21`). |
| MP-E2-C5-T3 | Multi-tool-call turns (defer ignored): detect it and release, so that no question is lost. |

**Tests:**
- A fake `aiur-claude` fixture emitting requestUserInput.
- A version-gate test.
- Manual run with a real Claude worker.

**Open research:** R-Q2. Whether an aiur-claude restart can resume a deferred session from
disk (the session survives, the thread map may not).

---

## MP-E2-C6 — Executor-originated Commands (D12) [B for store and CLI; D for UI]

**Outcome:** the Executor raises Commands through the same system, routed `human_only`.
Answers reach the Executor through its journal and wake, and through its session once
MP-E3 exists. `aiur ask` becomes an alias.

**Dependencies:** C1, C2. Cross-feature: MP-E3 (session injection, optional), U3 (wake
inbox API).

| Ticket | Scope |
| --- | --- |
| MP-E2-C6-T1 | CLI `aiur command request "<question>" [--option id=label …] [--recommend id] [--blocking] [--urgency] [--ticket N] [--context-file]`, with the actor and requester from the Executor identity (`Claims.resolve_consumer_id/1`). Launcher engine passthrough. `cli.md`. |
| MP-E2-C6-T2 | `Aiur.Commands.ExecutorDelivery`: on answer, publish `executor.decision.answered`. `executor-wait --json` shows it. Mark delivered on the cursor acknowledgement. |
| MP-E2-C6-T3 | `aiur ask` alias: writes a Command; `ask --done ID` maps to moot. Existing `ask_` records stay readable. Deprecation note in docs. |
| MP-E2-C6-T4 [D] | Dashboard "From Executor" filter and badge (DESIGN-E2 §6.6). |

**Tests:**
- Executor request, then dashboard answer, then `executor-wait` returns the answer.
- Restarting the Executor consumer still gets the answer once.
- `ask` alias parity.

**Open research:** the E3 injection hook shape (owned by the MP-E3 planner).

---

## MP-E2-C7 — Command surfaces: inbox, detail and CLI presentation [D]

**Outcome:** the dashboard, CLI and deck present routing, escalation, native multi-question
answers and suggested responses exactly as DESIGN-E2 §4–§5 specify.

**Dependencies:** C1–C3, plus DESIGN-E2 approval. Cross-feature: MP-E4 (conversation
anchor link), MP-E5 (mic placement).

| Ticket | Scope |
| --- | --- |
| MP-E2-C7-T1 | Inbox routing chips and filters (Needs you / With Executor / From Executor / Resolved); overview banner counts per DESIGN-E2 §6.2; fleet `Commands` column semantics. |
| MP-E2-C7-T2 | Detail view: escalation timeline, native multi-question form (single submit, multi-select, Other), and the recommended option first. |
| MP-E2-C7-T3 | Unit row "Waiting for your answer" while a native question is held (DESIGN-E2 §6.8). |
| MP-E2-C7-T4 | CLI `aiur commands` columns (route state, age, escalation cause) and `--filter needs-you`. |
| MP-E2-C7-T5 | Stream Deck compatibility: option keys for v2 single-question Commands; multi-question shows "answer on dashboard". |

**Tests:**
- LiveView render tests per state, including a mutation test for the unknown and stale
  branches (AGENTS.md).
- Browser check at mobile width.
- Manual `aiurdev --test`.

---

## MP-E2-C8 — Docs, skills, rollout [B]

**Outcome:** documentation and the Executor and agent skills match the behaviour. The
rollout flags flip in order.

**Dependencies:** C2–C7.

| Ticket | Scope |
| --- | --- |
| MP-E2-C8-T1 | `concepts/commands.md` (routing, escalation, native questions, supersede), `concepts/executor.md`, `reference/configuration.md`, `reference/cli.md`. |
| MP-E2-C8-T2 | `aiur-run` skill: Executor triage of `with_executor` Commands and deadlines, `executor-ack`, `command request`. Replace the "human answered; ingestion blocked" text with #3005's command if it has merged. |
| MP-E2-C8-T3 | `aiur-agent` skill: the 2–3 suggested responses guidance, and when to use a native ask versus `decision.requested`. Flip `commands.require_suggested_responses` after a census of current option counts in live `decisions.ndjson` (count and record it, per AGENTS.md "population counted"). |
| MP-E2-C8-T4 | Enable native capture by default per harness only after DESIGN-E2 approval and the owner decision on the Codex `UnderDevelopment` flag. |

---

## Chunk dependency summary

```text
C1 ──► C2 ──► C6
 │      └───► C7 (DESIGN-E2)
 ├──► C3 ───► C7
 └──► C4 ──► C5
C2..C7 ──► C8
External: MP-R2 (topics) → C1-T3/C2; MP-R7 (adapter) → C4/C5; MP-E3 → C6 (optional); #3005 → C3
```

May run concurrently: C3 with C2; C4-T0 and C5-T0 spikes at any time (research only).
