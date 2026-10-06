---
ticket_id: MP-R1-C9-T11
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: Move the Executor verbs (executor-emit/-subscribe/-listen/-wait/-roster/-claim/-release/-revoke/-fast-forward) into the executor-attention component
status: blocked   # research complete; only DESIGN-R1 and named predecessors remain
blocked_by: [DESIGN-R1, MP-R1-C9-T10, U3]
prior_units: [U3, U6, U8]
prior_boundaries: [CLI #31, EXE #26]
prior_features: [MP-E2, MP-E3]
prior_findings: [loose-2-01, loose-2-18]
size_owner: CLI (agent_control_cli.ex, agent_control_cli_test.exs)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T11 — Executor CLI verbs move to executor-attention

## Identity and outcome

- Bucket 1, MP-R1, chunk C9, step S16 (path-map row PR-13).
- **User value:** none visible. The Executor's daemon-side verbs belong to the
  `executor-attention` component (component-map.md L3), so that component can later be
  packaged with its own CLI.
- **Deliverable:** `Aiur.ExecutorAttention.CLI` (PROPOSED,
  `src/lib/aiur/executor_attention/cli.ex`) holding the bodies of `executor_emit/2`,
  `executor_subscribe/1`, `executor_unsubscribe/1`, `executor_subscriptions/0`,
  `executor_listen/1`, `executor_wait/1`, `executor_fast_forward/2`, `executor_roster/1`,
  `executor_claim/1`, `executor_release/1`, `executor_revoke/2` and their private helpers.
  `AgentControlCLI` keeps each public name as `defdelegate`.
- **Non-goals:** `executor_answer/1`, `executor_escalate/1`, `executor_moot/1` already
  delegate to `ExecutorCommandCLI` (`agent_control_cli.ex:345-358`) and stay as they are.
  The executor wake line inside `status` (`print_executor_wake_status`, `:2397`) stays with
  status (C9-T14). No wording change.

## Dependencies and blockers

- DESIGN-R1 §1; C9-T10 (protocol kernel).
- **U3** owns `executor/claims.ex` and `executor_wake_inbox.ex`; its claim-ownership and
  wake-receipt PRs change the APIs these verbs call (`Claims`, `ExecutorWakeInbox`). Start
  after U3's claim and wake-receipt PRs merge so the move is not rebased across an API
  change.
- MP-E2/MP-E3 later add Executor-facing verbs; they should land in this module (note for
  their tickets via MP-R1-C11-T2).
- Concurrent with C9-T12, T13 (different line ranges — merge-conflict risk is limited to
  the `alias` block; serialize merges, not work).

## Verified starting point (45a290e3)

- Executor verb block: `src/lib/aiur/agent_control_cli.ex:385-791` (≈405 lines), calling
  `ExecutorEvents`, `ExecutorListener`, `ExecutorWakeInbox`, `Executor.Claims`,
  `Executor.Roster` (references at `:388-749`).
- Launcher entry points: `aiur-engine.sh:3166` (`executor_listen`, streamed via
  `run_control_stream`), `:3188` (`executor_wait`, with
  `AIUR_CONTROL_RPC_TIMEOUT_SECONDS=$((timeout + 10))`), `:3220`, `:3247`, `:3262`,
  `:3277`, `:3286`, `:3306`, `:3315-3316`, `:3322`.
- Tests: the executor cases in `src/test/aiur/agent_control_cli_test.exs` (4,125 lines,
  U8 `CLI` row).

## Chosen design

Pure move behind delegates (the C9-T10 rule: public names on `AgentControlCLI` never change,
so old/new launcher/daemon pairs keep working). The moved module imports
`Aiur.ControlCLI.Protocol` and aliases `Aiur.ControlCLI.Reasons`. The executor test cases
move to `src/test/aiur/executor_attention/cli_test.exs` (PROPOSED), which also takes the
first step on the U8 `CLI` row (the 4,125-line test shrinks).

## Implementation steps

1. Create `executor_attention/cli.ex` by moving `:385-791` and the private helpers used
   only there (`executor_wait_*`, `executor_fast_forward_result`,
   `executor_subscription_result`, …); compile tells which helpers are shared.
2. Replace the block in `AgentControlCLI` with 11 `defdelegate` lines.
3. Move the matching test `describe` blocks; keep every assertion string.
4. `components.json`: path under `executor-attention`.

Estimated: ≈20 changed lines, ≈420 moved lines (prod) + ≈1,000 moved test lines.

## Non-happy paths

Unchanged: `executor-wait` timeout and exit codes, `executor-listen` streaming (the
`run_control_stream` path keeps calling `AgentControlCLI.executor_listen/1`, which
delegates), invalid JSON in `executor-emit` (exit 1). Multi-Executor `--as` handling is
moved verbatim.

## Compatibility and rollout

No launcher, flag, output or docs change. Rollback: revert.

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/executor_attention/cli_test.exs test/aiur/agent_control_cli_test.exs
env -C <checkout>/packaging/npm/aiur-cli bun test
bash website/docs-app/scripts/check-cli-reference.sh
```

| Test | Expectation | Fails without |
|---|---|---|
| `agent_control_cli_delegation_test "every launcher-called AgentControlCLI function is exported"` | for each `Aiur.AgentControlCLI.<fn>(` literal in `aiur-engine.sh`, `function_exported?/3` is true with the arity used | any missing delegate (delete one → named failure) |
| moved `executor_wait` tests | identical output strings and exit markers | (moved; must stay green) |

The delegation test is the one new test; it fails if a delegate is dropped, which is the
real risk of this ticket. Manual: `--bg` run, then `scripts/aiurdev executor-wait --timeout 5`,
`executor-roster`, `executor-claim`, `executor-release` — same lines as on the base build.

## Completion and handoff

- [ ] Executor verbs live in `executor-attention`; 11 delegates; delegation test green.
- Docs: none.
- Dependents: MP-E2/E3 CLI additions (via C11-T2). size_owner re-resolved at ticket start
  (RC-23).
