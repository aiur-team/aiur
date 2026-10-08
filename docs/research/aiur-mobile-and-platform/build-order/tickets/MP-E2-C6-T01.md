---
ticket_id: MP-E2-C6-T01
feature_id: MP-E2
chunk_id: MP-E2-C6
bucket: 2-platform
title: aiur command request — Executor-originated Commands
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C1-T01, MP-E2-C1-T03, MP-E2-C2-T03]
prior_units: [U6, U3]
prior_boundaries: [DEC #27, EXE #26, CLI #31]
prior_features: [MP-R1-C9-T05 (AgentControlCLI split; rebase if landed)]
prior_findings: [RC-41, security B2 (rule 4b), D12, contract §2 (sentinel ticket), §4 (human_only), plan §1.5]
size_owner: "CLI (aiur-engine.sh; agent_control_cli.ex 3,482 — delegator only); DECISIONS (one guard in decision_store.ex executor answer policy)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C6-T01 — `aiur command request`: Executor-originated Commands

## Identity and outcome

- Bucket 2, MP-E2, chunk C6 (Executor as requester, D12).
- **User value:** when the Executor itself needs your decision, it raises a real Command
  with suggested responses that you see in the same inbox, instead of the hidden
  `aiur ask` store no surface shows (plan §1.5).
- **Deliverable:** CLI
  `aiur command request "<question>" [--option <id>=<label>]… [--recommend <id>]
  [--blocking] [--urgency low|normal|high|critical] [--ticket <n>] [--context-file <path>]
  [--short-summary <text>] [--executor-id <id>] [--idempotency-key <key>]`
  creating a Command with `requester.kind: :executor`, `origin: :executor_cli`, reserved
  ticket `"executor"`, routed `human_only` by Routing (`executor_originated`); and two
  store guards: an Executor actor may not answer a Command it raised, and an
  `operator_relayed` answer to an Executor-originated Command is refused (RC-41,
  contract §6 rule 4b, security B2). The second guard closes the path where
  `executor.relay_operator_answers: true` lets the Executor answer its own question as
  "the operator".
- **Non-goals:** delivery of the answer back (C6-T02); `aiur ask` alias (C6-T03); UI
  filter (C6-T04).

## Dependencies and blockers

- **DESIGN-E2** (§3 CLI copy; §6.6 one inbox with a filter). Predecessors C1-T01
  (requester/sentinel), C1-T03 (executor topics), C2-T03 (Routing routes it).
- May run concurrently with C3, C4.

## Verified starting point (`45a290e3`)

- Engine patterns: `packaging/npm/aiur-cli/libexec/aiur-engine.sh:459-460` usage,
  `:2786-2836` `cmd_executor_answer` (base64 option encoding, `run_control_rpc`),
  dispatch `:4122-4137` (`commands)`, `executor-answer)` …).
- `src/lib/aiur/agent_control_cli.ex:345-357` delegators.
- `src/lib/aiur/executor/claims.ex:185-195` `resolve_consumer_id/1` (`--as` >
  `AIUR_EXECUTOR_ID` > host-instance).
- `DecisionStore.request/4` `decision_store.ex:154-160`; validation requires `blocking`
  (`decision_validation.ex:98`), `options` ≤ 20.
- Executor answer policy `decision_store.ex:1503-1526`
  (`validate_answer_policy_context/2` executor clause).

## Chosen design

- PROPOSED `Aiur.Commands.ExecutorRequestCLI.request(params, deps)`:
  - payload: `question`, `options` (`id=label` pairs in order; `--recommend` id moved first
    and set as `recommendation`), `blocking` (default `true`; an Executor asking the human
    is normally blocked), `urgency` (default `normal`), `authority: "human_required"`
    (the Executor asks the human by definition), `reversibility` default,
    `context.short_summary` from `--short-summary`, `long_context_markdown` from
    `--context-file` (≤ 20 000 chars, file read in the CLI process), `source_id` =
    `--idempotency-key` or a generated `exec-<ulid>` (printed so a retry can reuse it).
  - opts: `ticket: %{identifier: "executor"}`, `source: %{agent_id: "executor",
    session_id: executor_id, event_id: source_id}`, `requester: %{kind: :executor,
    executor_id, ticket: (--ticket || nil)}`, `origin: :executor_cli`.
  - Output: `Created Command <id> (needs you)` + `aiur commands <id>` hint; `--json`
    prints `{decision_id, version, route_state}`. Copy final per DESIGN-E2 §3.
- `--ticket <n>` is *context* only (shown in UI, `requester.ticket`); delivery never goes
  to that ticket's worker.
- Suggested-responses rule (C1-T02) applies with origin `:executor_cli` too (2–3 options
  recommended; warn otherwise).
- Guard 1: in the executor clause of `validate_answer_policy_context/2`, refuse when
  `Requester.executor?(request)`:
  `{:answer_invalid, {:executor_scope, :executor_originated}}` (delegates to
  `Aiur.Commands.Routing.Policy.executor_may_answer?/1`, so the store gains one call).
- Guard 2 (RC-41): in the same function, for an `:operator_relayed` actor (the clause
  #3006 adds, or a new clause matching the kind by name if #3006 has not merged), refuse
  when `Requester.executor?(request)`:
  `{:answer_invalid, :relay_on_executor_command}`. It applies to answer, revise and
  supersede, because all three validate the policy context. The relay CLI (#3006) maps
  it to "this Command was raised by the Executor; the operator must answer it on a
  surface they log in to (dashboard, Stream Deck or phone)" (exit 1).

## Implementation steps

1. PROPOSED `src/lib/aiur/commands/executor_request_cli.ex` (≈150 lines) + `@spec`s.
2. `agent_control_cli.ex`: `command_request/1` delegator.
3. `aiur-engine.sh`: `cmd_command_request` (parse repeated `--option`, base64 each),
   usage line, dispatch case `command)` with subcommand `request` (unknown subcommand →
   usage, exit 64).
4. `decision_store.ex`: one `cond` branch in the executor policy clause and one in the
   relayed-actor clause (both delegate to `Routing.Policy`).
5. Docs: `website/docs-app/reference/cli.md` entry (AGENTS.md: CLI command ⇒ cli.md).

## Non-happy paths

- Daemon not running: `run_control_rpc` failure message, exit non-zero (Commands need
  the daemon; documented).
- Duplicate submit with the same `--idempotency-key`: same `decision_id` →
  `:duplicate`, prints the existing id.
- `--context-file` unreadable or too large: exit 64 before any RPC.
- No live Executor claim for the given `--executor-id`: still accepted (the requester is
  identified, not authenticated, exactly like `executor-answer`).
- Executor tries `executor-answer` on its own Command: refused with a clear message
  ("you raised this Command; it needs the human").
- Executor tries `operator-relay-answer` on its own Command with relay enabled:
  refused (guard 2), and no `answer_recorded` is written.
- A relayed answer to a **worker** Command is unaffected (guard 2 must not over-match).

## Compatibility and rollout

- New command; no config. Rollback: older binaries show these Commands as ticket
  `executor` and may expire them (contract §11 release note).

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/commands/executor_request_cli_test.exs test/aiur/decision_store_test.exs test/aiur/commands/routing_test.exs
bash -n packaging/npm/aiur-cli/libexec/aiur-engine.sh
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "request creates an executor-originated Command" | `requester.kind == :executor`, `origin == :executor_cli`, ticket `"executor"`, options ordered with recommended first | step 1 |
| "routing marks it with_human executor_originated with one human_needed" | as stated | C2-T03 + requester |
| "lifecycle topic is executor.decision.requested, no ticket topic" | publisher capture | C1-T03 integration |
| "same idempotency key returns duplicate" | same id, status duplicate | `source_id` |
| "executor cannot answer its own Command" | `{:error, {:answer_invalid, {:executor_scope, :executor_originated}}}` | step 4 |
| "operator answers it" | `{:ok, %{status: :accepted}}` | — (guard must not over-match) |
| **"relay answer to an executor-originated Command is refused"** (B2) | `DecisionStore.answer/5` with actor `%{kind: :operator_relayed}` and `actor_source: :relay_cli` → `{:error, {:answer_invalid, :relay_on_executor_command}}`; `decisions.ndjson` byte length unchanged | guard 2 |
| "relay revise of an operator answer on an executor-originated Command is refused" | same refusal through `revise/5` | guard 2 on the revise path |
| "relay answer to a worker Command is still accepted" | `{:ok, %{status: :accepted}}` (fixture kind until #3006 merges) | — (guard 2 must not over-match) |

Mutation check per row: revert that guard in a worktree, confirm the row fails, restore;
report the commands in the PR. Manual: from the Executor repo root, `scripts/aiurdev command
request "Ship the beta today?" --option yes="Ship" --option no="Wait"` while
`aiurdev --test` runs; `/commands` lists it as needing you.

## Completion and handoff

- [ ] CLI + guard + docs.
- Docs: `reference/cli.md`.
- Dependents: C6-T02, C6-T03, C6-T04, C8-T02.
