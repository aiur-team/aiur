---
ticket_id: MP-R1-C7-T3
feature_id: MP-R1
chunk_id: MP-R1-C7
bucket: 1-refactor
title: Give the agent sandbox a boundary below the backends and the workspace (non-GitHub edges)
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T1, MP-R1-C1-T3, MP-R1-C5-T2, MP-R1-C5-T3]
prior_units: [U4]
prior_boundaries: ["#17 agent sandbox", RUN, WS, CLD, TUI, K, CFG]
prior_features: []
prior_findings: [codebase-02, codebase-03]
size_owner: AGENT_CORE (agent_environment.ex 643, agent_process_log.ex 576); WORKSPACE (repo_base.ex 1,539, receives only delegates); other touched files < 500. Pinned to U8 ledger 465aca643; re-resolve at ticket start (RC-23, MP-R1-C11-T2)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C7-T3 — Agent sandbox boundary (non-GitHub edges)

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C7 (migration step S6; prior §7
  step 5, "Agent sandbox (17), then workspace (19). This breaks the
  runner/backend/workspace cycles").
- **User value:** none visible. The `agent-sandbox` component (component-map L2: requires
  only `kernel`, `config`) stops referencing the Claude backend, the TUI, the
  orchestrator, the alerts ledger and the workspace. That removes the edges that make
  `RUN ⇄ WS`, `CLD ⇄ RUN` and `OC ⇄ RUN` cycles (`feature-boundaries.md` §3.2) and is the
  precondition for MP-R7 (harness adapters must sit **above** the sandbox).
- **Deliverable:** every reference listed in "Verified starting point" from a sandbox
  file to a non-kernel, non-config module is replaced by a kernel/config call, an
  injected default resolved at the composition root, or `Signal.emit/2`. Facades and
  public function signatures of sandbox modules stay unchanged.
- **Non-goals:** the GitHub credential/guard edges inside `AgentEnvironment` and
  `AgentProcessLog` (C7-T4); moving files to new directories (KTD3: logical first);
  physical package `aiur_agent_sandbox` (promotion test, `migration-plan.md` §5);
  fixing the ignored `:pause_containment_result` message (see Non-happy paths).

## Dependencies and blockers

- **Owner gate:** DESIGN-R1 §1.
- **Predecessors:** MP-R1-C1-T1/T3 (manifest entry `agent-sandbox` and layer rule);
  **MP-R1-C5-T2** (kernel process-kill helper: moves `graceful_kill_tree/1`,
  `graceful_kill_process_group/1`, `graceful_kill/1`, `process_alive?/1` out of
  `Aiur.Claude.RemoteControl`); **MP-R1-C5-T3** (`Signal.emit/2` with `Alerts` as a
  consumer). If C5 lands those under different names, use them; do not add a second kill
  helper.
- **Prior unit:** U4 owns `pause_containment.ex` and the agent runner. U4's "settle
  pause once for TurnLoop and QueueDrain" changes callers of `PauseContainment`; this
  ticket only changes the module's outgoing calls and must rebase over any merged U4
  pause PR. Do not run concurrently with a U4 PR on `pause_containment.ex`.
- **RC-19:** no overlap with MP-E1-C1 paths.
- **Then:** MP-R7 (harness adapter package) starts only after this ticket and C7-T4
  (`migration-plan.md` S7 depends on S6).
- **Concurrent with:** C7-T1, C7-T2, C7-T6. C7-T4 and C7-T5 both edit
  `agent_environment.ex`/`repo_base.ex`; run T3 first.

## Verified starting point (base `45a290e3`)

Sandbox members (prior #17): `process_reaper.ex` (343), `agent_environment.ex` (643),
`agent_build_guard.ex` (36), `build_gate.ex` (797), `build_gate_hold_monitor.ex` (223),
`agent_command_installer.ex` (116), `agent_resource_guard.ex` (192),
`agent_process_log.ex` (576), `agent_scratch.ex` (76), `pause_containment.ex` (404),
plus `src/priv/build_gate.bash`, `build_gate_holder.py`, `pidfd_reap.py`.
`agent_github_guard.ex` (541) is assigned to the `github` component (C7-T4/T6), not the
sandbox, because it is GitHub-specific and the sandbox must not require an optional
component (rule R-optional).

Outgoing edges this ticket removes:

| From | Line | To | Kind |
|---|---|---|---|
| `process_reaper.ex` | 51, 289 | `Claude.RemoteControl.graceful_kill_tree/1` | harness-adapters (cycle) |
| `process_reaper.ex` | 290 | `Aiur.Tmux.kill_pane/1` | tui (upward) |
| `agent_resource_guard.ex` | 16, 105 | `RemoteControl.graceful_kill/1` | harness-adapters |
| `pause_containment.ex` | 9, 143-144 | `RemoteControl.graceful_kill_process_group/1`, `process_alive?/1` | harness-adapters |
| `pause_containment.ex` | 342 | `Alerts.emit_system/2` | executor-attention (upward) |
| `pause_containment.ex` | 351-356 | `send(Aiur.Orchestrator, {:pause_containment_result, …})` | orchestration (upward) |
| `build_gate_hold_monitor.ex` | 84 | `&Alerts.emit_system/2` default | executor-attention |
| `agent_command_installer.ex` | 7, 41 | `Workspace.Remote.remote_shell_assign/2` | workspace (cycle) |
| `agent_scratch.ex` | 19, 57 | `Workspace.Remote.remote_shell_assign/2` | workspace |
| `agent_environment.ex` | 9, 426, 503 | `Workspace.Remote.remote_shell_assign/2` | workspace |
| `agent_environment.ex` | 249, 406, 565-567, 609-611 | `RepoBase.repo_path/1`, `repo_relative_path/1`, `cache_sidecar_paths/1` | workspace |
| `agent_process_log.ex` | 566 | `RepoBase.repo_path/1` | workspace |

Facts used by the design:

- `Workspace.Remote.remote_shell_assign/2` (`workspace/remote.ex:6-17`) is pure string
  building over `Aiur.Shell.escape/1`; `Aiur.Shell` (`shell.ex`, 36 lines) is kernel.
- `RepoBase.repo_path/1` (`repo_base.ex:75-76`), `repo_relative_path/1` (`:80-81`) and
  `cache_sidecar_paths/1` (`:65-67`, list at `:33`) depend only on private `base_root/0`
  (`:1498-1500`, app env `:repo_base_root` else `~/.aiur/repo`) and private `slug/1`
  (`:1507-…`). Prior #19 recommends moving "the repository state path out of `RepoBase`
  into `Config.Paths`" (`feature-boundaries.md` entry 19). `Config.Paths`
  (`config/paths.ex`, 368 lines) already owns sibling path helpers (`runtime_state_dir/0`
  `:243`, `repo_name/0` `:256`).
- `ProcessReaper` already accepts injected killers (`process_reaper.ex:209`, keys
  `:kill_tree, :kill_pane, :cmdline_reader`), so only the **defaults** change.
- `{:pause_containment_result, …}` has **no handler** in the orchestrator at base:
  `git grep pause_containment_result` matches only the sender, and
  `orchestrator.ex:238-241` is a catch-all `handle_info/2` that logs at debug and drops it.

## Chosen design

1. **Kill helpers → kernel (C5-T2).** Point the three default funs at the kernel module
   C5-T2 creates. `Claude.RemoteControl` keeps delegating wrappers for its own callers.
2. **Pane killer → composition root.** `default_killers/0` reads
   `Application.get_env(:aiur, :process_reaper_pane_killer, {__MODULE__, :noop_kill_pane})`;
   `src/config/config.exs` sets `{Aiur.Tmux, :kill_pane}` for every env. An MFA tuple
   (not a capture) because config files cannot hold anonymous functions portably. In a
   build without the TUI, panes are never registered, so the no-op default is never hit.
3. **Alerts → `Signal.emit/2` (C5-T3)** for `pause_containment.ex:342` and the
   `build_gate_hold_monitor.ex:84` default, with the same topic string and keyword fields.
4. **Pause result target → configured registered name.** Replace the hard-coded
   `Aiur.Orchestrator` with `Application.get_env(:aiur, :pause_containment_result_target)`
   (a registered name atom), set to `Aiur.Orchestrator` in `config.exs`. The message
   shape is unchanged. Rationale: keeps today's observable behaviour exactly (a debug
   log line in the orchestrator) without the sandbox naming orchestration.
5. **`remote_shell_assign/2` → `Aiur.Shell.remote_assign/2`** (kernel, moved verbatim);
   `Workspace.Remote.remote_shell_assign/2` becomes a one-line delegate.
6. **Repo state paths → `Config.Paths`:** add `repo_state_path/1`,
   `repo_state_relative_path/1`, `repo_cache_sidecar_paths/1`, and move `slug/1`,
   `base_root/0` and `@cache_sidecars` there verbatim (including the `..` rejection).
   `RepoBase.repo_path/1`, `repo_relative_path/1`, `cache_sidecar_paths/1`,
   `state_root/0` become delegates (other callers — `findings.ex:165`,
   `github/quota.ex:1021`, `github/request_log.ex:164`, `run_telemetry/summaries.ex:56`,
   `workspace/hooks.ex:316-317` — move in C7-T5/T6 or keep the delegate).

**Invariants:** every path string, shell fragment, alert topic, message tuple and kill
call is byte-identical to base for the same inputs; the `:repo_base_root` test override
(`config.exs:128`) keeps working because `base_root/0` reads the same key.

## Implementation steps

1. Wait for C5-T2/T3 to merge; rebase.
2. Move `remote_shell_assign/2` into `shell.ex`; delegate from `workspace/remote.ex`;
   update the four sandbox call sites.
3. Move `slug/1`, `base_root/0`, `@cache_sidecars` and the three path functions into
   `config/paths.ex`; delegate from `repo_base.ex`; update the five sandbox call sites.
4. Switch kill defaults (`process_reaper.ex:289`, `agent_resource_guard.ex:105`,
   `pause_containment.ex:143-144`) to the kernel helper.
5. Add `:process_reaper_pane_killer` and `:pause_containment_result_target` to
   `src/config/config.exs`; implement the two lookups.
6. Replace the two `Alerts` uses with `Signal.emit/2`.
7. Manifest: `agent-sandbox` component paths = the eleven files and three priv scripts
   above (minus `agent_environment.ex` GitHub parts, which stay until C7-T4); remove
   resolved allowlist rows; count must fall by the number of rows in the table above.

Estimated production change: ~180 lines moved, ~60 new.

## Non-happy paths

- **Pane killer not configured:** no-op; a pane registration then leaks the pane until
  tmux exits. Only reachable in a custom build that drops the config key while keeping the
  TUI; covered by a test asserting `config.exs` sets it.
- **Result target not running:** the existing `Process.whereis` guard
  (`pause_containment.ex:352`) is kept, applied to the configured name; nil config →
  no send (same as orchestrator not running).
- **Ignored message (finding, not fixed):** the orchestrator drops
  `:pause_containment_result` today. Changing that is a behaviour change (Bucket 2 /
  U4 territory); record it in the PR body and as a U4 note. Do not delete the send here.
- **Path traversal:** `slug/1` moves verbatim with its `..` rejection; the repo_base path
  tests run against the moved function.
- **Security:** no change to env scrubbing lists (`agent_environment.ex:18-56`); this
  ticket does not touch them.

## Compatibility and rollout

- No `.aiur/config` key; two new **application** config keys in `src/config/config.exs`
  (build-time, not operator-facing — no docs entry required by AGENTS.md).
- Public functions keep their names via delegates; no on-disk path changes.
- Rollback: revert.

## Verification

```bash
env -C src mise exec -- mix test test/aiur/process_reaper_test.exs test/aiur/pause_containment_test.exs \
  test/aiur/agent_resource_guard_test.exs test/aiur/agent_environment_test.exs test/aiur/agent_scratch_test.exs \
  test/aiur/agent_command_installer_test.exs test/aiur/build_gate_hold_monitor_test.exs \
  test/aiur/agent_process_log_test.exs test/aiur/repo_base_test.exs test/aiur/workspace/remote_test.exs \
  test/aiur/config/repo_state_paths_test.exs   # new (PROPOSED); test/aiur/shell_test.exs exists
make -C src fmt-check && make -C src lint
python3 scripts/check-components.py   # MP-R1-C1 (PROPOSED)
```

New tests:

1. `config/repo_state_paths_test.exs` (new) "repo_state_path matches RepoBase for https, ssh and local
   inputs and rejects .." — compares against fixed expected strings
   (`"<root>/owner/name"`), not against `RepoBase` (which delegates). **Mutation:** drop
   the `"github.com"` filter in the moved `slug/1`; fails.
2. `shell_test.exs` (existing file, new case) "remote_assign expands ~ and ~/ and escapes quotes" — fixed expected
   output from base. **Mutation:** remove the `'~/'*)` branch; fails.
3. `pause_containment_test.exs` "result is sent to the configured target" — register a
   test process under a test name via `put_env`; assert the tuple shape. **Mutation:**
   hard-code `Aiur.Orchestrator` back; the test process receives nothing; fails.
4. `process_reaper_test.exs` "default pane killer comes from app config" — MFA pointing
   at a test module that records calls. **Mutation:** restore `&Aiur.Tmux.kill_pane/1`;
   fails.
5. Checker fixture (C1): a sandbox file referencing `Aiur.Claude.RemoteControl` fails
   `check-components.py` (guard for future regressions).

Manual: foreground `scripts/aiurdev --test` (wrapper-tmux recipe in AGENTS.md), wait for a
running row, run `scripts/aiurdev pause` then `scripts/aiurdev resume`, then `aiurdev stop`; capture the AgentList before and after
(`tmux capture-pane`) and confirm the pause row and stop/reap behave as at base.

## Completion and handoff

- [ ] `git grep -nE 'Claude\.RemoteControl|Aiur\.Tmux|Aiur\.Orchestrator|Alerts\.|Workspace\.Remote|RepoBase' -- <sandbox files>` returns only comments.
- [ ] Mutation results for tests 1–4 in the PR body; ignored-message finding recorded.
- [ ] Checker count lower by the removed rows.
- **Docs:** none (no operator surface).
- **Dependents:** C7-T4, C7-T5, MP-R7 (S7), MP-R1-C9 (orchestrator no longer named by the sandbox).
