# Decomposition proposal: `src/lib/aiur/workspace.ex` (1235 lines)

Behavior-preserving split for regression hotspot #4 ("Workspace lifecycle, git metadata & prewarm base", ~19 incidents — `docs/refactor/research-history-hotspots.md`, row 4 and section "Workspace refresh & git metadata"). House style: one source of truth per fact, pure policy functions over call chains, no local-vs-remote M-x-N fan-out spread across concerns, one dependency direction, files <=200 lines.

External API surface (must stay on `Aiur.Workspace` — callers: `agent_runner.ex:81,105,118`, `orchestrator.ex:1756,4166`, `alerts.ex:642`, `opencode/session_writer.ex:796`, `opencode/session_writer_registry.ex:211`, plus both test files):
`create_for_issue/2`, `run_before_run_hook/3`, `run_after_run_hook/3`, `remove/1,2`, `remove_issue_workspaces/1,2`, `workspace_path_under/2`, and the `@doc false` test seams `materialize_from_base/2,3`, `ensure_git_metadata_writable/2`.

---

## 1. Function / responsibility census

Eleven distinct concerns interleaved in one module. Line ranges from current `src/lib/aiur/workspace.ex`.

### A. Creation entry + create/reuse/recreate decision table (~155 lines)
| Function | Lines | Size |
|---|---|---|
| `create_for_issue/2` (public entry, try/rescue envelope) | 14–35 | 22 |
| `maybe_install_agent_skills/2` (local-only, #689) | 37–43 | 7 |
| `ensure_workspace/3` (PR-anchored delegation clauses) | 45–69 | 25 |
| `ensure_workspace/2` local (dir? / stale-file / create cond) | 71–83 | 13 |
| `ensure_workspace/2` remote (SSH script + `__AIUR_WORKSPACE__` marker) | 85–116 | 32 |
| `create_workspace/1` (cold path) | 118–122 | 5 |
| `create_or_materialize/1,2` (prewarm gate → cold fallback) | 124–154 | 31 |
| `recreate_workspace/2` local + remote | 576–596 | 21 |

### B. Prewarm materialize + branch checkout (~145 lines)
| Function | Lines | Size |
|---|---|---|
| `materialize_from_base/2` (public test seam) | 156–178 | 23 |
| `materialize_from_base/3` (PR-anchored) | 180–200 | 21 |
| `checkout_fresh_branch/1` (live-origin-tip fix, #567) | 202–216 | 15 |
| `checkout_existing_pr_branch/2` | 218–232 | 15 |
| `fetch_pr_head_branch/2` | 234–243 | 10 |
| `checkout_tracking_pr_branch/2` (FETCH_HEAD rationale) | 245–259 | 15 |
| `checkout_local_pr_branch/2` | 261–270 | 10 |
| `fresh_base_start_point/1` | 272–281 | 10 |
| `current_branch/1` (shared with concern F) | 283–288 | 6 |
| `copy_tree/2` (APFS `cp -c` vs `--reflink=auto`) | 290–298 | 9 |
| `branch_for/1` | 300 | 1 |

### C. Removal (~140 lines)
| Function | Lines | Size |
|---|---|---|
| `remove/1`, `remove/2` local | 302–321 | 20 |
| `remove/2` remote | 323–343 | 21 |
| `remove_issue_workspaces/1,2` (remote, local ssh-host fan-out, catchall) | 345–379 | 35 |
| `maybe_run_before_remove_hook/2` local | 902–925 | 24 |
| `maybe_run_before_remove_hook/2` remote | 927–963 | 37 |

### D. before_run flow + stale-workspace refresh policy (~90 lines) — the #569→#577→#595→#653→#661 chain
| Function | Lines | Size |
|---|---|---|
| `run_before_run_hook/3` (public entry) | 381–404 | 24 |
| `finalize_before_run_workspace/3` | 406–410 | 5 |
| `run_before_run_command/4` | 412–416 | 5 |
| `maybe_recreate_stale_workspace/6` (3-way cond: error / recreate for todo dispatch #577 / non-fatal WIP skip #653) | 418–456 | 39 |
| `stale_leftover_refresh_refusal?/1` (exit-65 contract) | 559–561 | 3 |

### E. Bootstrap-image warm-cache seeding (~105 lines)
| Function | Lines | Size |
|---|---|---|
| `maybe_seed_from_bootstrap_image/3` | 458–472 | 15 |
| `seed_from_bootstrap_image/5` local (Task+timeout) | 474–498 | 25 |
| `seed_from_bootstrap_image/5` remote (timeout remap) | 500–516 | 17 |
| `bootstrap_image_script/3` | 518–527 | 10 |
| `bootstrap_image_copy_script/0` (+ `@warm_cache_paths`, exit 66) | 529–557 | 29 |

### F. Git metadata writability (~185 lines) — regressed 4+ times (#493→#542→#561→#565→#616)
| Function | Lines | Size |
|---|---|---|
| `ensure_git_metadata_writable/2` local | 598–613 | 16 |
| `ensure_git_metadata_writable/2` remote (script; git-dir containment exit 31) | 615–660 | 46 |
| `local_git_metadata_probe_paths/1` | 662–667 | 6 |
| `probe_lock_files/1` | 669–676 | 8 |
| `local_git_metadata_dir/1` | 678–692 | 15 |
| `expand_git_dir/2` | 694–699 | 6 |
| `ensure_git_dir_inside_workspace/2` | 701–714 | 14 |
| `git_metadata_probe_paths/2` (4 canonical locks) | 716–727 | 12 |
| `pr_anchored_ref_lock_paths/2` | 729–747 | 19 |
| `ref_lock_segments/1` | 749–752 | 4 |
| `pr_anchored_workspace?/1` (`pr-` leaf check) | 754–756 | 3 |
| `probe_lock_file/1` (rm-then-exclusive-create-then-rm) | 758–768 | 11 |
| `remove_stale_lock/1` | 770–781 | 12 |

### G. Lifecycle hook wrappers (~40 lines)
| Function | Lines | Size |
|---|---|---|
| `run_after_run_hook/3` (public; failures ignored) | 783–796 | 14 |
| `maybe_run_after_create_hook/4` (tri-state `true/:materialized/false`) | 879–900 | 22 |

### H. Hook execution engine (~115 lines)
| Function | Lines | Size |
|---|---|---|
| `ignore_hook_failure/1` | 965–966 | 2 |
| `run_hook/5` local (env scrub, perf log, Task+timeout+brutal_kill) | 968–1012 | 45 |
| `run_hook/5` remote | 1014–1029 | 16 |
| `hook_env/0` (`THIS_REPOSITORY_URL`) | 1031–1043 | 13 |
| `handle_hook_command_result/4` (ok tail-log + failure tuple) | 1045–1065 | 21 |
| `sanitize_hook_output_for_log/2` | 1067–1077 | 11 |

### I. Path layout + root-containment validation (~120 lines)
| Function | Lines | Size |
|---|---|---|
| `workspace_path_under/2` (public) | 798–809 | 12 |
| `workspace_path_for_issue/2` local (canonicalized) + remote (raw) | 811–819 | 9 |
| `issue_workspace_path/2` (repo namespacing, idempotent append) | 821–841 | 21 |
| `repo_segment/0` (github/linear/memory) | 843–862 | 20 |
| `safe_repo_segment/1`, `safe_identifier/1` | 864–877 | 14 |
| `validate_workspace_path/2` local (equals-root / symlink-escape / outside-root) | 1079–1105 | 27 |
| `validate_workspace_path/2` remote (empty / control chars) | 1107–1119 | 13 |

### J. Remote shell plumbing (~55 lines)
| Function | Lines | Size |
|---|---|---|
| `remote_shell_assign/2` (tilde expansion) | 1121–1131 | 11 |
| `parse_remote_workspace_output/1` (`__AIUR_WORKSPACE__` marker) | 1133–1154 | 22 |
| `run_remote_command/3` (Task+timeout+brutal_kill over `SSH.run`) | 1156–1171 | 16 |
| `shell_escape/1` | 1173–1175 | 3 |

### K. Issue-context extraction (~60 lines)
| Function | Lines | Size |
|---|---|---|
| `worker_host_for_log/1` | 1177–1178 | 2 |
| `issue_context/1` (map / binary / catchall; `pr-<pr#>` leaf) | 1180–1214 | 35 |
| `pr_head_ref_from/1` | 1216–1225 | 10 |
| `workspace_identifier/2` | 1227–1230 | 4 |
| `issue_log_context/1` | 1232–1234 | 3 |
| `todo_dispatch?/1`, `normalize_issue_state/1` (used by concern D) | 563–574 | 12 |

---

## 2. Proposed module split (NAME MAP — contract for downstream tickets)

Namespace convention follows the in-repo precedent `Aiur.Prewarm.Detect` → `src/lib/aiur/prewarm/detect.ex`. The `Aiur.Workspace.*` namespace is free (only `Aiur.Config.Schema`'s embedded `Workspace` changeset exists, in a different namespace). `Aiur.Workspace.Context` deliberately avoids clashing with the existing `Aiur.IssueContext` (pane intro summaries — unrelated).

| # | Module | File (under `src/lib/`) | Responsibility | ~LOC | Key functions moving there |
|---|---|---|---|---|---|
| 1 | `Aiur.Workspace` | `aiur/workspace.ex` (shrinks in place) | Public facade: the entire existing API surface, `create_for_issue/2` orchestration with its try/rescue envelope, `defdelegate` for the test seams. | 110 | `create_for_issue/2`, `workspace_path_under/2`, delegations for `remove`, `remove_issue_workspaces`, `run_before_run_hook`, `run_after_run_hook`, `materialize_from_base`, `ensure_git_metadata_writable` |
| 2 | `Aiur.Workspace.Layout` | `aiur/workspace/layout.ex` | Pure path policy: where a workspace lives (repo-namespaced layout) and whether a path is legal under the configured root. | 160 | `issue_workspace_path/2`, `workspace_path_for_issue/2`, `repo_segment/0`, `safe_repo_segment/1`, `safe_identifier/1`, `validate_workspace_path/2` (local+remote), `pr_anchored_workspace?/1` |
| 3 | `Aiur.Workspace.Context` | `aiur/workspace/context.ex` | Pure policy normalizing issue-or-identifier into the workspace issue-context map (`pr-` leaf naming, todo-dispatch classification, log formatting). | 90 | `issue_context/1` (as `build/1`), `pr_head_ref_from/1`, `workspace_identifier/2`, `todo_dispatch?/1`, `normalize_issue_state/1`, `issue_log_context/1` (as `log_context/1`), `worker_host_for_log/1` |
| 4 | `Aiur.Workspace.Remote` | `aiur/workspace/remote.ex` | SSH execution plumbing shared by every remote clause: hard-timeout command runner, tilde-expanding shell assignment, escaping. | 70 | `run_remote_command/3`, `remote_shell_assign/2`, `shell_escape/1` |
| 5 | `Aiur.Workspace.Checkout` | `aiur/workspace/checkout.ex` | Git branch selection for a freshly materialized workspace (live-origin-tip `aiur/<id>` vs PR-anchored head ref) plus the shared branch query. | 110 | `checkout_fresh_branch/1`, `fresh_base_start_point/1`, `checkout_existing_pr_branch/2`, `fetch_pr_head_branch/2`, `checkout_tracking_pr_branch/2`, `checkout_local_pr_branch/2`, `current_branch/1`, `branch_for/1` |
| 6 | `Aiur.Workspace.GitMetadata` | `aiur/workspace/git_metadata.ex` | `.git` writability probes and stale-lock repair, local and remote, including the git-dir-inside-workspace containment guard. | 200 | `ensure_git_metadata_writable/2` (both), `local_git_metadata_probe_paths/1`, `probe_lock_files/1`, `local_git_metadata_dir/1`, `expand_git_dir/2`, `ensure_git_dir_inside_workspace/2`, `git_metadata_probe_paths/2`, `pr_anchored_ref_lock_paths/2`, `ref_lock_segments/1`, `probe_lock_file/1`, `remove_stale_lock/1` |
| 7 | `Aiur.Workspace.Materialize` | `aiur/workspace/materialize.ex` | Warm-base copy-on-write materialization (copy tree, then delegate branch choice to `Checkout`), with cold-clone fallback signaling. | 90 | `materialize_from_base/2,3`, `copy_tree/2` |
| 8 | `Aiur.Workspace.Provisioner` | `aiur/workspace/provisioner.ex` | The create/reuse/recreate decision table: existing dir reused, stale file replaced, cold create vs prewarm materialize, remote prepare script, forced recreate. | 180 | `ensure_workspace/2,3` (all clauses), `create_workspace/1`, `create_or_materialize/1,2`, `recreate_workspace/2`, `parse_remote_workspace_output/1` + `@remote_workspace_marker`, `maybe_install_agent_skills/2` |
| 9 | `Aiur.Workspace.Hooks` | `aiur/workspace/hooks.ex` | Hook execution engine (env-scrubbed local run, remote run, timeout envelopes, result logging) plus the after_create tri-state and after_run ignore-failure wrappers. | 180 | `run_hook/5` (both), `hook_env/0`, `handle_hook_command_result/4`, `sanitize_hook_output_for_log/2`, `ignore_hook_failure/1`, `maybe_run_after_create_hook/4` (as `run_after_create/4`), `run_after_run_hook/3` body (as `run_after_run/3`) |
| 10 | `Aiur.Workspace.BootstrapImage` | `aiur/workspace/bootstrap_image.ex` | Docker bootstrap-image warm-cache seeding (local + remote), script generation, `@warm_cache_paths`, exit-66 no-cache contract. | 130 | `maybe_seed_from_bootstrap_image/3` (as `maybe_seed/3`), `seed_from_bootstrap_image/5` (both), `bootstrap_image_script/3`, `bootstrap_image_copy_script/0` |
| 11 | `Aiur.Workspace.Refresh` | `aiur/workspace/refresh.ex` | The before_run flow and the stale-workspace refresh decision table (#569 dirty guard, #577 todo-dispatch recreate, #653 non-fatal WIP skip), then metadata check + bootstrap seed. | 140 | `run_before_run_hook/3` body (as `run/3`), `finalize_before_run_workspace/3`, `run_before_run_command/4`, `maybe_recreate_stale_workspace/6`, `stale_leftover_refresh_refusal?/1` |
| 12 | `Aiur.Workspace.Remove` | `aiur/workspace/remove.ex` | Workspace teardown: local/remote removal, before_remove hook (failures tolerated), ssh-host fan-out for closed issues. | 140 | `remove/1,2` (all clauses), `remove_issue_workspaces/1,2` (all clauses), `maybe_run_before_remove_hook/2` (both) |

Total ≈ 1600 LOC (moduledoc/spec overhead over today's 1235). Every file <=200 lines.

**Dependency direction (strictly one-way, top calls down):**

```
Aiur.Workspace (facade)
  → Refresh → Provisioner, GitMetadata, BootstrapImage, Hooks, Context
  → Remove  → Hooks, Remote, Layout, Context
  → Provisioner → Materialize, Remote, Layout   (Provisioner never calls Refresh)
      Materialize → Checkout
      GitMetadata → Checkout (current_branch), Layout (pr_anchored_workspace?), Remote
      BootstrapImage → Hooks (result handling), Remote
      Hooks → Remote, Context (log context)
  → leaves: Checkout, Remote, Layout, Context (no intra-namespace deps)
```

`current_branch/1` gets exactly one home (`Checkout`) — today it is shared by materialize and the PR-anchored lock-path probe; both callers point at the leaf, no duplication (one source of truth per fact).

---

## 3. Extraction sequencing (waves; strictly serialized on this file)

All workspace behavior is exercised through the `Aiur.Workspace` public API in both test files, so every wave keeps tests untouched and green. Verify after each wave: `mix compile --warnings-as-errors` + full `mix test` (at minimum `test/aiur/workspace_and_config_test.exs`, `test/aiur/workspace_materialize_test.exs`). Each wave is one reviewable ticket, <=400 source lines moved.

- **Wave 1 (~330 lines): leaves — `Layout`, `Context`, `Remote`.** Pure/plumbing code with no intra-file dependents that must move first. Facade privates become calls into the new modules. Comments (repo-namespacing rationale, tilde-expansion case) move verbatim.
- **Wave 2 (~300 lines): `Checkout` + `GitMetadata`.** Checkout first within the ticket (GitMetadata needs `Checkout.current_branch/1`). Facade keeps `ensure_git_metadata_writable/2` as a `defdelegate` — `workspace_materialize_test.exs:130` calls it on `Aiur.Workspace`.
- **Wave 3 (~330 lines): `Materialize` + `Provisioner`.** Facade keeps `defdelegate materialize_from_base/2,3` (test seam). `create_for_issue/2` now calls `Provisioner.ensure_workspace/3` inside its unchanged try/rescue; `recreate_workspace/2` becomes `Provisioner.recreate/2`, still called from the refresh code remaining in the facade this wave.
- **Wave 4 (~310 lines): `Hooks` + `BootstrapImage`.** The engine (`run_hook`, timeouts, env scrub, result handling) and its bootstrap-image consumer move together so `handle_hook_command_result/4` never needs a temporary public shim. `run_after_run_hook/3` and the after_create tri-state wrapper delegate from the facade.
- **Wave 5 (~250 lines): `Refresh` + `Remove`; facade finalized.** All dependencies (Provisioner, GitMetadata, BootstrapImage, Hooks, Context) already exist. Facade shrinks to public API + `create_for_issue` orchestration, ~110 lines.

Ordering rationale: leaves → engine/probes → provisioning → hook engine → flows; after every wave each moved function's callees are already extracted, so no forward references, no temporary duplicate definitions, and no wave touches another wave's modules.

---

## 4. Risks: semantics to preserve verbatim

Hotspot map row 4 and the "Workspace refresh & git metadata" chains say this file's regressions are *semantic*, not structural — the split must move these behaviors byte-for-byte:

1. **Exit-65 refresh-refusal contract + non-fatal WIP skip (#569→#577→#595→#653/#656→#661).** `stale_leftover_refresh_refusal?/1` matches exactly `{:workspace_hook_failed, "before_run", 65, _}`; the checked-in `.aiur/hooks` file is the other half of the contract (pinned by test at line 402). Recreate is only for todo dispatches (`todo_dispatch?/1` checks state `"todo"` OR label `"agent:todo"` — the retry path carries the label, not the state); a non-todo dirty refusal must return `:ok` (skip refresh, keep WIP) — turning that into an error re-creates #653 where every PR merge retry-exhausted every in-flight agent. The recreate path re-runs before_run exactly once (test asserts exactly 1 trace line).
2. **Git-metadata probe semantics (regressed 4+ times: #493→#542→#561→#565→#616).** Exact lock list (`index.lock`, `FETCH_HEAD.lock`, `ORIG_HEAD.lock`, `refs/remotes/origin/aiur/<id>.lock`, plus the PR-anchored derived `refs/remotes/origin/<head_ref>.lock`), the rm→`O_EXCL`-create→rm probe sequence, the git-dir-inside-workspace containment guard (remote exit 31), and `:not_git → :ok` passthrough. The remote script must stay byte-identical.
3. **`created?` tri-state `true | false | :materialized`.** `maybe_run_after_create_hook/4` skips on `:materialized` — a warm-materialized workspace is already populated and branched; running the operator's cold-clone after_create hook there is a regression. Do not collapse to a boolean.
4. **Live-origin-tip branching (#567).** `checkout_fresh_branch/1` fetches the base's tracking branch and branches off `origin/<base>`, silently falling back to the copied HEAD (`fresh_base_start_point/1` returning `[]`) when no usable remote — tests pin both the v2-tip case and the fallback.
5. **Timeout envelopes and error-tuple shapes.** Every local hook / remote command runs under `Task.async` + `Task.yield(timeout)` + `Task.shutdown(:brutal_kill)`. Tuple shapes are API: `{:workspace_hook_timeout, hook_name, ms}` (with the remote `"remote_command"` remap to `"bootstrap_image"`), `{:workspace_hook_failed, hook, status, output}`, `{:workspace_prepare_failed, ...}` (arity differs local/remote), `{:workspace_git_metadata_unwritable, ...}` (3-tuple local vs 4/5-tuple remote), `{:workspace_equals_root|_symlink_escape|_outside_root, ...}`. Callers (`AgentRunner`) and tests pattern-match them.
6. **Env scrubbing in local `run_hook` (hotspot theme 5, env leakage).** `Aiur.AgentEnvironment.scrub_shell_command/1` must keep wrapping the hook command — dropping it re-introduces the silent `inet_tcp` node-name clash that voids `deps.get`. Also `hook_env/0`'s `THIS_REPOSITORY_URL`.
7. **`create_for_issue/2` rescue envelope.** The `rescue [ArgumentError, ErlangError, File.Error]` must keep wrapping the *delegated* provisioning calls (raising `File.rm_rf!`/`mkdir_p!` live inside `Provisioner`/`Materialize`); moving work outside the try changes failure mode from `{:error, e}` to crash.
8. **Reuse/idempotency + fan-out.** Existing dir → `{:ok, ws, false}` with no deletion (WIP preserved); stale non-dir replaced; `remove_issue_workspaces(id, nil)` fans out across all configured `ssh_hosts`; remote paths keep tilde expansion (fake-ssh test asserts `${workspace#~/}`).

**Tests pinning this file** (all via the public API, so the facade keeps them green unmodified):
- `src/test/aiur/workspace_and_config_test.exs` (2740 lines, `use Aiur.TestSupport`; ~40 workspace tests, lines 10–1005, 1438–1570, 2564–2634): after_create bootstrap + failure/timeout, `pr-` leaf naming, git-metadata writes/stale-lock repair/outside-workspace rejection, dirty-leftover recreate (todo state + retry label), exit-65 contract, #653 WIP-preserving skip, repo-namespaced paths (determinism, idempotent append, memory-tracker flat fallback), symlink-escape + canonicalized roots, remove-root rejection, agent-skills-only install, bootstrap-image seed/keep, remove fan-out + missing-root/non-binary tolerance, before_remove failure/large-output/timeout tolerance, multiline YAML hooks lifecycle, full remote lifecycle via fake `ssh` shim.
- `src/test/aiur/workspace_materialize_test.exs` (187 lines, async): CoW carry of `_build`, `aiur/<id>` branch pinning (no PR leakage), PR-anchored fetch/checkout + no-remote fallback, metadata repair on materialized workspaces, non-copyable-base error, #567 live-tip.

**Characterization coverage missing (add before/during the touching wave):**
- Remote `ensure_git_metadata_writable/2`: the fake-ssh lifecycle test exits 0 for everything, so the exit-31 containment branch, probe failures, and the `{:workspace_git_metadata_unwritable, ws, host, status, output}` shape are unpinned (wave 2 risk).
- `parse_remote_workspace_output/1` malformed output → `{:error, {:workspace_prepare_failed, :invalid_output, output}}` (wave 3).
- Remote `validate_workspace_path/2` rejects (empty / newline / NUL) (wave 1).
- `create_or_materialize` gate itself (prewarm enabled but `RepoBase.status` not `:ready` → cold fallback) — materialize tests bypass the gate by calling `materialize_from_base` directly (wave 3).
- `run_remote_command/3` timeout (Task.yield nil → brutal_kill) and the bootstrap-image timeout remap; remote `seed_from_bootstrap_image` clause; copy-script exit-66 "no cache paths" branch (wave 4).
- Remote `recreate_workspace/2` clause (wave 3).
- `maybe_recreate_stale_workspace` with `before_run == nil` (error passthrough) (wave 5).
- `run_after_run_hook` failure-ignored path (only before_remove tolerance is pinned) (wave 4).
- Env scrub applied in `run_hook` — no test pins `scrub_shell_command` being invoked; a silent drop reproduces the masked deps.get failure (wave 4).
