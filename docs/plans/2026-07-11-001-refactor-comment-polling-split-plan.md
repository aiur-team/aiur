---
title: "refactor: Split comment polling responsibilities"
type: refactor
status: completed
date: 2026-07-11
origin: docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md
---

# refactor: Split comment polling responsibilities

## Summary

Keep `Aiur.Orchestrator.CommentPolling` as the stable poll-driver surface while moving target discovery, ordering, capping, PR freshness, and target bookkeeping into a nested `TargetSelection` module. The change follows the round-one W10/W11 seam and preserves every polling result and state transition.

## Problem Frame

The origin document defined the planning spike and its later executor-ticket flow; issue #947 is one of those downstream implementation tickets. This plan carries forward the origin's R4-R10 refactor contract, while the spike-only deliverables and process requirements (R1-R3 and R11-R13) no longer apply.

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds.*

- The existing `CommentPolling` module remains the driver-facing facade so `Aiur.Orchestrator` and its test seams require no caller changes.
- `Aiur.Orchestrator.CommentPolling.TargetSelection` is the single new module; introducing an additional driver facade would add churn without strengthening the requested concern boundary.
- Existing end-to-end polling tests remain authoritative, with focused direct coverage added for the extracted selection boundary rather than reorganizing unrelated tests.

## Requirements

- R4. Preserve the complete comment-polling feature set with zero feature loss.
- R5. Keep the change behavior-preserving and leave the repository green after the ticket.
- R8. Make the extraction mechanical from the documented file boundary and approach.
- R10. Use the target-selection/poll-driver concern seam to reduce the oversized sibling while applying the file-size norm with judgment.

**Ticket constraints:**

- C1. Split target selection from poll execution along the W10/W11 boundary named in `docs/refactor/research-arch/orchestrator-facade-finish.md`.
- C2. Preserve `CommentPolling.poll_github_firehose/2` and `CommentPolling.poll_github_comments/2`, including their default options and return values.
- C3. Preserve target composition and order for running, human-review, merging, and watched-PR targets, including deduplication, caps, pause filtering, oldest-cursor priority, PR freshness, and unchanged-target suppression.
- C4. Preserve cursor merging, successful-target bookkeeping, partial-failure behavior, connectivity success/failure classification, firehose watermarks, and tracker-kind gating.
- C5. Keep all work as plain function calls inside the orchestrator GenServer process. Add no process, timer, message, `GenServer.call`, or state-shape change; the full `giant-orchestrator.md` section 4 invariant set remains unchanged.

## Scope Boundaries

- No changes to `Aiur.Orchestrator`, `CommentWake`, retry logic, teardown ordering, timer tokens, pause/resume clocks, tracker APIs, or GitHub poller behavior.
- No selection-policy redesign, new target type, new configuration, test-seam cleanup, or broad test-file split.
- No public API expansion beyond the minimum functions the driver needs from the extracted internal module.

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/orchestrator/comment_polling.ex` currently combines a compact poll driver with the larger target-selection/cursor helper cluster.
- `src/lib/aiur/opencode/slot.ex` and `src/lib/aiur/opencode/slot/` establish the local pattern of retaining a stable facade while extracting nested concern modules.
- Commit `60d1b68` originally moved both W10/W11 concerns together; its one-line orchestrator delegations and test seams must remain stable.
- `src/test/aiur/orchestrator/comment_polling_test.exs`, `src/test/aiur/orchestrator_firehose_test.exs`, and the direct-comment-poll cases in `src/test/aiur/orchestrator_deactivate_test.exs` pin the target, cursor, freshness, error, and connectivity behaviors.

### Institutional Learnings

- No matching `docs/solutions/` material exists. The explicit invariants in `docs/refactor/research-arch/giant-orchestrator.md` section 4 are the governing local guidance.

### External References

- None. This is a repository-local pure move with strong local precedent and no dependency or external-contract change.

## Key Technical Decisions

- Retain `CommentPolling` as the poll driver: this preserves its two callers and avoids a redundant facade layer.
- Move target assembly as one cohesive cluster: selection helpers share caps, review-state constants, fetcher injection, PR metadata, cursor priority, and bookkeeping semantics.
- Keep the driver responsible for invoking pollers and interpreting poll results: logging, connectivity health, cursor/state updates, and partial-failure classification remain together at the side-effect boundary.
- Keep driver-to-selection dependency one-way: `CommentPolling` calls `TargetSelection`; the extracted module never calls back into the driver or orchestrator.

## Implementation Units

### U1. Extract target selection

**Goal:** Move target discovery and selection bookkeeping into a cohesive nested module without changing selection output.

**Requirements:** R4, R5, R8, R10, C1, C3, C5

**Dependencies:** None

**Files:**
- Create: `src/lib/aiur/orchestrator/comment_polling/target_selection.ex`
- Create: `src/test/aiur/orchestrator/comment_polling/target_selection_test.exs`
- Modify: `src/lib/aiur/orchestrator/comment_polling.ex`

**Approach:**
- Move the running, human-review/merging, and watched-PR target cluster verbatim, including injected fetchers, normalization, deduplication, limits, sorting, freshness keys, open-PR option mapping, cursor merging, and successful-poll bookkeeping.
- Expose only the small set of functions used across the driver boundary; keep all subordinate helpers private.
- Preserve constants, clause order, logging, and data shapes with the moved consumers.

**Execution note:** Add direct characterization at the new boundary before relying on integration coverage.

**Patterns to follow:**
- `src/lib/aiur/opencode/slot.ex`
- `src/lib/aiur/opencode/slot/state.ex`
- `src/lib/aiur/orchestrator/comment_polling.ex`

**Test scenarios:**
- Happy path: running, human-review, and watched targets are combined in the existing order and deduplicated without changing their metadata.
- Edge case: paused review issues, invalid identifiers, duplicate watched PRs, closed PRs, invalid limits, and unchanged freshness markers retain their existing filtering/fallback behavior.
- Failure path: review-target or watched-PR fetch failures return the same error tuple and prevent a partial target set from being polled.
- Integration: open-PR metadata selected for review/watch targets reaches the comments poller options unchanged.

**Verification:**
- Selection results and state-bookkeeping outputs match the pre-extraction behavior for equivalent inputs.
- The extracted module has no process boundary, timer, or callback into `CommentPolling`/`Orchestrator`.

### U2. Rewire the poll driver and preserve integration behavior

**Goal:** Make the stable `CommentPolling` surface delegate target work to `TargetSelection` while retaining poll-side semantics.

**Requirements:** R4, R5, R8, C2, C4, C5

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/orchestrator/comment_polling.ex`
- Modify: `src/test/aiur/orchestrator/comment_polling_test.exs`
- Test: `src/test/aiur/orchestrator_firehose_test.exs`
- Test: `src/test/aiur/orchestrator_deactivate_test.exs`

**Approach:**
- Replace only the moved helper calls with `TargetSelection` calls; retain poller invocation, logging, tracker-kind gating, connectivity classification, and state update order in `CommentPolling`.
- Keep both existing public function heads/specs and all orchestrator-facing seams unchanged.
- Add a boundary-focused assertion only where existing integration coverage does not directly pin the delegation result.

**Patterns to follow:**
- `src/lib/aiur/orchestrator.ex` one-line module delegations.
- Existing firehose and direct-comment polling characterization tests.

**Test scenarios:**
- Happy path: a successful comment poll merges per-target cursors and remembers only successfully polled review targets.
- Edge case: an empty target set returns the original state without invoking the comments poller.
- Failure path: target refresh failure preserves state; partial target failure advances successful cursors but does not remember failed review targets; all-target failure retains connectivity classification.
- Integration: firehose ETag/watermark and comments Retry-After behavior remain unchanged through the existing orchestrator test seams.

**Verification:**
- The driver surface, function defaults, return state, log conditions, and state-update ordering are unchanged.
- Focused compile, format, affected tests, scoped Credo, and CI pass.

## System-Wide Impact

- **Interaction graph:** `Aiur.Orchestrator` continues calling `CommentPolling`; `CommentPolling` calls poller/health modules plus the new `TargetSelection`; no caller elsewhere changes.
- **Error propagation:** Existing target-refresh error tuples and poller partial-failure lists retain their current handling and logging.
- **State lifecycle risks:** Cursor and review-target freshness maps must be updated in the same order and only for successful targets.
- **API surface parity:** Both orchestrator test seams and both `CommentPolling` public entry points remain stable.
- **Integration coverage:** Existing direct-comment-poll and firehose suites prove the GitHub poller boundary; focused tests prove the extracted selection boundary.
- **Unchanged invariants:** No timers, teardown, retry budgets, pause clocks, monitor lifecycle, or process ownership are touched.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Moving a helper to the wrong side subtly changes cursor/freshness ownership. | Follow the documented W10 target-selection/cursor-helper cluster and compare moved bodies verbatim. |
| Module extraction accidentally changes private clause ordering or defaults. | Preserve function bodies and clauses exactly, then review a word-diff and run the existing integration suites. |
| The new boundary introduces a callback cycle or changes `self()`. | Keep `TargetSelection` pure with respect to the orchestrator and use only direct same-process calls. |

## Sources & References

- **Origin document:** [docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md](../brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md)
- [docs/refactor/research-arch/orchestrator-facade-finish.md](../refactor/research-arch/orchestrator-facade-finish.md)
- [docs/refactor/research-arch/giant-orchestrator.md](../refactor/research-arch/giant-orchestrator.md)
- `src/lib/aiur/orchestrator/comment_polling.ex`
- `src/test/aiur/orchestrator/comment_polling_test.exs`
- Issue #947
