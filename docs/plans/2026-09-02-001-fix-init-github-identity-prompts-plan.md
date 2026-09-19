---
title: "fix: Ask GitHub identity mode once during init"
date: 2026-09-02
type: fix
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/aiur-team/aiur/issues/2502
---

# Ask GitHub Identity Mode Once During Init

## Goal Capsule

- **Objective:** Replace `aiur init`'s repeated GitHub identity and CODEOWNERS interactions with one explicit identity-mode choice, one bot-login input only when the operator chooses a separate account, and at most one CODEOWNERS creation confirmation.
- **Authority:** The issue acceptance criteria define the user flow; repository prompt/default and resume contracts constrain the implementation.
- **Dependency:** Issue #2501 owns single-account provenance and the explicit identity-mode configuration used by this wizard. Consume its validated branch only after its `agent.unblocked` signal.
- **Stop condition:** Do not publish a guessed identity-mode API or duplicate #2501's provenance implementation.
- **Tail ownership:** This ticket owns CODEOWNERS prompt deduplication, integration with #2501's mode API, user-facing wording, regression coverage, documentation, and delivery through a green draft PR.

## Product Contract

### Summary

GitHub setup asks which posting identity agents use once, then derives the bot account and trusted human account without asking the operator to repeat a detected login or confirm an account they just supplied.

### Problem Frame

Fresh setup currently asks to create CODEOWNERS, asks which login to add, confirms that login, and separately asks for `bot_account` after a long implementation-focused explanation. The sequence duplicates information and hides the actual own-account versus separate-account decision.

### Requirements

- R1. Fresh GitHub setup explicitly asks whether agents post as the detected operator account or a separate bot account.
- R2. Own-account mode uses the detected operator login as `bot_account` without another login prompt.
- R3. Separate-account mode asks for the bot login once while using the detected operator login for CODEOWNERS.
- R4. Supplying or detecting the operator login authorizes its CODEOWNERS insertion without a second confirmation; creating a missing CODEOWNERS file may remain one confirmation.
- R5. Prompt prose explains user-visible consequences in plain language and contains no issue numbers or credential-injection internals; App-specific syntax appears only when App authentication is actually detected.
- R6. Injected prompts remain deterministic: defaults are echoed, invalid defaults sanitize to `nil` rather than looping, and a non-GitHub tracker passes through unchanged. The mode default is own-account when only a valid operator login exists or both resolved logins match, and separate-account when distinct valid operator and bot logins exist or only a valid bot login exists; no identity fields are persisted when neither login is valid.
- R7. A non-force rerun resumes without rewriting the saved tracker or repeating fresh identity prompts.
- R8. When operator-login detection fails, setup asks for that login once before the mode choice; separate-account mode rejects a bot login equal to the resolved operator login.

### Acceptance Examples

- AE1. Given a detected login and own-account selection, fresh setup writes that login as `bot_account`, adds it to CODEOWNERS, and asks no login question.
- AE2. Given a detected operator login and separate-account selection, fresh setup asks once for a different bot login, writes that bot login, and adds only the operator login to CODEOWNERS.
- AE3. Given an existing config, rerunning init preserves its tracker identity fields and does not present the identity-mode choice.
- AE4. Given non-interactive input with an invalid detected default, setup terminates deterministically with no invalid identity persisted.
- AE5. Given no detected operator login, setup asks for it once and then presents the same mode choice using the resolved value.
- AE6. Given separate-account mode and a bot login equal to the operator login, interactive setup rejects the value while injected/non-interactive setup sanitizes an equal default to `nil` without looping.

## Planning Contract

### Key Technical Decisions

- KTD1. #2501 is the source of truth for identity-mode representation and same-login provenance. This ticket stacks on its validated ref rather than inventing a parallel mode flag.
- KTD2. CODEOWNERS setup owns file creation and insertion only. It consumes an explicitly resolved operator login that is distinct from the current bot-token-backed `deps.github_login` seam, automatically inserts a valid missing owner, and asks for a login only when the operator resolver genuinely failed.
- KTD3. Preserve the existing injected `io` and `deps` seams. Prompt-count and ordering assertions belong in integration tests, while normalization and invalid-default behavior remain unit-tested at the identity helper.
- KTD4. Until #2501 is integrated, the explicit mode, operator identity context, and CODEOWNERS changes remain blocked to avoid trusting the bot-token identity as the human operator or publishing a conflicting guessed API.
- KTD5. Resolve the operator login through a human-identity source before the mode selector; never reuse the bot-token viewer resolver for that purpose. Detection success produces no login input. Detection failure permits one manual operator-login input because the wizard does not already have that value, and that fallback must pass strict single-GitHub-login validation before it can reach CODEOWNERS.

### Sequencing

1. After #2501 explicitly unblocks with a validated ref and SHA, stack on it and inspect its real identity-mode and operator-account contract.
2. Resolve or collect one strictly validated operator login, pass it to CODEOWNERS, and remove the redundant add-account confirmation.
3. Adapt fresh setup to the dependency's mode API, tighten prompt copy, update documented init behavior, and add end-to-end prompt-count/resume coverage.

## Implementation Units

### U1. Deduplicate CODEOWNERS account insertion

- **Goal:** Make detected or newly supplied operator ownership a single decision with no follow-up confirmation.
- **Requirements:** R3, R4, R6.
- **Dependencies:** #2501's validated identity context.
- **Files:** `src/lib/aiur/init/codeowners.ex`, `src/test/aiur/init/codeowners_test.exs`, `src/test/aiur/init_test.exs`.
- **Approach:** Keep the missing-file confirmation, consume the operator login resolved before the identity-mode question, retain the manual-login fallback only when that human-identity lookup fails, strictly validate it as one GitHub login, and call the existing idempotent editor directly after a login is resolved. Do not use the bot-token-backed `deps.github_login` value as the operator identity.
- **Patterns to follow:** `Aiur.Codeowners.Edit.normalize_login/1` and `Edit.add_login/2`; existing no-op behavior when the owner is already present.
- **Test scenarios:** A separately resolved operator login is inserted with only the file-creation confirmation; when operator and bot differ only the operator is inserted; an existing file gains the operator without any confirmation; an already-present owner remains a no-op; detection failure accepts one strictly valid manual login without an add confirmation; whitespace, newline, comment-delimiter, and malformed-login inputs cannot add owners; declining file creation leaves the repository unchanged.
- **Verification:** Tests observe the exact input/confirm trace and resulting file content.

### U2. Integrate the explicit identity-mode flow

- **Goal:** Ask the posting-identity choice once and derive `bot_account` and CODEOWNERS ownership from it.
- **Requirements:** R1, R2, R3, R5-R8; covers AE1-AE6.
- **Dependencies:** #2501's validated identity-mode API; this unit establishes the identity context consumed by U1.
- **Files:** Expected integration surface includes `src/lib/aiur/init.ex`, `src/lib/aiur/init/bot_account.ex`, `src/lib/aiur/init/runtime.ex`, `src/test/aiur/init/bot_account_test.exs`, `src/test/aiur/init_test.exs`; use the actual #2501 exports after inspection.
- **Approach:** Fetch and inspect the explicitly unblocked dependency, preserve its mode field and provenance semantics, then collapse the wizard around that contract. Resolve a human operator login through a source distinct from the bot token, with one strictly validated manual fallback, before the selector. Own-account mode consumes that login; separate-account mode prompts only for a distinct bot login and rejects equality with the operator login. Default the injected selector from the resolved pair as defined by R6 so force runs preserve the available identity without inventing an invalid relationship.
- **Patterns to follow:** Existing injected prompt defaults, normalized login validation, and resume path that reconstructs saved trackers without invoking fresh setup.
- **Test scenarios:** Own-account and separate-account prompt traces; detection failure asks once before the selector; separate mode rejects an equal login interactively and sanitizes an equal injected default without looping; missing and invalid defaults; conditional App-specific help; non-GitHub pass-through; force determinism; non-force resume preserving the tracker and presenting no fresh identity prompts.
- **Verification:** Integration tests assert persisted configuration, exact identity-related prompt counts/order, plain-language output, and resume idempotence.

### U3. Correct user-facing documentation

- **Goal:** Document the explicit mode choice and its deterministic defaults without stale dedicated-account guidance.
- **Requirements:** R5-R7.
- **Dependencies:** U2.
- **Files:** `website/docs-app/reference/configuration.md` and any existing `aiur init` guide/reference sentence made inaccurate by the final flow.
- **Approach:** Describe what each mode does and when a bot login is requested; keep credential mechanics on the GitHub API page rather than repeating them in setup guidance.
- **Test expectation:** none -- prose mirrors the tested CLI behavior and existing documentation checks cover referenced config keys.
- **Verification:** Search all docs for the removed prompt wording, issue-number prose, and claims that the wizard always defaults `bot_account` directly from the token login.

## Verification Contract

- Compile with warnings as errors and format the touched Elixir files.
- Use `mix aiur.affected_tests` to compute the scoped suite, then run every emitted test invocation with `--max-cases 4`.
- Mutation-check each new behavioral test in an isolated, uniquely named worktree: removing its production hunk must make the test fail, and restoring it must make the test pass.
- Audit the full test tree for every renamed prompt label, function, or option key before push.
- Manual CLI verification is required from the Executor repo root because this agent workspace is prohibited from running `scripts/aiurdev --test`.

## Definition of Done

- The normal detected-login flow presents one identity-mode question, at most one bot-login input, and at most one CODEOWNERS creation confirmation.
- No login already known to the wizard is requested again, and no `Add @login to CODEOWNERS?` confirmation remains.
- Non-interactive/force defaults and invalid-default termination are covered and preserved.
- A non-force rerun preserves the existing tracker and skips fresh identity prompts.
- Required docs match the final flow, scoped validation passes, mutation checks prove the new tests, and the draft PR is self-reviewed against current `main`.


## Executor continuity clarification — 2026-09-16

Recovered from the original September 2 Codex planning transcript and its three review amendments; no implementation was found in the interrupted workspace. Dependency #2501 is merged at 83b8826a. Its actual implementation supplies provenance and identity_mode, but does not supply a separate human-operator resolver API. Consume the existing representation; introduce an explicit independent human-identity seam or use the already-approved strictly validated manual fallback. Never infer the human operator from the bot-token-backed deps.github_login result. This clarifies the integration seam without changing requirements.

Integrate the accepted init-scope work (#2637) before implementation because both touch fresh setup in Init. Preserve the dotenv and label-preflight contracts from #2638 and #2639 when their merges arrive. Executor verification remains outstanding; do not claim a manual CLI/TUI check from unit tests or logs.
