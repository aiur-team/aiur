---
title: Sandbox Derived Writable Roots - Plan
type: fix
date: 2026-08-21
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Sandbox Derived Writable Roots - Plan

## Goal Capsule

- **Objective:** Prevent Codex agents from starting with stale or incomplete local `workspaceWrite` roots that make coordinated GitHub operations fail closed mid-turn.
- **Authority:** Issue #2238 acceptance criteria and repository operating rules override this plan; existing sandbox containment and broker fail-closed behavior remain intact.
- **Stop conditions:** Do not broaden local agents to sibling ticket workspaces, validate daemon-host paths as though they existed on SSH workers, or allow an unavailable broker to fail open.
- **Tail ownership:** Implementation includes mutation-sensitive tests, configuration documentation, the dogfood config cleanup, scoped verification, PR self-review, and CI handoff.

---

## Product Contract

### Summary

Aiur will derive lifecycle-owned local sandbox roots from authoritative runtime state, treat configured roots as validated extras, and report the exact budget root and configuration remedy when the GitHub guard still cannot write its shared state.

### Problem Frame

Configured Codex `writableRoots` are normalized as data but never checked for existence or daemon-user writability. The runtime appends the current issue workspace, package caches, and build-gate metadata, but omits the shared GitHub budget directory exported to the same agent. A stale configured path therefore survives preflight while the missing budget grant is discovered only after an agent invokes `gh`.

### Requirements

#### Root construction and validation

- R1. Every local `workspaceWrite` turn derives the current issue workspace from the configured `workspace.root` lifecycle instead of requiring an absolute workspace path in `writableRoots`.
- R2. When the local shared GitHub broker is enabled, its authoritative state directory is prepared and included in the turn sandbox exactly once.
- R3. Operator-configured writable roots are optional extras that must be existing writable directories on the daemon host; invalid entries fail configuration validation and runtime policy resolution with the exact path and configuration key.
- R4. Read-only, danger-full-access, future policy types, disabled-budget operation, and SSH-worker host-local roots retain their existing boundaries; daemon-host configured extras are not forwarded to remote workers.

#### Failure reporting and documentation

- R5. The fail-closed GitHub guard names the unavailable derived budget root, identifies the compatibility configuration surface that can grant it on stale runtimes, and directs current runtimes to repair host permissions and redispatch without contacting GitHub.
- R6. Configuration docs and checked-in examples explain derived roots and remove machine-specific workspace and budget paths from the dogfood policy.

### Acceptance Examples

- AE1. Given a unique nonexistent configured root, when configuration validation runs, then it returns an error containing that path and `agent.codex.turn_sandbox_policy.writableRoots`.
- AE2. Given a valid local policy with no explicit workspace or budget path, when a turn policy is resolved, then it contains the canonical issue workspace and enabled `Budget.state_dir()` exactly once alongside existing derived roots.
- AE3. Given a sandbox that cannot create or use the budget directory, when guarded `gh` runs, then it exits before the real executable, names the root, and gives the configuration remedy.

### Scope Boundaries

- SSH worker roots remain resolved on the remote host; daemon-host configured extras are validated locally and are not forwarded or probed remotely.
- The GitHub broker continues to fail closed; this change does not relax admission or add an uncoordinated fallback.
- The current issue workspace remains the derived workspace grant; the parent workspace root is not granted wholesale to avoid cross-ticket writes.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Validate declared extras with filesystem type checks plus a bounded create/delete write probe. Permission bits alone do not represent ACLs or the daemon user's effective access, while `PathSafety.canonicalize/1` intentionally permits nonexistent suffixes.
- KTD2. Compose the budget root in `Aiur.Config` beside package-cache and build-gate augmentation, using `Aiur.GitHub.Budget` as the single state-directory authority and skipping local host paths for remote turns.
- KTD3. Keep the guard's status-75 refusal and strengthen its deterministic stderr contract. The observed `github-budget-root-readonly` alert is agent-authored rather than a product-defined alert, so actionable guard evidence is the stable repository-owned seam. The message distinguishes the compatibility `writableRoots` grant from current-runtime permission repair and redispatch.

### Assumptions

- Holding dispatch through `Config.validate!/0` satisfies the acceptance requirement to reject or warn loudly at startup while keeping the daemon available for diagnosis.
- Lifecycle-owned derived directories may be created by their owning components; only operator-declared extra roots must pre-exist.
- Local agents run as one OS user and remain in the broker's existing same-trust domain: granting the shared budget/cache root is a coordination requirement, not a cross-ticket capability boundary. Narrow IPC and per-ticket cache isolation are outside this bug fix.

### Sequencing

Validate configured extras first, then add the prepared budget root to effective local policies, update the guard diagnostic, and finally remove redundant machine paths from configuration and documentation.

---

## Implementation Units

### U1. Validate and compose local sandbox roots

- **Goal:** Reject unusable configured extras and construct complete local `workspaceWrite` policies from authoritative workspace and budget state.
- **Requirements:** R1, R2, R3, R4; KTD1, KTD2.
- **Dependencies:** None.
- **Files:** `src/lib/aiur/config/codex_sandbox_policy.ex`, `src/lib/aiur/config.ex`, `src/test/aiur/workspace_and_config_test.exs`.
- **Approach:** Add a dedicated daemon-host configured-root validator without changing generic path canonicalization. Run it during semantic validation and local runtime resolution. Prepare and append the enabled local budget directory through the existing runtime augmentation pipeline; remote turns derive only remote-host roots, while non-`workspaceWrite` branches remain unchanged.
- **Patterns to follow:** `Aiur.BuildGate.prepare_writable_root/1`, `Aiur.GitHub.Budget.ensure_state_dir/1`, and existing sandbox root deduplication.
- **Test scenarios:** Covers AE1: nonexistent, regular-file, and effectively unwritable configured roots fail with exact actionable context. Covers AE2: valid configured extras remain locally while issue workspace, budget, package caches, and build gate are derived once. Disabled budget omits its root. Remote policy omits daemon-host extras and non-write policies remain unchanged.
- **Verification:** Reverting the configured-root validator makes the bogus-root assertion fail; removing budget augmentation makes the effective-policy assertion fail.

### U2. Make broker failure actionable

- **Goal:** Ensure the last-resort fail-closed error identifies the inaccessible shared state and its recovery surface.
- **Requirements:** R5; KTD3.
- **Dependencies:** U1.
- **Files:** `src/priv/github_quota_guard.sh`, `src/test/aiur/agent_github_guard_test.exs`.
- **Approach:** Include the exact budget root in early directory-preparation and later broker-failure diagnostics without exposing credentials. Explain that current runtimes derive the grant and need host permission repair plus redispatch; retain the configuration key only as a compatibility remedy for stale runtimes.
- **Patterns to follow:** Existing status-75 guard refusal tests that assert the fake `gh` executable is never called.
- **Test scenarios:** Covers AE3: an unavailable root yields actionable stderr and no network call. A broker failure after directory preparation carries the same root context. Token and fingerprint values remain absent.
- **Verification:** Guard tests assert exit status, exact root/config hints, and zero real-`gh` calls.

### U3. Remove drift-prone configuration

- **Goal:** Document construction semantics and delete redundant machine-specific roots from tracked policy.
- **Requirements:** R6.
- **Dependencies:** U1.
- **Files:** `.aiur/config`, `.aiur/examples/config.example`, `website/docs-app/reference/configuration.md`, `src/README.md`.
- **Approach:** Describe configured roots as validated extras and derived local roots as runtime-owned. Retain only intentional extras in the dogfood config.
- **Patterns to follow:** Existing configuration reference entries and derived build-gate root documentation.
- **Test scenarios:** The current checked-in config validates after machine-specific roots are removed; documentation checker continues to recognize the existing config key.
- **Verification:** The tracked config contains no per-machine workspace or budget path and the effective-policy tests prove access remains.

---

## Verification Contract

- `mise exec -- mix compile --warnings-as-errors` passes from `src/`.
- `mise exec -- mix format` reports no remaining formatting changes.
- `mise exec -- mix aiur.affected_tests` identifies the scoped test set, and every emitted `mix test` invocation passes with `--max-cases 4`.
- The mutation-sensitive bogus-root test fails if configured-root validation is removed.
- The guard test proves no real GitHub command runs on budget-root failure.

---

## Definition of Done

- U1 through U3 satisfy their requirements and test scenarios with no abandoned implementation paths in the diff.
- Local policy construction no longer depends on checked-in absolute workspace or budget paths.
- Invalid configured roots are rejected before an agent turn and the fallback guard error is actionable.
- Required documentation is correct, the scoped local gate passes, and the draft PR is self-reviewed against `main` before CI handoff.
