---
ticket_id: MP-E2-C2-T03
feature_id: MP-E2
chunk_id: MP-E2-C2
bucket: 2-platform
title: Routing process — route, escalate on deadlines and roster, survive restarts
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C2-T01, MP-E2-C2-T02, MP-E2-C2-T05]
prior_units: [U6, U3]
prior_boundaries: [DEC #27, EXE #26]
prior_features: [MP-R2 (RC-08 topic), MP-N4/N5]
prior_findings: [RC-18 (#2819), baseline § E2 "vanish" risk, plan §1.2, contract §4–§5]
size_owner: "n/a for the new module; DECISIONS for the one-guard edit in decision_store.ex handle_defer"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C2-T03 — Routing process: route, escalate, survive restarts

## Identity and outcome

- Bucket 2, MP-E2, chunk C2.
- **User value:** a Command the Executor ignores, or that arrives while the Executor is
  stalled or gone, reaches the human on time and exactly once — even across a daemon
  restart. This closes the "vanish" risk (plan §1.2: no Executor-to-human timeout today).
- **Deliverable:** PROPOSED `Aiur.Commands.Routing` GenServer; supervision entry; the
  defer refusal / re-route rule.
- **Non-goals:** Executor re-ask (explicitly none, contract §5); legacy attention re-ask;
  notifications; UI.

## Dependencies and blockers

- Blocked by **DESIGN-E2** (§6.1 defaults via C2-T05; §6.7 defer rule).
- Predecessors: C2-T01 (policy), C2-T02 (facts), C2-T05 (config accessors).
- **RC-18 / live bug #2819** ("A main-red attention outlives the red it describes", open,
  `agent:in-progress`): the legacy `attention.*` re-ask in `decision_attention.ex`
  (`@default_reask_interval_ms` 15 min `:17`; unbounded `handle_info({:reask, key})`
  `:216-227`) never stops while its condition is believed true. Its fix is in flight in
  that file. **This ticket must not edit `decision_attention.ex`.** Routing never re-asks;
  for legacy-attention Commands (authority `human_required`, `decision_validation.ex:30-35`)
  it routes `simultaneous` and emits `human_needed` once, which is the bounded
  replacement. After #2819 merges, re-check whether its re-ask should stop once
  `human_visible_at` is set (follow-up owned by #2819's author, not here).
- Cross-feature: the roster (U3 owns `executor/claims.ex` / wake inbox; read-only use).
- May run concurrently with C3, C4-T01.

## Verified starting point (`45a290e3`)

- Change feed: `Aiur.DecisionPubSub.subscribe/0` → `{:decision_changed, id, version}`
  (`decision_pubsub.ex:11-16,55-57`); broadcast after every accepted request
  (`decision_store.ex:4613-4617`). Read: `DecisionStore.get/2` `:388`, `list/1` `:393`.
- Roster: `Aiur.Executor.Roster.build(record?: false)` (`executor/roster.ex:47,52-69`) —
  `record?: false` is required so Routing's reads do not disturb the roster's
  "acknowledged since last observation" evidence.
- Supervision list `src/lib/aiur.ex:417` (DecisionAttention), `:443` (DecisionExpiry).
- Expiry interplay: `decision_expiry.ex:21-23,112-125`.
- Defer: `decision_store.ex:222-226` `defer/4`; `:1820-1831` `handle_defer/3` (any open
  Command, any actor); UI "Defer to Executor" (`decision_action.ex:117`, DESIGN-E2 §1).
- Executor escalation: `decision_store.ex:766-831` records `executor_escalated`.

## Chosen design

State: `%{timer_ref, next_due_at, config, clock, roster_fun, store}` (all injectable).

1. **Boot** (`handle_continue`): `DecisionStore.list/1`; for each non-terminal Command:
   - no `routed_at` → `route/1` (below);
   - `with_executor` → `Policy.escalation_due/3`; overdue → escalate now, once.
   Then arm the timer for the earliest `{:next, at}` (bounded to 30 s).
2. **On `{:decision_changed, id, v}`:** `get/2`; if new (no `routed_at`) and open → route;
   if `answer` set, or terminal → nothing (deadlines simply stop applying); if
   `executor_escalated` appears in audit and `route_state == :with_executor` →
   `escalated{cause: :executor_escalated}`.
3. **Tick** (`:tick`, every ≤ 30 s or at `next_due_at`): recompute liveness once per tick;
   for every `with_executor` Command: if liveness is `:offline`/`:stalled` →
   `escalated{cause: :executor_offline | :executor_stalled}`; else apply
   `escalation_due/3`.
4. **route/1:** `Policy.route(decision, liveness)` → `record_command_fact(:routed, …)`;
   if state ≠ with_executor → `record_command_fact(:human_needed, …)`.
5. **escalate/2:** `record_command_fact(:escalated, …)`; if it was the first human
   visibility → `record_command_fact(:human_needed, …)`.
6. **Defer rule** (one guard in `handle_defer/3`, via `Aiur.Commands.Routing.Policy.deferrable?/1`):
   refuse with `{:conflict, :not_deferrable}` when authority is `human_required` or the
   requester is the Executor. Accepted defer → Routing sees the change and writes
   `routed{state: :with_executor, cause: nil, at: now}` (re-arms deadlines from now;
   `human_visible_at` unchanged, so no second `human_needed`).

- Cadence (resolves chunks.md research): 30 s ceiling vs the wake inbox's 2 s debounce —
  deadlines are minutes long, so 30 s precision is sufficient and costs one `list/1` per
  tick (in-memory map; no I/O).
- Expiry wins: terminal Commands are skipped; a `human_needed` followed by `expired` is
  legitimate and clients clear on the terminal slug (contract §5).
- Idempotency: every write is guarded in the projection (C2-T02), so a crash between
  `routed` and `human_needed` is repaired at the next boot/tick ("first human visibility
  with no `human_needed` yet" → write it).

## Implementation steps

1. PROPOSED `src/lib/aiur/commands/routing.ex` (≈220 lines; split a
   `routing/sweep.ex` if it exceeds 200).
2. `src/lib/aiur.ex`: add `Aiur.Commands.Routing` after `Aiur.DecisionStore` and before
   `Aiur.DecisionExpiry` in the children list (near `:443`).
3. `decision_store.ex` `handle_defer/3`: one `with` step calling `Policy.deferrable?/1`.
4. Map `{:conflict, :not_deferrable}` in `decision_commands.ex` error copy (draft from
   DESIGN-E2 §6.7; final copy is a DESIGN-E2 item — until approved, reuse the existing
   generic conflict message).

## Non-happy paths

- DecisionStore read-only: writes fail; Routing logs once per tick and keeps the timer;
  the inbox still shows everything (today's behaviour).
- Roster read raises/times out: liveness = `:stalled` (fail toward the human), log.
- Executor claim expires mid-deadline: next tick sees `:offline` → escalate
  `executor_offline` immediately (does not wait for the remaining deadline).
- Daemon down across a deadline: boot sweep escalates once (test).
- Many open Commands: O(n) per tick over the in-memory list; no GitHub or disk I/O.
- Multiple Executors: any live one → `executor_first`; escalation is per Command.

## Compatibility and rollout

- Behaviour change: open Commands created before this ticket get routed at first boot
  (`routed` facts appended for every open Command — one-time burst; bounded by open count).
- Kill switch: config `decisions.escalation.enabled` (default `true`, C2-T05) stops the
  process from writing; Commands then behave as today.
- Rollback: older binary ignores routing facts (contract §11).

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/commands/routing_test.exs test/aiur/decision_store_test.exs test/aiur/decision_expiry_test.exs
```

All tests inject `clock` and `roster_fun`; no `Process.sleep`.

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "supervisor_allowed with live Executor is with_executor, then with_human once after answer deadline" | `routed` then, at T+15 min, one `escalated{executor_answer_timeout}` + one `human_needed` | tick + escalate |
| "restart in the middle of a deadline escalates once" | stop Routing at T+10, restart at T+20 → one escalation; second restart → none | boot sweep + C2-T02 guard |
| "human_required is with_both and human_needed at creation" | one `human_needed` immediately | route step 4 |
| "empty roster routes with_human executor_offline" | as stated | liveness use |
| "stalled roster mid-deadline escalates executor_stalled on next tick" | as stated | tick liveness branch |
| "answer before deadline stops escalation" | no `escalated` after answer | answered skip |
| "expired Command is not escalated" | expire, advance clock → no facts | terminal skip |
| "defer of human_required is refused" | `{:error, {:conflict, :not_deferrable}}` | step 3 |
| "defer of supervisor_allowed re-routes with_executor and does not re-emit human_needed" | new `routed` with later `routed_at`; `human_needed` count 1 | step 6 |
| "routing uses roster record?: false" | `roster_fun` called with `record?: false` | option |
| "legacy attention Command emits human_needed once and Routing never re-asks" | over 1 h of ticks, one `human_needed`, zero further facts | no re-ask |

Mutation check per row (worktree; porcelain shows only the revert).
Manual (AGENTS.md wrapper-tmux recipe): `scripts/aiurdev --test`; have a worker raise a
`supervisor_allowed` Command, do not answer as Executor, set
`decisions.escalation.executor_answer_ms: 60000` in a scratch config, and observe the
Command move to "needs you" in the dashboard inbox (`/commands`) and
`aiur commands --json` showing `route_state: with_human`.

## Completion and handoff

- [ ] Routing supervised; invariant N1 holds in tests; no edit to `decision_attention.ex`.
- [ ] #2819 cited in the PR body as the legacy re-ask variant (RC-18).
- Docs: `concepts/commands.md` routing section (C8-T01); config keys documented in C2-T05.
- Dependents: C2-T04, C6-T01, C7-T01, MP-N4/N5.
