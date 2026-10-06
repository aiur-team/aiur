---
ticket_id: MP-E2-C2-T04
feature_id: MP-E2
chunk_id: MP-E2-C2
bucket: 2-platform
title: Executor acknowledgement — aiur executor-ack and implicit acks
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C2-T02]
prior_units: [U6, U3]
prior_boundaries: [DEC #27, EXE #26, CLI #31]
prior_features: [MP-R1-C9-T5 (AgentControlCLI split; rebase if landed)]
prior_findings: [R-Q3 (answered here), contract §5, roster "positive evidence only" rule]
size_owner: "CLI (aiur-engine.sh; agent_control_cli.ex 3,482 — 4-line delegator only) + DECISIONS (executor_command_cli.ex 387)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C2-T04 — Executor acknowledgement: `aiur executor-ack` and implicit acks

## Identity and outcome

- Bucket 2, MP-E2, chunk C2.
- **User value:** the Executor can say "seen, working on it" in one cheap command, which
  stops the 5-minute ack timer without pretending to answer.
- **Deliverable:** CLI `aiur executor-ack <decision-id> [--executor-id <id>]`; implicit
  `executor_acknowledged` facts on every Executor answer, escalation, moot and supersede.
- **R-Q3 resolution (minimum set):** explicit ack + the four Executor actions. Not
  included: `aiur commands <id>` reads (a human at the same shell is indistinguishable,
  and reading is not commitment) and `executor-wait` delivery (one wake carries many
  records; delivery is not attention). This matches the roster rule that state comes only
  from positive per-consumer evidence (`executor/roster.ex:1-33`).
- **Non-goals:** answer timer changes (ack never stops it); dashboard display (C7-T02).

## Dependencies and blockers

- Blocked by **DESIGN-E2** (§3 CLI copy). Predecessor C2-T02 (`executor_acknowledged`).
- May run concurrently with C2-T03, C2-T05.

## Verified starting point (`45a290e3`)

- Engine: usage lines `packaging/npm/aiur-cli/libexec/aiur-engine.sh:459-460`;
  `cmd_executor_answer` `:2786-2836` (base64-encoded opts → `run_control_rpc
  "Aiur.AgentControlCLI.executor_answer([...])"`); dispatch `:4126-4137`.
- `src/lib/aiur/agent_control_cli.ex:345-357` `executor_answer/1`, `executor_escalate/1`,
  `executor_moot/1` delegators (`guarded/2` + `exit_marker/1`).
- `src/lib/aiur/executor_command_cli.ex:8-66` `answer/2`, `escalate/2`, `moot/2`
  (actor `%{kind: :executor, id: executor_id}`; supersede `:148-159`; errors `:253-281`).
- Executor id default: `Aiur.Executor.Claims.resolve_consumer_id/1`
  (`executor/claims.ex:185-195`).

## Chosen design

- `ExecutorCommandCLI.ack(params, deps)`: validates `decision_id` (16 hex) and
  `executor_id`; calls `DecisionStore.record_command_fact(id, :executor_acknowledged,
  %{executor_id, via: :explicit, at: now}, [])`. Output: `acknowledged <id>` or
  `already acknowledged <id>` (exit 0 both); `not found` exit 1; usage exit 64. Final copy
  is DESIGN-E2 §3 (CLI copy); these strings are placeholders until approval.
- Ack is meaningful only when `route_state == :with_executor`; otherwise the fact is still
  recorded (audit) but has no routing effect.
- Implicit acks: in `ExecutorCommandCLI.answer/escalate/moot` (and the supersede branch),
  after a successful store reply, record `executor_acknowledged{via: :answer|:escalate|
  :moot|:supersede}`. Best-effort: a failure is logged, never changes the command's exit
  status (the answer itself is what matters, and an answer already stops all timers).

## Implementation steps

1. `executor_command_cli.ex`: `ack/2` (+ `@spec`), implicit-ack helper (≈40 lines).
2. `agent_control_cli.ex`: `executor_ack/1` delegator beside `:345-357`.
3. `aiur-engine.sh`: usage line after `:460`; `cmd_executor_ack` modelled on
   `cmd_executor_escalate`; dispatch case near `:4130`.
4. Docs: `website/docs-app/reference/cli.md` entry for `aiur executor-ack` (AGENTS.md:
   CLI command ⇒ cli.md in the same PR).

## Non-happy paths

- Daemon not running: `run_control_rpc` existing failure (exit non-zero, message).
- Unknown id: exit 1 "could not find decision".
- Store read-only: exit 1 with the store error.
- Repeated ack: idempotent (`:duplicate`).
- Ack after escalation: recorded; no effect (already `with_human`).

## Compatibility and rollout

- New command; nothing else changes. Engine change ships in the npm package and
  `aiurdev` alike (shared engine, AGENTS.md "Running").

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/executor_command_cli_test.exs test/aiur/commands/routing_test.exs
bash -n packaging/npm/aiur-cli/libexec/aiur-engine.sh
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| `executor_command_cli_test` "ack records executor_acknowledged with via explicit" | store has fact; exit 0 | `ack/2` |
| "second ack is reported as already acknowledged" | exit 0, message differs | duplicate branch |
| "executor-answer records an implicit ack" | fact with `via: :answer` | implicit helper |
| "implicit ack failure does not change exit status" | inject failing fact writer; answer exit 0 | best-effort guard |
| `routing_test` "ack stops the ack timer but not the answer timer" | at T+6 min no escalation; at T+15 `executor_answer_timeout` | integration of C2-T01 rule with the fact |

Mutation check per row. Manual: `aiurdev --test` (wrapper-tmux), raise a Command, run
`scripts/aiurdev executor-ack <id>` from the repo root, confirm `aiur commands <id> --json`
shows `executor_acknowledged_at` and no escalation at the ack deadline.

## Completion and handoff

- [ ] `aiur executor-ack` in engine + CLI docs.
- [ ] Implicit acks on the four Executor actions.
- Docs: `reference/cli.md` (this PR); the aiur-run skill triage text in C8-T02.
- Dependents: C7-T02 (timeline), C8-T02.
