---
ticket_id: MP-R1-C9-T10
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: Control-CLI kernel — extract the RPC output protocol and the shared reason renderer from AgentControlCLI
status: blocked   # research complete; only DESIGN-R1 and named predecessors remain
blocked_by: [DESIGN-R1, MP-R1-C1-T01, MP-R1-C1-T02]
prior_units: [U6, U8, U9]
prior_boundaries: [CLI #31, "#32 launcher"]
prior_features: [MP-E1]
prior_findings: [loose-2-01, loose-2-20, loose-2-21, tests-5-30, nonelixir-shell-06]
size_owner: CLI (src/lib/aiur/agent_control_cli.ex 3,362 lines in the ledger; 3,482 at 45a290e3; src/test/aiur/agent_control_cli_test.exs)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T10 — Control-CLI kernel

## Identity and outcome

- Bucket 1, MP-R1, chunk C9, step S16 ("split `AgentControlCLI` by component, with
  per-component CLI verbs"). This is the first of five CLI tickets (T10–T14).
- **User value:** none visible. The launcher↔daemon output protocol (exit marker, error
  marker, crash guard, timeout wording) gets one owner module that every per-component CLI
  module uses, so the later moves (T11–T14) are pure moves.
- **Deliverable:**
  1. `Aiur.ControlCLI.Protocol` (PROPOSED, `src/lib/aiur/control_cli/protocol.ex`):
     `exit_marker/1`, `control_error/1`, `guarded/2`, `single_line/1`,
     `control_query_timeout/3`, `format_timeout_budget/1`,
     `report_control_query_failure/3`, `application_started?/0`,
     `not_running_message/0`, `orchestrator_liveness/0`, and the two marker constants.
  2. `Aiur.ControlCLI.Reasons` (PROPOSED, `…/control_cli/reasons.ex`): `format_reason/1`
     and `format_message_reason/1` (today `agent_control_cli.ex:3306-3476`).
  3. `AgentControlCLI` calls them; its public functions are unchanged.
- **Non-goals:** no launcher change; no output byte changes; finding `loose-2-20` (some
  entry points bypass `guarded/2`) is **not** fixed — it is recorded for U6/U9.

## Dependencies and blockers

- DESIGN-R1 §1 (CLI output lines unchanged); MP-R1-C1-T01/T02 (manifest component
  `control-cli`).
- U6 owns `agent_control_cli.ex` for the status read model; this ticket touches only the
  protocol helpers and reason table, not status rendering, so it is not blocked on U6. Ask
  the U6 owner to review.
- Concurrent with C9-T01…T09. T11–T14 depend on it.

## Verified starting point (45a290e3)

- `src/lib/aiur/agent_control_cli.ex`: 3,482 lines, 495 `def/defp` clauses; markers
  `@exit_marker "__AIUR_CONTROL_EXIT__:"` and `@error_marker "__AIUR_CONTROL_ERROR__:"`
  (`:41-42`); `guarded/2` (`:3177-3192`, the #1684 last-resort guard); `control_error/1`
  (`:3241-3245`); `exit_marker/1` (`:3478-3481`); `orchestrator_liveness/0`
  (`:3141-3160`); reason table `format_reason/1` (`:3306-3430`) used from executor
  verbs, `set_max_agents`, `todo` and pause/resume (≈25 call sites between `:394` and
  `:1991`).
- The launcher invokes the module by **string expression** over the control RPC, e.g.
  `run_control_rpc "Aiur.AgentControlCLI.status()"`
  (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:2614`); 34 such call sites in the engine,
  10 in `packaging/npm/aiur-cli/test/launcher.test.mjs`, 1 in `src/lib/aiur/cli.ex`, 2 in
  `src/lib/aiur_web/streamdeck_channel.ex`. The launcher parses the two marker strings
  (finding `tests-5-30`: "a cross-language contract defined only by string literals").
- Already-extracted verb modules use an `error_fun` argument fed with `&control_error/1`
  (`agent_control_cli.ex:345-373`: `CommandsCLI`, `ExecutorCommandCLI`, `BuildOrdersCLI`,
  `GitHubCostCLI`). MP-E1 adds `Aiur.BuildQueueCLI` behind `AgentControlCLI.queue/1` the
  same way (`bucket-2-platform/MP-E1/chunks.md` C6-T01/T02).
- `website/docs-app/scripts/check-cli-reference.sh` derives commands and flags from the
  engine's `case "$cmd"` arms and parse arms and from `src/lib/aiur/cli.ex` `@switches`
  (`:14-60`); it never reads `agent_control_cli.ex`, so splitting the module cannot
  change that check.

## Chosen design

- **The launcher keeps calling `Aiur.AgentControlCLI.<fn>`.** `aiurdev` control commands
  run against the already running release without a rebuild (AGENTS.md "Layout"), so a
  launcher from a newer checkout may talk to an older daemon. Keeping every public name on
  `AgentControlCLI` (as a delegate after T11–T14) means no launcher or `launcher.test.mjs`
  edit at all, and old/new combinations keep working. No runtime verb registry: the verb
  table is the engine's `case` (that is what `check-cli-reference.sh` checks), and a daemon
  registry would be a second copy.
- `Protocol.guarded/2` is the moved function, byte-identical output.
- Marker constants get a single Elixir home plus a test that reads the engine file and
  asserts the same literals appear there (makes `tests-5-30` visible without changing it).

## Implementation steps

1. Create `protocol.ex` and `reasons.ex` by moving the listed functions (≈300 moved
   lines) and making them public with `@doc false`.
2. `import Aiur.ControlCLI.Protocol` (only the moved names) and alias `Reasons` in
   `AgentControlCLI`; delete the private copies.
3. Keep `error_fun: &control_error/1` call shapes (now the public function).
4. Add the marker-parity test.
5. `components.json`: `control-cli` gets `src/lib/aiur/control_cli/**`.

## Non-happy paths

The guard's behaviour on raise, `:exit` timeout (exit code 124) and other throws is moved,
not changed; existing tests in `agent_control_cli_test.exs` cover it (#1684 cases). No
concurrency change (stateless functions).

## Compatibility and rollout

No launcher, flag or output change. Old launcher + new daemon and new launcher + old
daemon both work (public names unchanged). Rollback: revert.

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/agent_control_cli_test.exs test/aiur/agent_control_cli_usage_test.exs \
  test/aiur/control_cli/protocol_test.exs
env -C <checkout>/packaging/npm/aiur-cli bun test   # package.json "test": "bun test"
bash website/docs-app/scripts/check-cli-reference.sh
```

| Test | Expectation | Fails without |
|---|---|---|
| `protocol_test "exit and error markers match the launcher's literals"` | both marker strings occur in `packaging/npm/aiur-cli/libexec/aiur-engine.sh` (read relative to the repo root) | (guard for `tests-5-30`; passes at base — labelled a regression guard) |
| `protocol_test "guarded/2 turns a GenServer call timeout into exit 124 with one line"` | captured output is exactly the base-SHA line plus `__AIUR_CONTROL_EXIT__:124` | the moved `:exit` timeout clause |
| `protocol_test "guarded/2 turns a raise into one error line and exit 1"` | one `__AIUR_CONTROL_ERROR__:aiur: x query failed (boom)` line and exit marker 1 | the rescue clause |

The two `guarded/2` tests copy the expected strings from the base SHA's behaviour (capture
once on the base before the move), so they prove byte identity. Mutation per AGENTS.md.
Manual: from the repo root, `scripts/aiurdev status`, `agents`, `alerts`, `commands`
against a `--bg` run; compare output to the same commands on the base build (same daemon
state, run back to back).

## Completion and handoff

- [ ] `agent_control_cli.ex` shrinks by ≈300 lines; no public name changes.
- [ ] Launcher tests and `check-cli-reference.sh` green with zero engine edits.
- Docs: none (no CLI surface change).
- Dependents: C9-T11, T12, T13, T14. size_owner re-resolved at ticket start (RC-23,
  MP-R1-C11-T02).
