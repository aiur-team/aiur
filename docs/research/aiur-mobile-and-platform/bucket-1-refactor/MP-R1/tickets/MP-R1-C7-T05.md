---
ticket_id: MP-R1-C7-T05
feature_id: MP-R1
chunk_id: MP-R1-C7
bucket: 1-refactor
title: Give the workspace component a boundary (GitHub preflight, attention, process kill, ledger validation)
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C7-T03, MP-R1-C7-T04, MP-R1-C7-T02, MP-R1-C5-T02, MP-R1-C5-T03]
prior_units: [U8]
prior_boundaries: [WS, "#17 agent sandbox", GHD, GHC, EXE, CLD]
prior_features: []
prior_findings: [codebase-02]
size_owner: WORKSPACE (repo_base.ex 1,539; workspace/ownership/guardian.ex 819; workspace/provisioner.ex 743; tests repo_base_test.exs, ownership_test.exs, workspace_and_config_test.exs). Pinned to U8 ledger 465aca643; re-resolve at ticket start (RC-23, MP-R1-C11-T02)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C7-T05 — Workspace component boundary

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C7 (migration step S6; prior §7
  step 5 "then workspace (19)").
- **User value:** none visible. `workspace` (component-map L2: requires `kernel`,
  `config`, `agent-sandbox`, `tracker`) stops referencing the GitHub family, the Claude
  backend, the alerts ledger and the Asks/Findings ledgers (executor-attention, L3).
- **Deliverable:** the edges in the table below are removed via (a) a registered
  workspace preflight, (b) tracker optional callbacks for the repo segment and clone
  URL, (c) a registered git credential provider for `RepoBase`, (d) kernel kill helpers,
  (e) `Signal.alert/2`, (f) ledger validators passed in by their owner, (g) a registered
  agent support module list.
- **Non-goals:** splitting `repo_base.ex` / `guardian.ex` / `provisioner.ex` for size
  (U8 WORKSPACE package does that; this ticket must not grow them); `init` hook
  scaffolding; `Orchestrator.WorkspaceCleanup` (stays with orchestration, C9);
  behaviour changes of any kind. Workspace safety rules in `src/AGENTS.md` apply.

## Dependencies and blockers

- **Owner gate:** DESIGN-R1 §1.
- **Predecessors:** C7-T03 (repo-state paths in `Config.Paths`, shell helper in kernel);
  C7-T04 (`AgentGitHubGuard` is GitHub's; provisioner list moves with it); C7-T02
  (registration pattern, tracker optional callbacks); MP-R1-C5-T02 must also move the
  **reap** helpers `reap_process_group/2,3`, `reap_process_tree/2,3`, `reap_process/2,3`,
  `process_group_alive?/1` (`claude/remote_control.ex:266-354`) — if C5-T02 moves only
  the graceful-kill helpers, this ticket is blocked on a C5 follow-up (named in the
  C7 contract-request note to the coordinator); MP-R1-C5-T03 (`Signal.alert/2`).
- **Prior units:** no U1–U7 unit owns `src/lib/aiur/workspace/**` or `repo_base.ex`
  at base; U8's `WORKSPACE` package does (start prerequisite "U2 lifecycle contract;
  U7 workspace decisions"). Single-writer rule: do not run while a `WORKSPACE` U8 split
  PR is open; whichever lands second rebases. U5 owns the GitHub functions the new
  GitHub preflight module wraps (no logic change).
- **RC-19:** no MP-E1-C1 path is touched.
- **Concurrent with:** C7-T01 only if T01 has merged its one-line `provisioner.ex:108`
  change first; C7-T06, C7-T07, C7-T08.

## Verified starting point (base `45a290e3`)

| From | Line | To | Replacement |
|---|---|---|---|
| `workspace/hooks.ex` | 6-9, 259, 341, 365-366 | `GitHub.AuthPreflight`, `GitHub.Tracker.auth_preflight/0`, `GitHub.Config.repo/0`, `GitHub.Client.format_auth_preflight_error/1` | registered workspace preflight (a) |
| `workspace/hooks.ex` | 307-314 | `tracker.kind == "github"` + `GitHub.Config.repo/0` → clone URL | tracker optional callback `clone_url/0` (b) |
| `workspace/hooks.ex` | 331-336 | preflight enabled only when `tracker_kind() == "github"` | preflight registered ⇔ GitHub (a) |
| `workspace/hooks.ex` | 355 | `Alerts.emit_custom/3` | `Signal.alert/2` (e) |
| `workspace/layout.ex` | 6, 106-110 | `GitHubConfig.repo/0` / Linear slug by kind | tracker optional callback `workspace_repo_segment/0` (b) |
| `workspace.ex` | 7, 205 | `Alerts.emit_custom/3` | (e) |
| `workspace/dirty_guard.ex` | 6, 70 | `Alerts.emit_system/2` | (e) |
| `workspace/ownership/guardian.ex` | 6, 117-121 | `Claude.RemoteControl` reap helpers | kernel (d) |
| `workspace/provisioner.ex` | 8, 13-14 | `Aiur.AgentGitHubGuard` in support-module lists | registered list (g) |
| `repo_base.ex` | 25, 27, 1383, 1407 | `Asks.validate_events/1`, `Findings.validate/1` | validators passed by owner (f) |
| `repo_base.ex` | 705 | `Aiur.GitHub.Config.token/0` | registered git credential provider (c) |
| `repo_base.ex` | 1476 | `Aiur.GitHub.Config.repo/0` (prewarm target) | tracker `clone_url/0` (b) |
| `repo_base.ex` | 23 | `Aiur.AgentEnvironment` | stays: sandbox is below workspace (allowed edge) |

Facts:

- The preflight already has a test seam: app env `:workspace_github_preflight_enabled`
  (`hooks.ex:332`, set `false` in test config `src/config/config.exs:36`) and
  `:workspace_github_preflight_fun` (`hooks.ex:340`). Call site `hooks.ex:236-247`;
  failure handling `:252-270`; message `:364-370` and probe text `:372-…`.
- `repo_base.ex:709-718` `git_auth_env/1` (public, takes the token) builds the
  `http.https://github.com/.extraheader`; only the zero-arity lookup at `:705` names GitHub.
- `repo_base.ex:1472-1482` `resolve/0` gives `:disabled` when the repo is not GitHub
  (comment `:1469-1471`).
- `layout.ex:106-110`: github → `GitHubConfig.repo()`, linear →
  `settings.tracker.linear.project_slug`, other (memory) → nil. Note `Tracker.project_identity/0`
  would return `"memory"` for memory (`memory/tracker.ex:11`), so it is **not** a drop-in.
- `RepoBase` validates the Asks and Findings ledgers when it reads repo metadata
  (`repo_base.ex:1372-1411`, `validate_ledger/3`).

## Chosen design

(a) **Workspace preflight registration.** Behaviour
`Aiur.Workspace.Preflight` (PROPOSED) with `run(workspace, worker_host)`,
`local_hold?(reason)`, `failure_message(workspace, issue_context, reason)`.
`Aiur.GitHub.WorkspacePreflight` (PROPOSED, `github` component) holds the moved code
from `hooks.ex:252-270, 338-380` verbatim. Registered via
`config :aiur, :workspace_preflights, %{"github" => Aiur.GitHub.WorkspacePreflight}` keyed
by tracker kind, so "enabled only for the GitHub tracker" (`:333`) is preserved. The two
existing app-env test seams keep their names and meaning.

(b) **Tracker optional callbacks** on `Aiur.Tracker.IssueTracker` (from C7-T01):
`clone_url/0 :: String.t() | nil` (GitHub: `"https://github.com/#{repo}.git"` when repo
set; others: not implemented → nil) and `workspace_repo_segment/0 :: String.t() | nil`
(GitHub: repo; Linear: project slug; memory: not implemented → nil). Facade:
`Aiur.Tracker.clone_url/0`, `Aiur.Tracker.workspace_repo_segment/0`, both returning nil
when the adapter does not export the callback (pattern of `project_identity/0`,
`tracker.ex:152-159`).

(c) **Git credential provider.** `RepoBase` reads
`Application.get_env(:aiur, :repo_base_git_token, {Aiur.Workspace.NoToken, :token, []})`
— an MFA set to `{Aiur.GitHub.Config, :token, []}` in `config.exs`. `git_auth_env/1`
unchanged.

(d) Guardian's five reap defaults point at the kernel helpers.

(e) Three alert sites → `Signal.alert/2` with identical topic and fields.

(f) `RepoBase` exposes `read_ledger(path, kind, validator)`; the default validators are
supplied at the composition root
(`config :aiur, :repo_ledger_validators, %{asks: {Aiur.Asks, :validate_events}, findings: {Aiur.Findings, :validate}}`).
No validator registered → ledger read without validation is **not** allowed; it returns
`{:error, {:no_validator, kind}}` (fail closed — see Non-happy paths).

(g) `Provisioner` support modules: `@local_agent_support_modules`/`@remote_…` become
`[Aiur.AgentSkills, Aiur.AgentScratch] ++ registered ++ [Aiur.AgentBuildGuard (local only)]`
with `config :aiur, :agent_support_modules, [Aiur.AgentGitHubGuard]`. **Order is preserved**
by inserting the registered list at index 1, matching `:13-14`.

**Invariant:** for the GitHub, Linear and memory trackers, every hook env, workspace
path, alert, git invocation env and installed support file is identical to base.

## Implementation steps

1. Add `Aiur.Workspace.Preflight` and `Aiur.GitHub.WorkspacePreflight`; move code; wire
   `hooks.ex:236-247` to `Registry`-style lookup by `Config.tracker_kind()`.
2. Add `clone_url/0` and `workspace_repo_segment/0` optional callbacks (GitHub, Linear);
   use them at `hooks.ex:307-314`, `layout.ex:102-110`, `repo_base.ex:1476-1477`.
3. Git token MFA at `repo_base.ex:705`.
4. Guardian reap defaults → kernel.
5. Alerts → `Signal.alert/2` (three sites).
6. Ledger validator injection in `repo_base.ex:1372-1411`.
7. Provisioner support module list from app env.
8. `src/config/config.exs`: four new keys (all envs; test env keeps
   `workspace_github_preflight_enabled: false`).
9. Manifest: `workspace` component allowlist rows for the table above removed.

Estimated production change: ~220 lines (≈120 moved). `repo_base.ex` must not grow
(net ≤ 0 lines).

## Non-happy paths

- **No preflight registered for the tracker kind:** workspace creation proceeds without
  preflight, which is exactly base behaviour for Linear and memory.
- **Preflight raises:** the moved code keeps its existing handling
  (`handle_github_preflight_unexpected/4`); no new rescue.
- **Local budget hold:** `local_hold?/1` keeps #2429 behaviour (no
  `system.github.connectivity_lost` for a local hold); test 2 guards it.
- **Missing ledger validator:** fail closed rather than read unvalidated agent-written
  ledgers. At base both validators always exist, so this path is unreachable in-tree;
  it protects a future build without `executor-attention`. MP-R1-C3 should surface that
  build as `executor.asks unavailable: not_installed`.
- **Git token provider returns nil:** `git_auth_env/1` already returns the no-token
  variant (`GIT_TERMINAL_PROMPT=0`); unchanged.
- **Remote (SSH) workers:** preflight receives `worker_host` exactly as today.

## Compatibility and rollout

- No `.aiur/config` key or CLI change; new application config keys only.
- Existing test seams (`:workspace_github_preflight_enabled`,
  `:workspace_github_preflight_fun`, `:repo_base_root`) keep their names.
- Rollback: revert.

## Verification

```bash
env -C src mise exec -- mix test test/aiur/workspace test/aiur/repo_base_test.exs \
  test/aiur/workspace_and_config_test.exs test/aiur/regression/workspace_lifecycle_test.exs \
  test/aiur/workspace_materialize_test.exs test/mix/tasks/workspace_before_remove_test.exs
make -C src fmt-check && make -C src lint
python3 scripts/check-components.py   # MP-R1-C1 (PROPOSED)
```

New / changed tests:

1. `workspace/hooks_test.exs` "preflight runs only for a tracker kind with a registered
   preflight" — enable the seam, linear config → preflight fun not called; github →
   called once. **Mutation:** run preflight unconditionally; linear case fails.
2. `workspace/hooks_test.exs` "local budget hold fails closed without a connectivity
   alert" — preflight fun returns a local-hold reason; assert `{:error,
   {:workspace_github_connectivity_failed, _, _}}` and no `system.github.connectivity_lost`
   signal. **Mutation:** drop the `local_hold?` check; fails.
3. `workspace/layout_test.exs` "repo segment: github repo, linear slug, memory nil" —
   **Mutation:** use `Tracker.project_identity/0`; memory case fails (`"memory"`).
4. `workspace/provisioner_test.exs` "support modules install in base order" — assert the
   resolved list equals `[AgentSkills, AgentGitHubGuard, AgentBuildGuard, AgentScratch]`
   locally and `[AgentSkills, AgentGitHubGuard, AgentScratch]` remotely. **Mutation:**
   append the registered list instead of inserting at index 1; fails.
5. `repo_base_test.exs` "ledger read without a validator fails closed" — **Mutation:**
   return `:ok`; fails.
6. Existing `repo_base_test.exs` and `regression/workspace_lifecycle_test.exs` stay green.

Manual: foreground `scripts/aiurdev --test` (AGENTS.md recipe); let one ticket provision
its workspace; open its chat pane and confirm the agent starts; inspect the workspace's
`logs/agent.md` for the usual hook output. Stop and clean up.

## Completion and handoff

- [ ] `git grep -nE 'Aiur\.GitHub|GitHub(Tracker|Config|Client)|AuthPreflight|Claude\.RemoteControl|Alerts\.|\bAsks\.|\bFindings\.' -- src/lib/aiur/workspace src/lib/aiur/workspace.ex src/lib/aiur/repo_base.ex` returns only comments.
- [ ] `repo_base.ex`, `guardian.ex`, `provisioner.ex` line counts not increased (PR body).
- [ ] Mutation results for tests 1–5 in the PR body.
- **Docs:** none (no operator surface).
- **Dependents:** C7-T06 (github component now owns `WorkspacePreflight`), MP-R7 (S7),
  MP-R1-C9 (orchestrator `WorkspaceCleanup` uses workspace facades only).
