---
title: "fix: Close the Claude adapter release gap"
date: 2026-09-02
type: fix
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Close the Claude Adapter Release Gap

## Goal Capsule

- **Objective:** Keep Claude agents fail-open while ensuring Aiur never presents an unavailable adapter release as its primary recovery path and makes a known degraded adapter visible during a run.
- **Authority:** GitHub issue #2503, the released `aiur-claude` v1.1.0 tag, and the current `@min_claude_version "1.1.0"` coordination-tool contract.
- **Stop conditions:** Init distinguishes published, unpublished, and unverifiable npm state; fresh and stale installs receive viable pinned commands; a headless Claude run emits a durable non-blocking degradation attention; required Aiur CI proves its declared minimum is obtainable from npm; operator docs match the behavior.
- **Tail ownership:** Complete scoped local verification, mutation-check new tests, self-review a draft PR against `main`, and hand it to CI. The PR cannot become green until an npm credential holder publishes 1.1.0.

---

## Product Contract

### Summary

Aiur continues to require `aiur-claude` 1.1.0 because that is the first adapter with coordination tools. When the exact npm release is missing, Aiur leads with the GitHub release pinned to commit `3478281243bfec8b9e1719461ff17c836c07c5b8` instead of a command known to 404, and it carries known degradation into the durable run alert feed rather than relying only on a scroll-past init warning.

### Requirements

- R1. Preserve the minimum Claude adapter version at 1.1.0 and preserve fail-open behavior: install, registry, version, and alert failures must not stop initialization or agent execution.
- R2. Classify the exact npm release as available, positively not found, or unverifiable. Only a confirmed 404 may be described as a pending npm publication; network, timeout, server, and malformed-response failures remain explicitly uncertain.
- R3. For an installed version below the minimum, print recovery instructions that first uninstall the existing global package, then use exact npm 1.1.0 when available or `github:aiur-team/aiur-claude#3478281243bfec8b9e1719461ff17c836c07c5b8` when npm is confirmed missing. An unverifiable registry result must not make a false availability claim and must lead with the commit-pinned GitHub source while presenting exact npm as an alternative.
- R4. A missing adapter install must never install floating npm `latest`. Install exact npm 1.1.0 when available; for a confirmed 404 or unverifiable registry result, install the commit-pinned GitHub release so initialization never falls back to npm 1.0.0.
- R5. Starting a local headless Claude adapter session with a known installed version below 1.1.0 emits a durable ticket-scoped, needs-attention warning naming the unavailable coordination tools and actionable recovery. A later capable version resolves an active degradation condition, and repeated stale checks do not duplicate it. Unknown/custom/remote command state leaves the durable condition unchanged and emits at most a sanitized transient log warning. The check must not block the session.
- R6. Required Aiur CI checks npm obtainability when the minimum-version declaration changes, and a scheduled monitor detects later registry drift without blocking unrelated pull requests during an npm incident. Both paths distinguish confirmed absence from registry infrastructure uncertainty and have deterministic tests. The change-scoped gate is expected to remain red until an npm credential holder publishes 1.1.0.
- R7. Existing operator documentation describes the minimum-version behavior, durable degradation warning, and pinned recovery path accurately.

### Scope Boundaries

- Publishing `aiur-claude` to npm and adding package-version release automation belong to the separate `aiur-team/aiur-claude` repository and require credentials unavailable in this workspace. This PR does not claim to perform either action.
- Do not lower the 1.1.0 gate, fail closed, automatically uninstall a working adapter, or add a broad agent-status schema solely for this condition.
- Limit runtime reporting to sessions that actually select the local headless `claude` backend; do not warn Codex, Claude REPL, or remote-control sessions based only on repository-wide configuration.

### Acceptance Examples

- Installed 1.0.0 plus npm 404 prints that npm publication is pending and leads with uninstall plus the commit-pinned GitHub install.
- Installed 1.0.0 plus npm 200 leads with uninstall plus exact npm 1.1.0.
- Installed 1.0.0 plus registry timeout says availability could not be confirmed, leads with the commit-pinned GitHub source, and offers exact npm without claiming the release is pending.
- Missing executable installs exact npm after a confirmed 200 and the commit-pinned GitHub release after a 404 or unverifiable lookup; it never installs floating `latest`.
- A ticket launched through local headless Claude 1.0.0 keeps running and receives one durable degraded-adapter attention; a later run on 1.1.0 resolves that condition, while unknown state changes neither condition.
- CI fails with a specific missing-release result while npm lacks 1.1.0, then passes without a code change after the operator publishes that exact version.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Introduce a shared Claude adapter health module as the single owner of the minimum version, exact npm lookup, install source, and remediation text so init, runtime, and CI-facing source extraction cannot drift independently.
- KTD2. Query the npm registry over a bounded, injectable transport and preserve a three-way result. A transport failure is not evidence of non-publication.
- KTD3. Keep automatic init behavior non-destructive. The fresh-install path selects a viable exact source; stale installs receive explicit uninstall/reinstall instructions rather than being removed automatically.
- KTD4. Perform runtime health reporting asynchronously at the actual local headless Claude dispatch boundary. Emit a stable ticket-scoped attention through the durable alert system while allowing the provider session to proceed.
- KTD5. Run the public npm-obtainability check in the existing required `lint` job only when the declared minimum changes, and run the same check on a schedule for later drift. This repository can enforce the availability of the version it requires without making every pull request depend on npm uptime; strict sibling `package.json`-to-npm equality and publish automation remain upstream responsibilities because a normal required PR equality gate would deadlock intentional pre-publication version bumps.

### Assumptions

- A durable ticket attention visible in Aiur's alert feed satisfies the issue's requirement that operators can detect degradation from run behavior; no new `aiur status` or AgentList field is required.
- The upstream v1.1.0 tag currently resolves to reviewed release commit `3478281243bfec8b9e1719461ff17c836c07c5b8`; the full commit, not the movable tag name, is the non-npm installation source.
- The npm publication is an external prerequisite, not authorization to modify or publish the sibling repository from this workspace.

### Risks

- A registry check on every relevant init can add latency or fail under transient network conditions; use a short timeout and fail-open tri-state messaging.
- Runtime checks can duplicate alerts or delay dispatch if placed incorrectly; run them out of band and use stable condition semantics.
- A live registry dependency can fail during npm incidents; keep pull-request enforcement scoped to declaration changes and report scheduled-check infrastructure uncertainty distinctly so it cannot be mistaken for version drift.

### Sequencing

Build and test the shared release/health contract first, wire init behavior second, add dispatch-time durable reporting third, then add the deterministic/live CI guard and documentation. The external npm publish is required only for the live gate to turn green, not for local implementation or review.

---

## Implementation Units

### U1. Share exact release resolution and honest init remediation

- **Goal:** Give fresh and stale installations one truthful source-selection contract.
- **Requirements:** R1-R4.
- **Dependencies:** None.
- **Files:** `src/lib/aiur/claude/adapter_health.ex`, `src/lib/aiur/init/agent_cli.ex`, `src/lib/aiur/init/runtime.ex`, `src/test/aiur/claude/adapter_health_test.exs`, `src/test/aiur/init/agent_cli_test.exs`, `src/test/aiur/init_test.exs`.
- **Approach:** Move the minimum version and install specs into a shared module; add an injectable, bounded exact-version registry lookup; distinguish available/not-found/unknown; make the missing executable installer accept an exact selected spec; select the commit-pinned GitHub source for both not-found and unknown fresh installs; render uninstall-first guidance without automatically uninstalling stale installations.
- **Test scenarios:** npm 200, confirmed 404, timeout/5xx/malformed responses; stale/current/unparseable installed versions; missing executable source selection; install and lookup failures preserve successful init completion.
- **Verification:** Reverting release classification or source selection must make the focused tests fail. Search the entire test tree for changed function names/signatures before push.

### U2. Persist known Claude-session degradation

- **Goal:** Make degraded coordination visible during the run that experiences it.
- **Requirements:** R1, R5.
- **Dependencies:** U1.
- **Files:** `src/lib/aiur/agent_runner/session_lifecycle.ex`, shared adapter-health module, and directly related session lifecycle/alert tests.
- **Approach:** At local headless `claude` dispatch, start a fail-open asynchronous health report that checks the actual adapter command/version, emits one stable ticket-scoped warning when it is known below the minimum, and resolves an active condition when a known-capable version is later observed. Unknown/custom/remote state leaves the condition unchanged. Persist only normalized status, a validated version, the static tool list, and static remediation text; never persist command text, paths, environment values, stdout, stderr, or raw exceptions.
- **Test scenarios:** stale local adapter emits needs-attention with tools and recovery once; a later capable adapter resolves it; repeated stale checks deduplicate; custom/unparseable state leaves the condition unchanged and logs no secret-bearing diagnostics; alert/check failures do not affect session execution; non-Claude backends do not run the check.
- **Verification:** Reverting the dispatch hook or changing stale classification to healthy must fail the new tests; assertions inspect the durable alert envelope, not only logs.

### U3. Gate Aiur's declared minimum on npm availability

- **Goal:** Prevent Aiur from silently merging a minimum-version recommendation that users cannot install from npm.
- **Requirements:** R6.
- **Dependencies:** U1 establishes the source-of-truth declaration.
- **Files:** `packaging/scripts/check-claude-adapter-release.mjs`, `packaging/scripts/test/check-claude-adapter-release.test.mjs`, `.github/workflows/ci.yml`.
- **Approach:** Extract the declared minimum from the shared module, query the exact public npm version, return distinct failures for missing release and transport uncertainty, invoke the live check from the existing required lint job when that declaration changes, and invoke it from a scheduled workflow for later drift. Keep network parsing independently unit tested with injected responses.
- **Test scenarios:** matching published version passes; 404 fails as unpublished; timeout/5xx/malformed metadata fails as infrastructure uncertainty; missing or malformed source declaration fails deterministically.
- **Verification:** The Node test file is named in output. The live command is expected to fail before external publication and pass afterward without repository changes.

### U4. Correct operator documentation

- **Goal:** Ensure every existing user-facing description gives the viable recovery path and explains persistent degradation visibility.
- **Requirements:** R7.
- **Dependencies:** U1-U3 define final behavior.
- **Files:** `website/docs-app/reference/configuration.md`, `src/docs/troubleshooting.md`, and any existing Claude setup page discovered during implementation.
- **Approach:** Replace stale or floating install advice with the exact npm/tagged GitHub rules, document fail-open degradation and the alert, and avoid duplicating the release workflow owned by the adapter repository.
- **Test expectation:** Documentation mirrors behavior proven by U1-U3.
- **Verification:** Search all tracked documentation for `aiur-claude`, `1.1.0`, and obsolete install commands and account for every hit.

---

## Verification Contract

- Read `src/.formatter.exs` and Credo settings before editing Elixir, then run `cd src && mise exec -- mix compile --warnings-as-errors`.
- Run `cd src && mise exec -- mix format` and confirm the resulting diff is intentional.
- Run `cd src && mise exec -- mix aiur.affected_tests`, then execute every printed affected-test command with `mix test --max-cases 4`.
- Run the focused Node release-check test and confirm its filename appears in output.
- For every new behavioral test, use an isolated worktree to remove the production hunk, assert the intended test fails with only that revert dirty, restore it, and re-run to green. Record exact commands and results in the PR body.
- Search the full `src/test/` tree for every renamed function, changed option key, or changed signature and account for all hits.
- Agent workspaces are prohibited from `scripts/aiurdev --test`; if the guard is encountered, stop that path and report the manual TUI verification as requiring an Executor-root run rather than constructing a bypass.
- Before push, run `aiur guard-pr-deletions "main"`, verify remote `main` is an ancestor of the PR head, and verify the PR base is exactly `main`.

---

## Definition of Done

- R1-R7 are implemented without lowering the coordination-tool gate or blocking Claude execution.
- Tests prove exact source selection, tri-state registry truthfulness, runtime durable degradation reporting, and live CI classification; each new test is shown to fail without its production change.
- Operator docs contain no stale floating or nonexistent primary install command.
- The upstream npm publish remains explicitly tracked as the only external prerequisite; once it occurs, the live gate passes without repository changes.
- A draft PR against `main` matches its pushed diff, is adversarially self-reviewed, and moves to CI only when no in-repository code work remains.
