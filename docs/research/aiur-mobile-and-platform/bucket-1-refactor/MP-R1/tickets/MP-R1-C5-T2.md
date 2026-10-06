---
ticket_id: MP-R1-C5-T2
feature_id: MP-R1
chunk_id: MP-R1-C5
bucket: 1-refactor
title: Kernel helpers - Bounded and process signalling (kill, tree, process groups, pidfd reaping) move into the kernel; MapAccess and CoordinationTasks reassigned
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T2]
prior_units: [U4]
prior_boundaries: ["K #1", "BO #30", "CLD #22", "CDX #21", "RUN #18", "ORC #12"]
prior_features: [MP-R7]
prior_findings: []
size_owner: "src/lib/aiur/claude/remote_control.ex: U8 package CLAUDE 'Claude backend' (726 lines; split) — this ticket removes ~40 lines"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C5-T2 — Kernel helpers

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C5. Step S1 (prior §7 step 1:
  "move ... `Bounded`, `MapAccess`, process-kill helpers into `aiur_kernel`").
- **User value:** none visible. Removes the kernel's upward edge `Aiur.Git → Claude.RemoteControl`
  and stops four components depending on build-orders or Claude for generic helpers.
- **Deliverable:**

  | Helper | Today | Change |
  |---|---|---|
  | Bounded text/URL/identifier validation | `Aiur.BuildOrder.Bounded` (`build_order/bounded.ex`, 236 lines; references only `Aiur.SecretRedactor`); 18 files in 4 prior boundaries (BO, CFG, GHD, WEB), 49 call sites | `git mv` to `src/lib/aiur/bounded.ex`, module `Aiur.Bounded`; update all callers |
  | Process signalling (kill, tree, process groups, identity-checked reaping) | Public: `graceful_kill/1`, `graceful_kill_tree/1`, `process_tree/1`, `process_group_alive?/1`, `process_group_for_pid/1`, `process_alive?/1`, `process_identity/1`, `graceful_kill_process_group/1`, `reap_process_group/2,3`, `reap_process_tree/2,3`, `reap_process/2,3`; private helpers (`collect_descendants`, `await_exit`, `await_process_group_*`, `signal_process_group`, `force_kill_process_group`, `reap_with_identity`, `pidfd_reap`, `pidfd_reaper_script`, `positive_pid_string`, `do_await_exit`) and `@kill_grace_ms 2_000` in `Aiur.Claude.RemoteControl` (`remote_control.ex:38,224-480`); `priv/pidfd_reap.py` | Move the whole block (~250 lines) to PROPOSED `src/lib/aiur/process_tree.ex` (`Aiur.ProcessTree`, same function names); `RemoteControl` keeps `defdelegate`s for every public name, so its internal uses and tests are untouched; external callers switch to `Aiur.ProcessTree`. `priv/pidfd_reap.py` is owned by `kernel` in the manifest. This answers C6–C11 researcher request Q-1 (MP-R1-C7-T5 needs the `reap_*` and `process_group_alive?` helpers in the kernel too). |
  | `Aiur.Protocol.MapAccess` | already generic (`protocol/map_access.ex`); 8 callers in CDX, CLD, GHB, RUN, TEL | Manifest reassignment to `kernel`; no code change |
  | `Aiur.CoordinationTasks` | generic keyed admission GenServer (356 lines); used by `aiur.ex` and `agent_runner/tool_executor.ex` | Manifest reassignment to `kernel` (prior §2 #1 "should also own") |

- **External callers of the kill helpers to switch** (base): `git.ex:14,71`,
  `app_server/adapter.ex:253`, `claude/repl/reaper.ex:164`, `codex/app_server_port.ex:158,284`,
  `muse/transport.ex:64,77`, `orchestrator/agent_teardown.ex:198,202,227`,
  `agent_runner/session_lifecycle.ex:646`, `claude/coding_agent.ex:183`,
  `claude/repl/launcher.ex:148`.
- **Non-goals:** Remote Control session logic (the rest of `remote_control.ex`); any
  timing, signal or identity-check change.

## Dependencies and blockers

- DESIGN-R1 §1; C1-T2. **U4 interlock:** U4 ("simplify agent turn and backend
  lifecycles", prior plan) edits `claude/` and `codex/`; if a U4 PR is open on
  `remote_control.ex`, land after it. Not a hard blocker.
- **Concurrent:** C5-T1, C5-T3. **Dependents:** C4-T4 (GlobalConfigStartup's `Bounded`
  edge becomes `github → kernel`), MP-R7 (backend packages no longer reach into Claude
  for kill helpers).

## Verified starting point (`45a290e3`)

- Counts from the parse-only walker at base (method in C1-T2): Bounded 18 files;
  MapAccess 8 files; RemoteControl 18 files in 8 prior boundaries (`K` among them, via
  `Aiur.Git`).
- `graceful_kill/1`: TERM, wait 2,000 ms, KILL, wait 2,000 ms, rescue → `:ok`
  (`remote_control.ex:224-238`). `graceful_kill_tree/1`: snapshot descendants with
  `pgrep -P` recursively, kill deepest first, then root (`:247-255`, `:427-441`).
- Identity-checked reaping (`:328-391`) opens a Linux pidfd through
  `priv/pidfd_reap.py` (resolved with `:code.priv_dir(:aiur)`, `:388-391`) and fails
  closed (`{:error, :identity_signal_unavailable}`) when Python or the script is missing.
  The moved module depends only on `System`, `File`, `:code` and `Aiur.ProcessIdentity`
  (already kernel, prior §2 #1).

## Chosen design

Verbatim moves. `Aiur.ProcessTree` depends only on stdlib and `Aiur.ProcessIdentity`; `RemoteControl`
delegates (`defdelegate graceful_kill(pid), to: Aiur.ProcessTree` etc.). `Aiur.Git`'s
injectable default (`kill_tree_fun: &RemoteControl.graceful_kill_tree/1`, `git.ex:71`)
becomes `&Aiur.ProcessTree.graceful_kill_tree/1`. `@kill_grace_ms` is also used by
Remote Control session code (`remote_control.ex:644`, `timeout: 2 * @kill_grace_ms + 1_000`);
expose `Aiur.ProcessTree.kill_grace_ms/0` and use it there so the value has one source.

## Implementation steps

1. Bounded: `git mv`, rename module, update 18 files (alias lines and the
   `BuildOrder.Bounded` qualified calls); move `test/aiur/build_order/bounded_test.exs` to `test/aiur/bounded_test.exs`.
2. ProcessTree: new module, move functions and private helpers; delegates in
   RemoteControl; update the external callers listed above.
3. Manifest: `bounded.ex`, `process_tree.ex`, `protocol/map_access.ex`,
   `coordination_tasks.ex` → `kernel`; facades added.
4. Prune stale allowlist keys.

## Non-happy paths

- `pgrep` missing → descendants `[]` (unchanged behaviour).
- pidfd unavailable (non-Linux, no `python3`) → `{:error, :identity_signal_unavailable}`
  (unchanged; covered by the existing remote-control tests).
- A caller passed `RemoteControl.graceful_kill_tree/1` as a captured fun stored in state
  across a code reload: not applicable (no hot upgrades).

## Compatibility and rollout

No behaviour change. Rollback: revert.

## Verification

- Existing tests (regression guards): every test file hit by
  `rg -n --fixed-strings -e 'BuildOrder.Bounded' -e 'graceful_kill' src/test/` must pass;
  at base this includes `test/aiur/git_test.exs` (kill-tree injection),
  `test/aiur/claude/remote_control_test.exs`, `test/aiur/orchestrator_remote_control_test.exs`
  and `test/aiur/build_order/bounded_test.exs` (moved).
- New `test/aiur/process_tree_test.exs`: spawn `sh -c 'sleep 30 & sleep 30'` via
  `Port.open`, call `graceful_kill_tree/1`, assert the parent and child PIDs are gone
  (`kill -0` fails) within 5 s; `graceful_kill(nil)` → `:ok`.
- Command: `$TESTCMD test/aiur/process_tree_test.exs test/aiur/git_test.exs` plus the
  files from the grep above.
- Mutation check: make `graceful_kill_tree/1` skip descendants → the child-PID assertion
  fails (this test also guards a future regression; the move itself adds no behaviour).
- Checker: kernel's outbound edge to `harness-adapters` (`Aiur.Git → RemoteControl`)
  disappears; allowlist keys pruned. `components: scc` size printed in the PR body.

## Completion and handoff

- [ ] Bounded and ProcessTree in kernel; MapAccess and CoordinationTasks reassigned.
- [ ] `remote_control.ex` shorter, expected ≈ 480 lines, below the 500 gate (U8 owner
      CLAUDE informed).
- [ ] Docs: none.
- **Dependents:** C4-T4, MP-R7.
