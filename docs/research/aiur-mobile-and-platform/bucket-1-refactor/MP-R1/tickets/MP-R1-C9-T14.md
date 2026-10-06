---
ticket_id: MP-R1-C9-T14
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: Move the read verbs (status, agents, watch, alerts, usage) to their components after U6's shared status read model
status: blocked
blocked_by: [DESIGN-R1, U6, RQ-U6-STATUS-MODEL, MP-R1-C9-T10, MP-R1-C9-T13]
prior_units: [U6, U8, U9]
prior_boundaries: [CLI #31, ORC #12, EXE #26, PM+USG #25]
prior_features: []
prior_findings: [loose-2-01, loose-2-02, loose-2-19, loose-2-22, loose-2-23, web-occ-01]
size_owner: CLI (agent_control_cli.ex, agent_control_cli_test.exs); LIFECYCLE_STATUS (orchestrator/status_report.ex, status_report_test.exs)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T14 — Read verbs move (last CLI split)

## Identity and outcome

- Bucket 1, MP-R1, chunk C9, step S16. Last of the CLI tickets; after it,
  `AgentControlCLI` is only delegates plus the composition-root glue.
- **User value:** none visible.
- **Deliverable:**
  - `status/1`, `agents/1`, `watch/1` and their renderers → `Aiur.Orchestrator.StatusCLI`
    (PROPOSED, `src/lib/aiur/orchestrator/status_cli/`), split by responsibility into
    files < 500 lines (status table, capacity block, agents table, watch diff);
  - `alerts/1` → `Aiur.ExecutorAttention.CLI` (it lists the `AlertFeed`, an
    executor-attention member, `agent_control_cli.ex:328-337`);
  - `usage/2` and `print_delivery_modes/1` → `Aiur.Accounting.CLI` (PROPOSED; next to the
    existing `Aiur.ProviderMeters.CLI`, `agent_control_cli.ex:3`, `:2293-2360`);
  - `AgentControlCLI` keeps all names as delegates.
- **Non-goals:** the status read model itself (U6), wording, the `watch --changes`
  node-global baseline (finding `loose-2-19`; the persistent-term key
  `{Aiur.AgentControlCLI, :watch_baseline}` (`:96`) keeps its literal value so a mixed-version
  node keeps its baseline).

## Dependencies and blockers

- **U6 / RQ-U6-STATUS-MODEL (blocking).** U6's goal: "give CLI/web a shared complete status
  read model with age", files include `orchestrator/status_report.ex` and
  `agent_control_cli.ex` (prior plan U6). The renderers in `:1998-3140` are exactly what U6
  rewrites (findings `loose-2-22`, `loose-2-23`: CLI-only visibility and staleness rules).
  Moving them first would make U6 rebase a 1,100-line move; moving them after U6 moves a
  smaller, shared model consumer. Start when U6's status read-model PR has merged; then
  move whatever CLI-local rendering remains.
- DESIGN-R1 §1 (output byte-identical); C9-T10; C9-T13 (serialize merges).
- `web-occ-01`: the CLI depends on `AiurWeb.OperatorControlCenter.UnitsPresentation`
  (`agent_control_cli.ex:39`) — a core→web inversion. Out of scope here; record the edge
  as an allowlisted checker violation that U6 is expected to remove.

## Verified starting point (45a290e3)

- `status/1` `:99-268`, `agents/1` `:268-298`, `watch/1` `:298-327`, `alerts/1`
  `:328-337`, `usage/2` `:2293-2308`; renderers `print_status_table` (`:1998`) through
  `watch_removed_lines` (`:3097-3140`).
- Launcher: `aiur-engine.sh:2614` (status), `:2621` (usage), `:2724` (agents), `:3102-3104`
  (alerts), `:3140` (watch, `mode:` keyword).
- Timeouts: `@status_timeout_ms 5_000` (`:43`), `@agents_timeout_ms 6_000` (`:64`) with the
  launcher-watchdog rationale (#1684, `:58-63`).

## Chosen design

As C9-T10–T13: pure move behind delegates, sized by responsibility after U6 has shrunk the
renderers. The exact file split is fixed at ticket start from what U6 leaves (the line
ranges above will have moved — MP-R1-C11-T2 refreshes them); the component assignment
above is fixed now.

## Implementation steps

1. Read U6's merged status model; list remaining CLI-local functions.
2. Move them into the three destinations; delegates in `AgentControlCLI`.
3. Move test blocks (the remaining `agent_control_cli_test.exs` content) into per-component
   test files, each < 500 lines, retiring the U8 `CLI` row for these paths.
4. Assert `AgentControlCLI` is delegates only (source-scan test).

## Non-happy paths

Moved verbatim: timeouts with one honest line and exit 124 (#1684), orchestrator-down
message, `watch --changes` baseline.

## Compatibility and rollout

No change for users or launcher. Rollback: revert.

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/orchestrator/status_cli test/aiur/executor_attention/cli_test.exs \
  test/aiur/accounting/cli_test.exs test/aiur/agent_control_cli_usage_test.exs \
  test/aiur/agent_control_cli_delegation_test.exs
env -C <checkout>/packaging/npm/aiur-cli bun test
bash website/docs-app/scripts/check-cli-reference.sh
```

| Test | Expectation | Fails without |
|---|---|---|
| `agent_control_cli_shape_test "AgentControlCLI defines only delegates and the module doc"` | every `def` in the file is a `defdelegate` (source scan) | any remaining body |
| delegation test (C9-T11) | all launcher names exported | dropped delegate |

Manual (AGENTS.md): foreground `aiurdev --test` in the wrapper tmux; `aiurdev status`,
`agents`, `watch --changes` twice, `alerts`, `usage` — same lines as the base build
captured back to back.

## Completion and handoff

- [ ] `agent_control_cli.ex` < 200 lines, delegates only; U8 `CLI` rows for it and its test
      retired.
- Docs: none.
- Dependents: MP-R1-C10 (component directory lists per-component verbs from the manifest).
  size_owner re-resolved at ticket start (RC-23).
