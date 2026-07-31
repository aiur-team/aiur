---
title: "fix: GitHub rework active-state dispatch"
type: fix
status: active
date: 2026-06-24
origin: https://github.com/aiur-team/aiur/issues/484
---

# fix: GitHub rework active-state dispatch

## Summary

Make the GitHub tracker fetch candidate issues from the configured active-state list instead of a hard-coded subset, so `agent:rework` issues dispatch when operators include `rework` in `tracker.active_states`.

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input -- un-validated bets that should be reviewed before implementation proceeds.*

- The intended behavior is parity with the Linear tracker: `fetch_candidate_issues/0` should honor all configured active states, not just the initial work states.
- Rework should not receive special dispatch handling beyond ordinary active-state eligibility.

## Requirements

- R1. GitHub candidate fetching includes every configured `tracker.active_states` entry using the configured label prefix.
- R2. Configured `rework` issues are returned as dispatch candidates just like `todo` and `in-progress`.
- R3. Existing state normalization behavior remains intact for slug and display-name inputs.

## Scope Boundaries

- Do not change orchestrator dispatch ordering, capacity handling, or deactivation behavior.
- Do not change the GitHub label namespace or seeded label list.
- Do not add special-case documentation for rework unless implementation reveals intentional differentiated behavior.

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/github/client.ex` has `fetch_issues_by_states/2`, which already normalizes configured state names into `<prefix>:<state>` label queries.
- `src/lib/aiur/linear/client.ex` reads `Config.settings!().tracker.active_states` in its candidate fetch path.
- `src/test/aiur/github_client_test.exs` already uses injected `request_fun` callbacks for no-network GitHub client regression coverage.

### Institutional Learnings

- `AGENTS.md` notes GitHub tracker states are label slugs and `active_states` should use slug form in workflow YAML.

## Key Technical Decisions

- Reuse `fetch_issues_by_states/2` from `fetch_candidate_issues/1` so candidate fetching and explicit state fetching cannot drift again.
- Keep state normalization centralized in the existing private helper rather than adding a second active-state label builder.

## Implementation Units

### U1. GitHub active-state regression coverage

**Goal:** Prove the GitHub candidate path queries configured active states, including `rework`.

**Requirements:** R1, R2, R3

**Dependencies:** None

**Files:**
- Modify: `src/test/aiur/github_client_test.exs`

**Approach:**
- Configure the test workflow with `tracker_active_states: ["todo", "in-progress", "rework", "merging"]`.
- Capture requested label query parameters and return a fixture issue only for the `sym:rework` request.

**Execution note:** Add the failing regression before changing implementation.

**Patterns to follow:**
- Existing `request_fun` assertions in `src/test/aiur/github_client_test.exs`.

**Test scenarios:**
- Happy path: configured active states include `rework`; `Client.fetch_candidate_issues/1` queries `sym:rework` and returns the rework issue with state `rework`.
- Edge case: configured active states include multiple labels; the client queries each separately and deduplicates through the existing fetch path.

**Verification:**
- Focused GitHub client test fails before U2 and passes after U2.

### U2. Config-driven GitHub candidate fetch

**Goal:** Replace the hard-coded `todo` / `in-progress` candidate label list with the configured active states.

**Requirements:** R1, R2, R3

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/github/client.ex`

**Approach:**
- Have `fetch_candidate_issues/1` delegate to `fetch_issues_by_states/2` with `Config.settings!().tracker.active_states`.
- Preserve the existing injected `request_fun` path so tests and callers keep the same API.

**Patterns to follow:**
- `src/lib/aiur/linear/client.ex` candidate fetching reads `Config.settings!().tracker.active_states`.
- `src/lib/aiur/github/client.ex` already normalizes state labels inside `fetch_issues_by_states/2`.

**Test scenarios:**
- Covered by U1 regression plus existing `fetch_issues_by_states/2` normalization tests.

**Verification:**
- GitHub candidate tests pass and requested labels include configured active states.

## System-Wide Impact

- **Interaction graph:** The orchestrator still calls `Tracker.fetch_candidate_issues/0`; only the GitHub adapter's candidate set expands to configured active states.
- **Error propagation:** Existing GitHub API error handling remains unchanged.
- **API surface parity:** GitHub candidate fetching now matches the tracker config contract already used by Linear.
- **Unchanged invariants:** State normalization, label prefixing, deduplication, and open-issue filtering remain unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Operators using display names for GitHub active states may still get normalized labels that do not match intended slug-only guidance. | Preserve existing normalization and rely on current AGENTS guidance; this issue specifically uses slug config. |
| More active states may increase GitHub issue list requests. | The configured list is small and requests were already one-per-label for explicit state fetches. |

## Documentation / Operational Notes

- No operator documentation change is needed if rework is ordinary active-state behavior after the fix.

## Sources & References

- Origin issue: https://github.com/aiur-team/aiur/issues/484
- Related code: `src/lib/aiur/github/client.ex`
- Related tests: `src/test/aiur/github_client_test.exs`
