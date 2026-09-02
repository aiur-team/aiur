---
title: Init Resume, Installer, and CI Guidance - Plan
type: fix
date: 2026-09-02
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Init Resume, Installer, and CI Guidance - Plan

## Goal Capsule

- **Objective:** Make `aiur init` preserve declined optional setup choices, never replace a satisfying Claude adapter with an older release, and stop CI setup at the first actionable prerequisite failure.
- **Authority:** Issue #2504 and its CODEOWNER comments define behavior; repository conventions and existing config/runtime contracts constrain implementation.
- **Stop conditions:** Do not broaden this work into publishing `aiur-claude` or rewriting all init prompts; #2503 owns publication and remediation-link defects.
- **Tail ownership:** Add mutation-proven regressions, update user-facing docs for changed config and CLI behavior, and deliver a draft PR against `main` through CI.

---

## Product Contract

### Summary

`aiur init` will remember both accepted and declined optional configuration, preserve an installed Claude adapter that already meets Aiur's minimum, and guide operators through CI prerequisites in dependency order.

### Problem Frame

Resume currently treats a missing configuration section as “never asked.” A declined backfill writes nothing, so later runs ask the same question while claiming saved selections were restored.

Claude adapter setup decides whether to install from command availability and validates the version only after mutation. That ordering can replace a working newer source install with npm's older `latest` release.

CI setup turns a branch-endpoint 404 into a definite missing-branch claim even when the configured token cannot see a SAML-protected repository. It then treats an empty workflow list as permission to offer scaffolding, causing operators to fix downstream rulesets while repository access remains unresolved.

### Requirements

#### Resume choices

- R1. Fresh setup and resume backfill must persist an explicit disabled state when the operator declines a registered optional section. Existing ElevenLabs configurations without `enabled` remain enabled for backward compatibility; only explicit `enabled: false` suppresses configured credentials and the `ELEVENLABS_API_KEY` fallback.
- R2. A later resume must report that decline in saved selections and skip the corresponding prompt.
- R3. Existing `aiur init --force` behavior remains the explicit full reconfiguration path.

#### Claude adapter installation

- R4. Setup must inspect the installed `aiur-claude` version before any install attempt and leave a satisfying version untouched.
- R5. A missing or outdated adapter must be installed only from a source expected to meet the minimum, using an immutable reviewed GitHub release ref when npm's published version is insufficient.
- R6. Setup must verify the resulting adapter version and stop provisioning when installation leaves it below the required minimum.

#### CI readiness

- R7. Init must explain that pull-request workflows run checks while required status checks prevent failed work from merging.
- R8. Repository visibility must be established before a branch-only 404 is classified as a missing configured base branch.
- R9. A true missing branch must name the attempted repository, value, `tracker.base_branch`, and a command that reports the repository default.
- R10. A repository access failure must name the active credential source, token authorization, and SAML SSO as a likely remedy instead of claiming the branch is absent; readiness-only permissions must not be attributed to `GITHUB_TOKEN`.
- R11. Missing repository access or a missing base branch must short-circuit without workflow prompts or writes.
- R12. Successful workflow creation must explain the second required-check step, identify Settings → Rules → Rulesets, name `ci / required`, name the configured branch, and tell the operator to rerun init.

### Acceptance Examples

- AE1. Given a declined ElevenLabs prompt, the written config records voice as disabled; the next init summary says it was declined and does not prompt again.
- AE2. Given a legacy config missing prewarm, declining its backfill appends `prewarm.enabled: false`; the next resume skips it.
- AE3. Given installed `aiur-claude` 1.2.0 and an auth probe that would otherwise trigger setup, init performs no install and retains 1.2.0.
- AE4. Given npm `latest` below the minimum, setup selects the GitHub source and rejects a post-install version below the minimum.
- AE5. Given a repository-level read that fails with an access-classified 403 or 404, init reports an access problem and performs neither a branch probe nor a scaffold prompt.
- AE6. Given a visible repository whose configured branch alone returns 404, init reports the exact missing base branch and performs no scaffold prompt.
- AE7. Given a valid base with no pull-request workflow, accepting creation writes the scaffold and prints why and where `ci / required` must be made required.

### Scope Boundaries

- `aiur-claude` npm publication and the standalone upgrade hint remain owned by #2503.
- Artifact-remediation prompts such as CODEOWNERS are not saved configuration choices and are unchanged.
- This work does not create or mutate GitHub rulesets automatically.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Represent optional-section declines with valid disabled configuration, not wizard-private metadata. This keeps resume state visible, portable, and compatible with normal config loading.
- KTD2. Add an ElevenLabs enabled gate because an empty section is not a decline: the current environment fallback can still activate voice when `ELEVENLABS_API_KEY` is present.
- KTD3. Make the registered backfill contract append both accepted and declined renderings, then run side effects only for accepted choices.
- KTD4. Make adapter installation monotonic by separating tagged installed-version classification, immutable install-source selection, and post-install verification.
- KTD5. Probe repository visibility before branch existence. A repository-level 404 is ambiguous access evidence; only a visible repository plus branch-only 404 proves the configured branch is missing.
- KTD6. Keep operator guidance in `Aiur.Init.GitHub`; the lower-level readiness result remains structured and reusable by other consumers.

### Assumptions

- The GitHub repository source for `aiur-claude` contains a version meeting `1.1.0` while npm `latest` may remain behind; #2503 will eventually remove that fallback need.
- `aiur init --force` is sufficient as the explicit reconfiguration mechanism, so no new CLI flag is required.
- A configured `enabled: false` must suppress ElevenLabs environment fallback; an explicit operator decline outranks ambient credentials.

### Sequencing

1. Establish persisted decline semantics and runtime gating.
2. Refactor adapter preflight and source-safe installation.
3. Correct CI evidence ordering and operator guidance.
4. Update docs and run mutation-proven validation.

---

## Implementation Units

### U1. Persist optional-section declines

- **Goal:** Give every registered optional section a durable accepted-or-declined result.
- **Requirements:** R1, R2, R3; AE1, AE2; KTD1, KTD2, KTD3.
- **Dependencies:** None.
- **Files:** `src/lib/aiur/init/resume.ex`, `src/lib/aiur/init/eleven_labs.ex`, `src/lib/aiur/init/prewarm.ex`, `src/lib/aiur/init/templates.ex`, `src/lib/aiur/config/schema.ex`, `src/lib/aiur/config/schema/eleven_labs.ex`, `src/test/aiur/init/resume_test.exs`, `src/test/aiur/init/templates_test.exs`, `src/test/aiur/config/schema_test.exs`, `src/test/aiur/init_test.exs`.
- **Approach:** Add `elevenlabs.enabled` with a backward-compatible true default, gate credential resolution only when it is explicitly false, render disabled YAML for a decline, make prewarm rendering reflect the supplied enabled state, append either backfill result, and reserve first-run effects for enabled answers. Include prewarm and voice choice states in saved summaries.
- **Test scenarios:** Fresh and resumed ElevenLabs declines persist disabled state; an exported ElevenLabs key cannot override explicit disablement; legacy prewarm decline appends disabled state; accepted paths preserve their existing values and side effects; a second resume makes no corresponding prompt.
- **Verification:** Config parsing, template rendering, resume unit tests, and an init-level repeated-run test demonstrate the tri-state behavior.

### U2. Make Claude adapter installation version-safe

- **Goal:** Never worsen a working adapter and never accept an installed result below Aiur's minimum.
- **Requirements:** R4, R5, R6; AE3, AE4; KTD4.
- **Dependencies:** None.
- **Files:** `src/lib/aiur/init/agent_cli.ex`, `src/lib/aiur/init/runtime.ex`, `src/lib/aiur/init.ex`, `src/test/aiur/init/agent_cli_test.exs`, `src/test/aiur/init_test.exs`.
- **Approach:** Classify the installed adapter as `:missing`, `{:satisfying, version}`, `{:outdated, version}`, or `{:unknown, reason}` before checking installation need; skip mutation for satisfying and safety-unknown existing installs; select an exact npm version that meets the minimum or the reviewed immutable `github:aiur-team/aiur-claude#v1.1.0` fallback; pass that package spec into the installer; verify after installation; and propagate install or insufficient-version failures through `check_agent_clis/3` and `Init.provision` instead of returning warning-only success.
- **Test scenarios:** Minimum and newer versions skip install; outdated or missing versions select a satisfying exact source; npm below minimum selects the pinned GitHub release; registry lookup or install failures leave an existing unknown install untouched where safety cannot be proved; a post-install old version stops provisioning.
- **Verification:** Pure version/source decision tests and init integration tests prove the install mock cannot run for a satisfying version and an insufficient result cannot reach the final setup screen.

### U3. Sequence CI prerequisites and explain the handoff

- **Goal:** Direct the operator to the first fix that can make repository merge gating succeed.
- **Requirements:** R7, R8, R9, R10, R11, R12; AE5, AE6, AE7; KTD5, KTD6.
- **Dependencies:** None.
- **Files:** `src/lib/aiur/github/ci_readiness.ex`, `src/lib/aiur/init/github.ex`, `src/test/aiur/github/ci_readiness_test.exs`, `src/test/aiur/init/github_test.exs`.
- **Approach:** Resolve repository visibility before branch existence, retain structured access failures and the active credential source, special-case missing/access blockers before generic incomplete readiness, preserve the existing least-privilege distinction between `GITHUB_TOKEN` and `AIUR_CI_READINESS_TOKEN`, and thread repository/base context into scaffold success guidance.
- **Test scenarios:** Repository 403/404 is an access error; visible repository plus branch 404 is `base_branch_missing`; missing/access states never branch-probe, confirm, or write; credential-source-specific guidance never directs readiness-only permissions to `GITHUB_TOKEN`; non-branch readiness prints one purpose statement without duplicate labels; scaffold success names why, destination, check name, branch, and rerun action.
- **Verification:** Lower-level request-order tests and init presenter tests constrain both classification and the exact actionable content.

### U4. Align user documentation

- **Goal:** Keep documented init and configuration behavior accurate.
- **Requirements:** R1, R2, R3, R4, R5, R6, R7, R12.
- **Dependencies:** U1, U2, U3.
- **Files:** `website/docs-app/reference/configuration.md`, `website/docs-app/reference/cli.md`, `.aiur/examples/config.example`.
- **Approach:** Document `elevenlabs.enabled`, persisted declines, `--force` reconfiguration, version-safe adapter setup, and the two-step CI workflow-plus-required-check setup.
- **Test scenarios:** Configuration-key documentation checker recognizes the new key; examples remain valid YAML under accepted and declined rendering.
- **Verification:** Documentation assertions and config-doc lint remain green.

---

## Verification Contract

| Gate | Scope | Done signal |
|---|---|---|
| Compile | Elixir production changes | `mix compile --warnings-as-errors` exits successfully. |
| Format | Changed Elixir files | `mix format` produces no remaining diff. |
| Affected tests | Modules and direct integration paths selected by `mix aiur.affected_tests` | Every printed invocation passes with `--max-cases 4`. |
| Config docs | New `elevenlabs.enabled` key | Configuration reference checker passes. |
| Mutation proof | New regression tests | Each named regression fails in an isolated worktree when its guarding production hunk is reverted and passes when restored. |
| CI | Repository-wide authoritative gate | Draft PR checks pass against a head containing current `origin/main`. |

---

## Definition of Done

- Declining each registered optional section leaves a durable disabled selection that resume reports and does not re-ask.
- A satisfying `aiur-claude` install is never mutated; an insufficient installation result cannot complete provisioning.
- Repository access failures and true missing branches produce distinct actionable guidance and block downstream CI prompts.
- Workflow scaffold guidance explains both the running-check and required-check steps with a concrete GitHub settings destination.
- Required docs and examples match behavior.
- Scoped tests, mutation checks, draft-PR self-review, and CI are complete; abandoned implementation attempts are absent from the diff.
