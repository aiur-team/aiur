---
ticket_id: MP-R1-C9-T12
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: Move the control verbs (pause, resume, reset-budget, global pause/resume, message, set max-agents) into the orchestration component's control CLI
status: blocked   # research complete; only DESIGN-R1 and named predecessors remain
blocked_by: [DESIGN-R1, MP-R1-C9-T10, MP-R1-C9-T11]
prior_units: [U2, U6, U8]
prior_boundaries: [CLI #31, CTL #14, MSG #16]
prior_features: [MP-E3]
prior_findings: [loose-2-01, loose-2-18, loose-2-25, web-rest-07]
size_owner: CLI (agent_control_cli.ex, agent_control_cli_test.exs)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T12 — Control verbs move to orchestration

## Identity and outcome

- Bucket 1, MP-R1, chunk C9, step S16 (path-map row PR-13).
- **User value:** none visible. The verbs that steer agents and the fleet live with the
  control lifecycle and operator messaging they call, not in a 3,482-line hub.
- **Deliverable:** two modules (each < 500 lines, U8):
  - `Aiur.Orchestrator.ControlCLI` (PROPOSED, `src/lib/aiur/orchestrator/control_cli.ex`):
    `pause/1`, `resume/1`, `reset_budget/1`, `pause_global/0`, `resume_global/0`,
    `set_max_agents/1` and the shared control machinery (`control/2`,
    `control_selected`, `await_resumes_applied`, `fleet_status_snapshot`,
    `classify_paused_resume`, `select_targets`, `control_one`, `print_unapplied_resume`, …).
  - `Aiur.Orchestrator.ControlCLI.Message` (PROPOSED, `…/control_cli/message.ex`):
    `message/3` and its confirmation helpers.
  - `AgentControlCLI` keeps `pause/1`, `resume/1`, `reset_budget/1`, `pause_global/0`,
    `resume_global/0`, `message/3`, `set_max_agents/1` as `defdelegate`.
- **Non-goals:** no change to confirmation budgets (`@resume_confirm_timeout_ms 4_000`,
  `@message_confirm_timeout_ms 1_500`, `agent_control_cli.ex:71-82`), to wording, or to the
  application-env test seams (finding `loose-2-18` stays; the keys keep their
  `:agent_control_cli_*` names so tests and any operator debugging seams are unchanged).
  The five-layer pass-through (`loose-2-25`) is not collapsed here.

## Dependencies and blockers

- DESIGN-R1 §1; C9-T10; C9-T11 (serialize merges in the same file).
- Not blocked on RQ-U2-TRANSITION: the CLI only *requests* pause/resume through
  `AgentChat`/`Orchestrator` public APIs; it decides no transition. U2's owner review is
  still requested because the verbs observe control status.
- MP-E3 (Executor conversation) will add send paths; its tickets should call these modules
  (note via MP-R1-C11-T02).

## Verified starting point (45a290e3)

- `set_max_agents/1` and `announce_if_orchestrator_busy/0`:
  `src/lib/aiur/agent_control_cli.ex:789-854` (busy threshold
  `@orchestrator_busy_mailbox_threshold 20`, `:51`; app-env seam at `:840`).
- `pause/1`, `resume/1`, `reset_budget/1`, `pause_global/0`, `resume_global/0`:
  `:1288-1362`; `message/3` and helpers: `:1363-1497` (seams `:1479-1495`); control
  machinery: `:1498-1997` (seams `:1548`, `:1691-1698`, `:1995`); `pause_agent/1`,
  `resume_agent/1` seams at `:3256-3260`.
- Launcher calls: `aiur-engine.sh:2667` (`reset_budget`), `:2714-2716` (`message`, two
  arities), `:3366` (`set_max_agents`); pause/resume/global via the same RPC helper.
- `print_failure/3` (`:3225-3239`) is used by these verbs (`:1317`, `:1379`, `:1414`,
  `:1879-1948`) and moves with them.

## Chosen design

Same rule as C9-T10/T11: pure move, delegates keep the public surface. Split point between
the two files is `message/3` (it shares only `print_failure/3`, `format_*` reasons and
`control_status_snapshot/0` with the rest; `control_status_snapshot/0` goes to
`ControlCLI` and `Message` calls it). The persistent application-env keys are read
exactly as today.

## Implementation steps

1. Move `:789-854`, `:1288-1997`, `:3225-3239`, `:3246-3262` (helpers used only here; the
   compiler identifies leftovers) into the two new files.
2. Replace with 7 `defdelegate` lines (two arities of `message`).
3. Move the matching test blocks to `src/test/aiur/orchestrator/control_cli_test.exs` and
   `…/control_cli/message_test.exs` (each < 500 lines).
4. `components.json`: `orchestration` owns `orchestrator/control_cli*`.

Estimated: ≈20 changed lines; ≈780 moved prod lines; ≈1,400 moved test lines.

## Non-happy paths

Moved verbatim: unconfirmed resume reported as failure (#1634), message queued vs claimed
(#1824), `--message-id` conflict, orchestrator busy announcement (#2137), timeout → exit
124 through `guarded/2`. The C9-T11 delegation test covers dropped delegates.

## Compatibility and rollout

No launcher/flag/output change. Rollback: revert.

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/orchestrator/control_cli_test.exs test/aiur/orchestrator/control_cli \
  test/aiur/agent_control_cli_test.exs test/aiur/agent_control_cli_delegation_test.exs
env -C <checkout>/packaging/npm/aiur-cli bun test
bash website/docs-app/scripts/check-cli-reference.sh
```

New test: none beyond the delegation test from C9-T11 (extended automatically, since it
reads the engine). Moved tests must keep every asserted string. Mutation check: delete the
`message/3` delegate → delegation test fails naming `message/2` and `message/3`.

**Manual (AGENTS.md):** wrapper-tmux `aiurdev --test`; from another shell
`scripts/aiurdev pause <id>`, `resume <id>`, `message <id> "hi"`, `set max-agents 3`,
`pause`/`resume` (global); the TUI row states and the chat pane (message delivered or
`QUEUED`) match the base build.

## Completion and handoff

- [ ] Both files < 500 lines; 7 delegates; launcher tests green.
- Docs: none.
- Dependents: MP-E3 send-path tickets (C11-T02 note). size_owner re-resolved at ticket
  start (RC-23).
