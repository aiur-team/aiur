---
ticket_id: MP-R7-C3-T05
feature_id: MP-R7
chunk_id: MP-R7-C3
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Harness-adapters boundary rule in the component checker, with a reasoned allowlist
status: blocked
blocked_by: [DESIGN-R7, MP-R7-C3-T01, MP-R7-C3-T02, MP-R7-C3-T03, MP-R7-C3-T04, MP-R1-C1-T01, MP-R1-C1-T02, MP-R1-C1-T03, MP-R1-C1-T05]
prior_units: [U4, U7]
prior_boundaries: [CA (20), CDX (21), CLD (22), OAI (23), RUN (18), #17 agent sandbox, K (1)]
prior_features: [integrations-09]
prior_findings: []
size_owner: n/a (manifest and allowlist data; checker owned by MP-R1-C1)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C3-T05 — Boundary rule and allowlist (resolves RQ-R7-2)

## Identity and outcome

- Bucket 1, MP-R7, chunk C3. **User value:** none directly; it stops new
  upward references into harness internals from merging unnoticed (plan
  acceptance criterion 3).
- **Deliverable:** in MP-R1's component manifest (`components.json`, PROPOSED,
  created by MP-R1-C1-T01) the `harness-adapters` entry declares its
  **private namespaces as data** and its public facades; MP-R1's checker
  (`scripts/check-components.py`, PROPOSED, MP-R1-C1-T02/T03) fails the
  required `lint` job when a module outside the component references a
  private namespace, except for the allowlist rows below, each with a reason
  and an owning ticket.
- **Non-goals:** not a second checker. RC-11 let MP-E1 ship its own scan test
  only because E1 lands in wave 0 before MP-R1-C1; R7 lands after MP-R1 step
  S6 (migration-plan §2), so the R1 checker exists.

## Dependencies and blockers

- **Blocked (cross-feature):** MP-R1-C1-T01 (manifest), -T02 (Elixir reference
  walker), -T03 (private-module rule), -T05 (ratchet allowlist + CI wiring).
- C3-T01..T04 merge first so their edges are absent rather than allowlisted.
- RC-22 (Gemini/ACP, draft PR aiur-team/aiur#2870, head `c1fc6f84`): if #2870
  merges before this ticket, add `Aiur.Gemini.` to the namespace list (one line).

## Verified starting point (base `45a290e3`)

Command used:
`git grep -n -E 'Aiur\.(Codex|Claude|Muse|OpenAICompat)\b|Aiur\.\{[^}]*(Codex|Claude|Muse|OpenAICompat)' 45a290e3 -- src/lib`
minus files under `codex/ claude/ muse/ open_ai_compat/ coding_agent/providers/`.
It returns 33 lines in 29 files. Classification (RQ-R7-2 resolution):

| # | Reference (file:line → target) | Class | Disposition |
| --- | --- | --- | --- |
| 1 | `agent_runner/{queue_drain:21, tool_executor:25, turn_loop:8}`, `agent_tools/catalog:4`, `app_server/adapter:12` → `Codex.DynamicTool` | leak | removed by C3-T01 |
| 2 | `agent_runner/checkpoint_delivery:13` → `Codex.SessionRecovery` | leak | removed by C3-T02 |
| 3 | `agent_runner/session_lifecycle:6` → `Claude.{DisplayTailer, Telemetry}` | leak | removed by C3-T03 |
| 4 | `orchestrator/interrupts:7` → `Claude.ReplAgent` | leak | removed by C3-T04 |
| 5 | `agent_resource_guard:16`, `app_server/adapter:11`, `git:14`, `orchestrator/agent_teardown:10`, `pause_containment:9`, `process_reaper:51`, `workspace/ownership/guardian:6`, `agent_runner/session_lifecycle:6` (`process_tree/1`) → `Claude.RemoteControl` **process helpers** (`graceful_kill*`, `process_tree`, `process_group_alive?`, `process_alive?`, `process_identity`, `reap_*`; `claude/remote_control.ex:224-360`) | misplaced generic helper | allowlist → owner **MP-R1-C5-T02** ("kill helper in kernel"; prior §3.3 "move kill-tree to K") |
| 6 | `orchestrator/remote_control_mode:7` (`ensure_workspace_trusted`, `reap_orphaned_servers`, `ReplAgent.reap_orphaned_panes`), `shutdown:26` (`ReplAgent.sweep_own_panes`, `RemoteControl.reap_workspace_agents`), `orchestrator/agent_teardown:10` (pane teardown) | Remote Control policy | allowlist; reason: RC promotion policy is orchestrator-owned by R7 design (plan "not inside"), and REPL/RC is a live conditional cut (prior U7 `integrations-09`); decoupling it before that decision is waste |
| 7 | `config.ex:1305` → `Codex.Config.validate_approval_policy/1`, `config.ex:1340` → `Claude.Config.validate!/0` | config schema | allowlist → owner **MP-R1-C4-T03** (`config.ex:1305`, Codex approval policy) and **MP-R1-C4-T01** (`config.ex:1340`, registered semantic checks) — Phase D, CR-R7-5 |
| 8 | `aiur.ex:432` → `Aiur.Claude.Telemetry` child spec | composition root | allowlist → owner **MP-R7-C4-T01** |
| 9 | `aiur_web/controllers/observability_api_controller:9` → `Claude.HookEvents.dispatch/2` (`POST /api/v1/:id/claude-hook`) | web route | allowlist → owner **MP-R1-C6-T01** (component route registration) |
| 10 | `provider_meter_probe:28` → `Claude.UsageApi`; `usage/grouped_scopes:47` → `Claude.Telemetry.UsageAdapter.Relationship`; `usage/headless/muse/session_usage:13` → `Muse.Usage` | accounting ⇄ harness | allowlist → owner **MP-R1-C11-T03**, which must cut the accounting (S10) ticket before wave 2 (Phase D, CR-R7-3) |
| 14 | `config.ex:319,396,1405-1413` → `Aiur.CodingAgent` (backend catalog); `config/schema/agent_validation.ex:78,132`, `config/schema/agent.ex:120` → `Aiur.CodingAgent` | config → harness facade (R-down, not R-private) | allowlist in the R1 layer ratchet → owner **MP-R7-C3-T06** (Phase D, CR-R1-7) |
| 11 | `agent_control_cli:30` → `Codex.EventHumanizer` (used for **every** backend at :2808) | surface | allowlist; replacing it with a per-backend humanizer would change `aiur agents` text for Claude agents, which DESIGN-R7 forbids. Reported to coordinator as a possible defect |
| 12 | `coding_agent/registry:14` → `OpenAICompat.Registry`; `app_server/rpc/stream:5` → `Codex.StartupFailure`; `app_server/adapter:11,12` | inside component | not a violation: `coding_agent/**` and `app_server/**` are in `harness-adapters` (MP-R1 component-map row, migration-plan PR-03) |
| 13 | `external_content:10`, `github/issue_dependencies:8`, `opencode/chat_completions/delta_renderer:134`, `coding_agent/route_failure:40` | comment/doc only | not a reference; the walker must ignore comments and `@doc` strings (a fixture proves it) |

RC-22 check of PR #2870 at `c1fc6f84`: its new files reference only
`Aiur.Gemini.*`, `Aiur.{PauseContainment, ProcessReaper}` (sandbox, a
downward edge), `Aiur.Muse.Transport` (`gemini/transport.ex:4`, an
adapter-to-adapter edge inside the component) and, through `agent_tools/mcp.ex`,
the neutral tool surface. It adds **no** upward leak; the only outside edits
are the registry entry and `AgentTools.MCP` transport tagging.

## Chosen design

Manifest data (PROPOSED shape; field names follow MP-R1-C1-T01's schema):

```json
"harness-adapters": {
  "paths": ["src/lib/aiur/coding_agent.ex", "src/lib/aiur/coding_agent/**", "src/lib/aiur/app_server/**",
            "src/lib/aiur/agent_tools/**", "src/lib/aiur/codex/**", "src/lib/aiur/claude/**",
            "src/lib/aiur/muse/**", "src/lib/aiur/open_ai_compat/**"],
  "private_namespaces": ["Aiur.Codex.", "Aiur.Claude.", "Aiur.Muse.", "Aiur.OpenAICompat."],
  "facades": ["Aiur.CodingAgent", "Aiur.CodingAgent.Backend", "Aiur.AgentTools.Catalog", "Aiur.AgentTools.Dispatch"]
}
```

Allowlist rows carry `{from_module, to_module, reason, owner_ticket}` and live
in the R1 ratchet file; the ratchet only lets the count fall (MP-R1-KD7).
Adding a harness (Gemini after #2870) is one string in `private_namespaces`.

## Implementation steps

1. Add/extend the `harness-adapters` manifest entry as above.
2. Add allowlist rows for classes 5–11, each naming its owner ticket (row 14 is
   an R-down row in MP-R1's layer allowlist, listed here only for its owner).
3. Add checker fixtures under MP-R1-C1-T06's fixture tree: one forbidden
   reference (`Aiur.Orchestrator.Foo` aliasing `Aiur.Codex.Frames`) that must
   fail, and one comment-only mention that must pass.
4. Run the checker on the branch; the reported harness count equals the number
   of allowlist rows.

## Non-happy paths

- An allowlisted owner ticket merges: its rows must be deleted in that PR
  (ratchet fails if a row no longer matches — confirm MP-R1-C1-T05 implements
  "stale allowlist row" as a failure; otherwise file a contract request).
- Dynamic references (`Module.concat`, registry module values) are invisible to
  a static walker. Registry entries are data inside the component, so this is
  acceptable; stated in the manifest comment.

## Compatibility and rollout

CI-only change. Rollback: revert the manifest rows. No runtime effect.

## Verification

- `scripts/test-check-components.sh` (PROPOSED by MP-R1-C1-T06) gains
  `harness_private_namespace_violation` (expects exit 1) and
  `harness_comment_mention_ok` (expects exit 0).
- Mutation: in a scratch worktree add `alias Aiur.Codex.Frames` to
  `src/lib/aiur/orchestrator/interrupts.ex`; `python3 scripts/check-components.py`
  exits non-zero naming that edge. Remove one allowlist row; the checker fails
  on that edge.
- Commands: `python3 scripts/check-components.py`,
  `bash scripts/test-check-components.sh`, `env -C src mise exec -- mix lint`.

## Completion and handoff

- [ ] Checker green on the branch with exactly the class 5–11 allowlist rows.
- [ ] Both fixtures behave as stated; mutation recorded in the PR body.
- Docs: none user-facing; C6-T01 documents the rule for contributors.
- Dependents: MP-R7-C4-T02 (promotion evidence starts counting releases with
  zero non-allowlisted violations).
