---
title: "fix: Make repository context explicit"
type: fix
date: 2026-08-16
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: issue-2037
---

# fix: Make repository context explicit

## Goal Capsule

Prevent an issue worker's destructive Git command from inheriting an unintended working directory, and make every successful Aiur launch name the absolute config path it actually selected.

---

## Problem Frame

Repository context and workflow config selection currently depend on ambient cwd. A disappeared worktree can therefore redirect a destructive command into an operator checkout, while launching from a repository subdirectory can silently select a global config. The fix must make agent Git context explicit, enforce that requirement for destructive forms, and expose the effective config without changing discovery precedence.

---

## Requirements

- **R1:** The canonical issue-worker manual requires `git -C <absolute-worktree>` for repository operations and forbids selecting Git context with `cd`.
- **R2:** The agent-installed `git` wrapper refuses `reset --hard`, force-clean, path checkout/restore, and `worktree remove` unless an explicit absolute `-C` resolves to the wrapper's owning workspace root.
- **R3:** Successful foreground and background launches print the absolute workflow config path selected by the running node; explicit and discovered configs use the same output contract.
- **R4:** Existing config precedence remains unchanged: local `.aiur/config`, local `.aiurconfig`, global `.aiur/config`, global `.aiurconfig`.
- **R5:** CLI documentation describes the startup config-path line.

## Scope Boundaries

- Keep the shared `aiur`/`aiurdev` launcher behavior aligned; do not force aiurdev to a repo-root config.
- Do not bulk-edit pinned Compound Engineering skills. The canonical `aiur-agent` instruction establishes the rule, and the Git wrapper enforces the destructive subset independent of prose.
- Do not add general OS-user containment or prohibit legitimate read-only Git commands. The wrapper is an accidental-safety policy boundary, not protection from a process deliberately invoking the exposed real-Git path.

---

## Key Technical Decisions

1. **Relay the CLI-selected path across the tmux capture boundary.** `Aiur.CLI.run/3` owns the authoritative expanded path before application startup. It emits one machine-greppable marker into the boot capture, and the shared launcher replays that marker for fresh launches without reimplementing discovery in shell.
2. **Enforce destructive context in the existing agent Git wrapper.** `src/priv/github_push_guard.sh` already reaches local and remote issue workers, so it is the narrowest structural guard seam.
3. **Derive authority from the installed wrapper path.** The expected workspace is the canonical parent of the wrapper's `.aiur-runtime/bin/git` location; `AIUR_AGENT_WORKSPACE` is only a consistency check because a child process can rewrite environment values. Git walks upward from nested `-C` paths, so their canonical top level must equal that derived workspace.
4. **Keep one skill source.** `.claude/skills/aiur-agent/` is embedded into provisioned workspaces and exposed to Codex through a symlink; duplicate backend copies would drift.

---

## Implementation Units

### U1. Teach explicit repository context

**Goal:** Make the safe Git invocation rule unavoidable in the canonical issue-worker workflow.

**Requirements:** R1.

**Dependencies:** None.

**Files:** `.claude/skills/aiur-agent/dev-loop.md`, `src/test/aiur/aiur_agent_skill_test.exs`, `src/test/aiur/agent_skills_test.exs`.

**Approach:** Add a repository-command safety section near branch setup. Require an absolute workspace path and `git -C` for repository commands, enumerate destructive forms, and correct examples in the same manual that contradict the rule.

**Patterns to follow:** Existing content-contract tests in `src/test/aiur/aiur_agent_skill_test.exs`; canonical Claude source with Codex symlink exposure.

**Test scenarios:** The skill-content test fails if the `git -C`, absolute-path, no-`cd`, or destructive-command language disappears; existing Codex symlink coverage still resolves the canonical content; a fresh compiled-skill installation materializes the updated guidance.

**Verification:** A freshly bundled issue-worker manual contains one internally consistent repository-context rule.

### U2. Guard destructive agent Git commands

**Goal:** Make a forgotten or wrong repository path fail before Git mutates state.

**Requirements:** R2.

**Dependencies:** U1.

**Files:** `src/priv/github_push_guard.sh`, `src/test/aiur/agent_github_guard_test.exs`.

**Approach:** Parse Git global options through the subcommand, retain explicit `-C` in either supported spelling, recognize only the destructive command forms named by R2, derive the expected workspace from the installed wrapper location, and fail closed unless the target is absolute, exists, and resolves to that canonical top level. Reject competing `--git-dir`/`--work-tree` options and `GIT_DIR`/`GIT_WORK_TREE` environment context on destructive forms. Treat `AIUR_AGENT_WORKSPACE` as an optional consistency check. Pass non-destructive commands through unchanged.

**Execution note:** Add failing wrapper tests before changing the embedded shell guard.

**Patterns to follow:** Existing real-Git wrapper tests and `AIUR_AGENT_WORKSPACE` environment contract.

**Test scenarios:**

1. `reset --hard`, force-clean, path checkout/restore, and `worktree remove` without `-C` are refused before real Git runs.
2. A nonexistent, relative, or different-worktree `-C` target is refused.
3. An absolute root or nested path whose canonical Git top level equals the expected workspace permits the destructive command.
4. Read-only commands continue to work without `-C`.
5. Both `-C <path>` and `-C<path>` are recognized.
6. Unsetting or falsifying `AIUR_AGENT_WORKSPACE` cannot redirect the derived expected root.
7. `--git-dir`, `--work-tree`, `GIT_DIR`, and `GIT_WORK_TREE` cannot override a validated `-C` on destructive forms.

**Verification:** The incident command shape cannot execute against ambient cwd, while ordinary Git inspection remains compatible.

### U3. Print the selected config at startup

**Goal:** Make an unexpected workflow selection visible on every successful run.

**Requirements:** R3, R4.

**Dependencies:** None.

**Files:** `src/lib/aiur/cli.ex`, `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `src/test/aiur/cli_test.exs`, `src/test/aiur_engine_test.exs`.

**Approach:** Emit a unique marker from `Aiur.CLI.run/3` after the workflow path is expanded and validated but before application startup. Add a launcher helper that extracts and prints one stable `Config:` line from the startup capture after readiness and before dashboard/session success output. Fresh launch failures already replay the boot capture; idempotent already-running background starts print no new config claim because they loaded nothing.

**Patterns to follow:** Existing CLI `capture_io` tests, dashboard startup reporting, and sourced-engine launcher tests.

**Test scenarios:**

1. CLI selection emits a marker carrying an absolute config path containing spaces.
2. Foreground and background success paths print config status before their normal success lines.
3. An idempotent already-running background invocation does not claim to have loaded a config.
4. Existing Workflow/CLI tests continue to prove local, legacy, global, and explicit precedence unchanged.

**Verification:** Startup output names the exact expanded path selected by `Aiur.CLI` without altering argv or discovery.

### U4. Document and validate the operator contract

**Goal:** Keep the CLI reference and delivery gate aligned with the new visible behavior.

**Requirements:** R5.

**Dependencies:** U1, U2, U3.

**Files:** `website/docs-app/reference/cli.md`.

**Approach:** Amend the existing launch/aiurdev section to state that startup prints the absolute selected config path and that selection still follows documented precedence.

**Test expectation:** No separate docs test; launcher regression coverage enforces the described line.

**Verification:** The CLI reference tells operators exactly where to look when the selected config is unexpected.

---

## Risks & Mitigations

- **Git option parsing:** A loose word search can mistake a ref or path for a subcommand. Parse global options until the real subcommand and test both `-C` spellings.
- **Nested path false safety:** `git -C` walks upward. Compare canonical `--show-toplevel` output with the canonical expected workspace.
- **Launcher capture boundary:** A marker written only inside tmux is still invisible. Replay exactly one marker from the existing boot capture and test output ordering.
- **Bundled skill rollout:** Skill bytes and the Git wrapper are compile-time release resources; compile/release validation must prove the changed resources are embedded.

---

## Verification Contract

- Compile with warnings as errors and format all touched Elixir files.
- Run `src/test/aiur/aiur_agent_skill_test.exs`, `src/test/aiur/agent_skills_test.exs`, `src/test/aiur/agent_github_guard_test.exs`, `src/test/aiur/cli_test.exs`, and `src/test/aiur_engine_test.exs` with the repository's four-case cap.
- Verify fresh installs materialize the updated skill and Git-wrapper bytes from the compiled resource modules, proving release packaging sees both changes.
- Use the affected-test task to confirm the scoped set.
- Exercise the non-destructive launcher path available inside an agent workspace; do not run guarded `--test`/`--test3` manual scenarios.

## Definition of Done

- Canonical issue-worker guidance uses explicit absolute Git context.
- Wrapper-routed destructive Git commands are refused without the expected `-C` worktree, with the policy-boundary limitation documented honestly.
- Successful launches print the absolute effective config path.
- CLI documentation matches the output.
- Scoped compile, format, and affected tests pass; the draft PR targets `main` and is ready for CI.
