---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
date: 2026-08-21
---

# CI Test Flake Mechanisms — Plan

## Goal Capsule

**Objective.** Remove the causal timing, global-log, config-memo, and cross-VM fixture races behind the named unrelated CI failures without reducing suite concurrency or hiding failures behind retries.

**Product authority.** Issue #2214 and its CODEOWNER diagnostic comments, 2026-08-21.

**Open blockers.** None.

---

## Product Contract

### Problem Frame

Unrelated pull requests repeatedly fail different tests only under parallel suite load. The failures come from independent mechanisms: mailbox deadlines used as synchronization, assertions over the global Logger capture, parsed configuration cached without content identity, and temporary release paths unique only inside one BEAM VM.

### Requirements

- R1. The named decision-store and placeholder tests must synchronize on causal events rather than sub-second scheduling deadlines.
- R2. Upgrade tests must assert that their own notice was not logged, not that no process logged anything.
- R3. Parsed config memoization must not return settings derived from different workflow content when a generation identifier is reused or an old reader publishes late.
- R4. Engine build-stamp fixtures must be host-unique across concurrent Mix VMs.
- R5. Repeated parallel runs of the affected tests must pass without lowering `max_cases`, adding retries, or quarantining failures.
- R6. CI reruns must leave an observable marker through the existing run summary rather than silently looking like first attempts.

### Scope Boundaries

In scope are the named failure mechanisms and a narrow CI run-attempt summary. Out of scope are a repository-wide rewrite of every finite test timeout, a new CI telemetry service, production build-stamp delays, and reduced coverage-partition concurrency. The endpoint/provisioner failures reported later remain evidence of shared lifecycle pressure; they are not changed without a deterministic local root cause.

---

## Planning Contract

### Key Technical Decisions

- **Causal barriers, not larger clocks.** Use `receive_barrier/1`, synchronous tmux mock replies, and `refute_received` after the opener barrier. This follows `CONTRIBUTING.md` and avoids turning a 100 ms bet into a 2 s bet.
- **Each workflow publication identifies parsed settings exactly.** Stamp every cache publication with a fresh collision-free reference and include `{generation, publication}` in both parsed-settings and environment-name memo keys. Do not use a bounded term hash: an identity collision would reintroduce the correctness defect. A delayed old reader may republish its result, but its old publication reference cannot match the current workflow.
- **Host identity belongs in fixture paths.** Route the shared engine release helper through `Aiur.TestSupport.tmp_root!/1`, which includes the OS PID, and register cleanup from the calling test.
- **Rerun visibility stays local to the required workflow.** A small tested script writes `github.run_attempt` to the step summary when it is greater than one. Invoke it immediately after checkout in every blocking job, so selectively rerun failed and matrix jobs disclose the new attempt; keep `workflow-security` responsible for testing that invariant. Do not add a forbidden `workflow_run` collector.

### Risks and Dependencies

- Cache-key changes sit on a hot read path. Use a constant-size publication reference and keep the ETS lookup count unchanged; do not copy or structurally compare the full config term on each read.
- Placeholder tests are `async: true`; retain that property and use the mock transport's existing `:infinity` seam rather than serializing the module.
- The build-stamp CI excerpt is unavailable locally. Before changing the fixture, reproduce the current path collision with two fresh Mix VMs that generate the same VM-local integer under the shared temp root; if that signature cannot be reproduced, defer U4 rather than claiming it fixes the named failure.

---

## Implementation Units

### U1. Replace mailbox clocks with barriers

**Goal.** Make decision-store serialization and placeholder tmux interaction causal.

**Requirements.** R1, R5.

**Files.** `src/test/aiur/decision_store_test.exs`, `src/test/aiur/pane_manager/placeholder_test.exs`.

**Approach.** After the decision opener proves the answer path is blocked, establish that the answer call has reached the blocked store with a causal test-only observation, use `refute_received`, release it, and establish completion through messages received after causal barriers. In placeholder tests, import `receive_barrier/1`, run the tmux mock with an infinite transport timeout, and centralize command receipt plus response so every expected command is acknowledged and no helper silently succeeds after 200 ms.

**Test scenarios.** The answer cannot complete before the opener releases; it completes afterward. Every placeholder flow observes commands in order, replies to each, and returns its new state under repeated parallel runs.

**Verification.** No touched synchronization path uses an explicit or default finite receive deadline; completion is established with `receive_barrier/1` and checked afterward with `assert_received`/`refute_received`.

### U2. Narrow upgrade log assertions

**Goal.** Prove each no-op upgrade path emits no upgrade notice while tolerating unrelated Logger output.

**Requirements.** R2, R5.

**Files.** `src/test/aiur/upgrade_test.exs`.

**Approach.** Replace whole-capture equality with absence of the `aiur_upgrade` marker or the exact notice text, retaining transport-count and state assertions.

**Test scenarios.** Stored, missing, disabled, and already-notified paths reject their own notice even if another process logs concurrently.

**Verification.** No `assert log == ""` remains in the upgrade test.

### U3. Bind config memoization to workflow content

**Goal.** Prevent valid repository settings from surviving a malformed config transition through a reused cache generation.

**Requirements.** R3, R5.

**Files.** `src/lib/aiur/config.ex`, `src/lib/aiur/workflow_store/cache.ex`, `src/test/aiur/workflow_store_test.exs`, `src/test/aiur/github/issues_test.exs` when needed for the end-to-end repository assertion.

**Approach.** Create a fresh reference atomically with each workflow cache publication and include `{generation, publication}` in the parsed-settings key and environment-name dependency key. Add a deterministic ABA regression that captures an old memo, publishes different workflow content under the same generation, republishes the old memo as a delayed reader would, and proves `GitHub.Config.configured_repo/0` sees the current malformed repository. The regression must assert that the key carries a reference, not merely two convenient non-colliding fixtures.

**Test scenarios.** Repeated reads within one `{generation, publication}` reuse the memo; a fresh publication misses even when its content and generation match the prior publication; different content under the same generation misses a late stale memo; malformed configured repositories remain `:invalid_configured_repository` after a valid predecessor.

**Verification.** The regression fails when workflow identity is removed from the key and passes with the fix.

### U4. Make engine release fixtures host-unique

**Goal.** Stop concurrent Mix VMs from sharing or deleting the same fake release and build stamp.

**Requirements.** R4, R5.

**Files.** `src/test/aiur_engine_test.exs`.

**Approach.** Build `fake_release/0` under `Aiur.TestSupport.tmp_root!/1` and register cleanup. Keep production shell behavior unchanged.

**Test scenarios.** Investigation evidence from fresh Mix VMs demonstrates that the old VM-local integer path can collide. The automated regression asserts that replacement roots contain the current VM's OS PID, while restart/build-stamp tests continue to assert the same shell contract.

**Verification.** The shared fake release path includes host process identity and is removed after each test.

### U5. Expose rerun attempts

**Goal.** Make repeat CI attempts visible without adding a privileged cross-workflow collector.

**Requirements.** R6.

**Files.** `.github/workflows/ci.yml`, `scripts/report-ci-run-attempt.sh`, `scripts/test-report-ci-run-attempt.sh`.

**Approach.** Add a pure shell reporter that accepts the attempt number and summary path, then appends a concise rerun marker only when the attempt exceeds one. Invoke it immediately after checkout in every blocking job, so selective failed-job reruns also disclose their attempt before any fallible repository checks. This is intentionally per-run disclosure, not an aggregate rerun-rate service.

**Test scenarios.** Invalid attempt values fail with a diagnostic; attempt one adds no rerun warning; attempt two or later reports the attempt number; every blocking job carries the disclosure immediately after checkout.

**Verification.** The script test covers invalid, first, and repeated attempts; dynamically enumerates every blocking workflow job; and repository workflow-security checks pass.

---

## Verification Contract

- Compile with warnings as errors and run formatting.
- Compute and run every affected test with `--max-cases 4`; this is the required agent-local resource-safety gate, not the loaded-suite acceptance proof.
- Repeat the named test files together across at least five seeds with `--max-cases 4` as focused regression evidence.
- Require the authoritative uncapped CI coverage-partition layout to pass as the acceptance evidence for representative host load. Do not emulate that layout by launching competing uncapped Mix VMs in the shared agent workspace.
- Run workflow-security checks if U5 changes CI YAML.
- Self-review the pushed diff with `ce-code-review`; no required user docs are expected because this restores internal test/cache behavior.

---

## Definition of Done

- The named mailbox assertions no longer use explicit or default finite deadlines as synchronization.
- Upgrade no-op tests reject only their own log message.
- Config memo keys include a collision-free workflow publication identity and a deterministic ABA regression proves the stale-memo failure.
- Investigation reproduces the pre-fix engine fixture collision across fresh VMs; the automated regression proves replacement release paths are OS-PID-qualified and cleaned up.
- Repeat CI attempts are disclosed in the affected run summary; no aggregate rerun-rate claim is made.
- Scoped compilation, formatting, affected tests, repeated parallel tests, and self-review pass; abandoned experiments are absent from the diff.
