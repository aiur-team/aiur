---
title: "refactor: Convert orchestrator test seams"
type: refactor
status: completed
date: 2026-07-11
origin: docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md
---

# refactor: Convert orchestrator test seams

## Summary

Route non-regression orchestrator tests directly to the extracted owner modules,
then remove facade-only `*_for_test` wrappers that no longer have callers. Preserve
all assertions and excluded regression pins, and compare equivalent coverage runs
before and after the conversion.

---

## Problem Frame

FF-W2 finished extracting orchestrator behavior into synchronous owner modules but
deliberately retained facade test wrappers for this wave. Thirty-seven distinct
wrappers now mediate 205 calls in non-regression tests, obscuring the actual module
under test and keeping obsolete public seams on the facade.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are
agent inferences that fill gaps in the input and should remain visible during
implementation and review.*

- F3 applies to `Aiur.Orchestrator` facade seams, not unrelated `*_for_test`
  helpers in other modules.
- The six facade wrappers still called from the excluded regression directory must
  remain until a separately authorized regression migration makes them removable.
- Four facade test wrappers with no repository callers can be removed with the
  other obsolete seams because they pin no current assertion or external contract.

---

## Requirements

- R1. Convert every non-regression `Aiur.Orchestrator.*_for_test` call to the same
  extracted owner function the wrapper currently delegates to.
- R2. Preserve every existing test and assertion; adapt arguments where a wrapper
  currently supplies policy sets or overload behavior rather than deleting or
  weakening the invariant.
- R3. Do not edit any file under `src/test/aiur/regression/`; retain facade wrappers
  required by those excluded callers.
- R4. Remove every other obsolete orchestrator `*_for_test` wrapper, including
  wrapper specs and unused seams, without changing runtime callbacks, client APIs,
  state transitions, return shapes, or process boundaries.
- R5. Keep the repository green and demonstrate that an equivalent before/after
  coverage run does not decrease.

**Origin actors:** A3 (executor agents), A4 (Aiur-loop pipeline)

**Origin flows:** F2 (behavior-preserving ticket execution)

**Origin requirements:** R4 (zero feature loss), R5 (green behavior-preserving
tickets), R6 (higher-value coverage), R7 (explicit dependency ordering), R8
(mechanical executor scope)

---

## Scope Boundaries

- No edits under `src/test/aiur/regression/`.
- No conversion or removal of `*_for_test` helpers outside `Aiur.Orchestrator`.
- No assertion deletion, consolidation that loses a case, or coverage-ignore change.
- No runtime policy, callback, message-shape, timer, retry, cleanup, dispatch,
  pause/resume, remote-control, event, or queue behavior change.
- No split of the public GenServer client API and no new module or abstraction.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/orchestrator.ex` contains 41 distinct `*_for_test` wrapper names:
  37 have non-regression callers, six have regression callers, and four have no
  callers. The overlap means 35 wrappers can be removed while six must remain.
- `src/lib/aiur/orchestrator/` contains the public owner functions already used by
  each wrapper. Most conversions are argument-for-argument calls; reconciliation
  and dispatch revalidation require retaining the policy-set arguments supplied by
  their wrappers.
- The twelve affected non-regression test files already alias the facade or nearby
  domain modules, so destination aliases can be introduced locally without changing
  test structure or scenarios.
- `docs/plans/2026-07-11-003-refactor-orchestrator-dispatch-lifecycle-extraction-plan.md`
  explicitly reserved wrapper removal and caller conversion for issue #944.

### Institutional Learnings

- `docs/refactor/research-arch/orchestrator-facade-finish.md` defines F3 as a direct
  caller conversion, forbids silent un-pinning, and excludes regression tests.
- `docs/refactor/research-arch/giant-orchestrator.md` treats the existing tests as
  behavior-preservation pins across the orchestrator's ordering-sensitive paths;
  this wave changes ownership visibility only, not behavior.
- FF-W2 / merged PR #959 confirmed all required owner APIs at commit `486df7f` and
  intentionally preserved the facade seams for this follow-up.

### External References

- None. The change is fully specified by local APIs, tests, and refactor contracts.

---

## Key Technical Decisions

- **Follow the existing delegation target exactly:** Each test calls the function
  already named by its facade wrapper; this avoids inventing a second public path or
  changing the level at which the invariant is pinned.
- **Retain excluded compatibility only:** A wrapper stays only when an unchanged
  regression test still calls it. Non-regression callers of those six wrappers are
  still converted so the ordinary suite no longer depends on the facade seam.
- **Preserve adapter semantics at call sites:** When a wrapper selects an overload
  or supplies active/terminal policy sets, the direct test call retains those inputs
  explicitly rather than testing a narrower behavior.
- **Use equivalent coverage populations:** Capture the baseline before edits and
  compare it with the same coverage selection after conversion; report both values
  rather than relying only on the configured threshold.

---

## Open Questions

### Resolved During Planning

- **Is FF-W2 still blocking?** No. Issue #943 is closed, PR #959 is merged, and the
  current branch starts at its validated squash commit `486df7f`.
- **Can every facade seam be deleted?** No. Six names remain referenced by the
  excluded regression suite and must stay because that directory cannot be edited.
- **Are non-orchestrator test helpers included?** No. The F3 architecture section
  and predecessor plan describe orchestrator facade compatibility seams only.

### Deferred to Implementation

- **Which direct-call aliases are clearest in each large test module?** Choose the
  narrowest non-conflicting aliases while editing, then let formatting and compile
  warnings expose collisions or unused imports.

---

## Implementation Units

### U1. Convert callers and collapse facade seams

**Goal:** Make all authorized tests exercise extracted owner modules directly and
remove orchestrator test wrappers that have no remaining callers.

**Requirements:** R1, R2, R3, R4

**Dependencies:** FF-W2 / #943 (satisfied by merged PR #959)

**Files:**
- Modify: `src/lib/aiur/orchestrator.ex`
- Modify/Test: `src/test/aiur/alerts_test.exs`
- Modify/Test: `src/test/aiur/core_test.exs`
- Modify/Test: `src/test/aiur/orchestrator_ci_lifecycle_test.exs`
- Modify/Test: `src/test/aiur/orchestrator_deactivate_test.exs`
- Modify/Test: `src/test/aiur/orchestrator_events_digest_coalesce_test.exs`
- Modify/Test: `src/test/aiur/orchestrator_firehose_test.exs`
- Modify/Test: `src/test/aiur/orchestrator_max_agents_test.exs`
- Modify/Test: `src/test/aiur/orchestrator_max_duration_test.exs`
- Modify/Test: `src/test/aiur/orchestrator_remote_control_test.exs`
- Modify/Test: `src/test/aiur/orchestrator_status_test.exs`
- Modify/Test: `src/test/aiur/orchestrator_thrash_test.exs`
- Modify/Test: `src/test/aiur/workspace_and_config_test.exs`
- Test unchanged: `src/test/aiur/regression/orchestrator_dispatch_retry_test.exs`
- Test unchanged: `src/test/aiur/regression/orchestrator_lifecycle_test.exs`
- Validate unchanged: all other files under `src/test/aiur/regression/`

**Approach:**
- Replace each facade call with its current delegate target, grouped by destination
  owner so aliasing and signature adaptations remain reviewable.
- Preserve all test bodies, fixtures, assertions, iteration counts, and failure-path
  cases; change only the module/function routing and any arguments the wrapper had
  supplied.
- Remove the corresponding facade specs and definitions after all authorized callers
  move. Retain the six wrappers still required by regression callers and verify that
  every other facade test seam has disappeared.
- Remove now-unused facade aliases only when no runtime or retained test wrapper needs
  them.

**Execution note:** Capture the coverage baseline before editing. Convert call sites
before deleting wrappers so compilation identifies missed or incorrectly adapted
callers.

**Patterns to follow:**
- Direct synchronous owner calls already used by orchestrator callbacks in
  `src/lib/aiur/orchestrator.ex`
- Signature-preserving delegations introduced by PR #959

**Test scenarios:**
- Happy path: polling, dispatch, status, queue, cleanup, remote-control, alert, and
  event-topic tests return the same values through their owner modules.
- Edge case: map-based reconciliation retains its explicit active and terminal state
  sets, while `%State{}` reconciliation continues using the owner's state-aware path.
- Failure path: dispatch revalidation, firehose/CI failures, closed PR handling,
  watchdog trips, and remote-control errors keep every existing assertion and result.
- Integration: queue claims still use the real orchestrator process while calling the
  extracted queue owner API, preserving GenServer reply behavior.
- Exclusion: the complete regression directory remains byte-for-byte unchanged, and
  its two facade-seam caller files compile against the six retained wrappers.

**Verification:**
- No non-regression test references `Aiur.Orchestrator.*_for_test`.
- Exactly the regression-required facade seams remain; every obsolete wrapper spec and
  definition is absent.
- The diff contains no deleted test or assertion lines except routing-token changes.

### U2. Prove behavior and coverage parity

**Goal:** Demonstrate that the seam collapse is compile-, format-, behavior-, and
coverage-neutral before handoff.

**Requirements:** R2, R3, R5

**Dependencies:** U1

**Files:**
- Validate: all files listed in U1

**Approach:**
- Run the scoped compile, formatter, and affected-test gate with bounded test
  concurrency.
- Compare equivalent full-suite coverage summaries from before and after U1. Treat a
  lower result as a defect even when both values exceed the configured threshold.
- Inspect the final diff, assertion census, remaining wrapper census, and regression
  directory diff before review.

**Patterns to follow:**
- Scoped pre-PR gate in `AGENTS.md` and `CONTRIBUTING.md`
- Coverage configuration in `src/mix.exs`

**Test scenarios:**
- Integration: all twelve affected non-regression test files pass together against
  the destination modules with no assertion changes.
- Compatibility: the two unchanged regression caller files pass against the retained
  facade wrappers.
- Coverage: the same test population produces an equal or higher aggregate result
  after conversion.
- Static acceptance: compilation has no warnings, formatting is stable, no forbidden
  regression file changed, and the facade seam census matches U1.

**Verification:**
- The scoped gate is green and both coverage summaries are recorded in the workpad.
- Review confirms no runtime logic or public client API changed.

---

## System-Wide Impact

- **Interaction graph:** Only test call paths move from `Aiur.Orchestrator` to the
  existing synchronous owner modules; runtime callback and client paths are unchanged.
- **Error propagation:** Existing owner return values and raised failures reach the
  same assertions without a facade forwarding frame.
- **State lifecycle risks:** Direct calls must preserve wrapper-supplied policy sets,
  default arguments, and GenServer server identifiers.
- **API surface parity:** Internal facade test exports shrink; the six regression
  compatibility exports and all runtime client exports remain.
- **Integration coverage:** Orchestrator-level test fixtures remain intact, so state,
  process, persistence, tracker, and queue interactions are still exercised together.
- **Unchanged invariants:** One orchestrator process serializes runtime mutations; no
  new mailbox call, process, state transition, or ordering change is introduced.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A bulk rename targets a similarly named but behaviorally different owner function | Derive each replacement from the current wrapper body and review mappings by owner module. |
| Deleting a wrapper breaks the excluded regression suite | Compute the regression caller intersection first and retain those six definitions unchanged. |
| Wrapper-only default or policy arguments are lost | Preserve explicit adapter inputs at the test call site and run the existing edge/failure assertions. |
| A test is dropped to simplify a difficult conversion | Require assertion-preserving diffs and compare test/coverage results before and after. |
| Coverage varies because different test populations are compared | Use equivalent before/after coverage selections and record both aggregate summaries. |

---

## Documentation / Operational Notes

- No user-facing documentation, configuration, migration, rollout, or monitoring
  change is needed.
- Manual TUI verification does not exercise this test-only routing refactor, and agent
  workspaces must not launch the protected manual harness. Automated tests and
  structural/coverage comparison are the applicable verification surfaces.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md](../brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md)
- Architecture: [docs/refactor/research-arch/orchestrator-facade-finish.md](../refactor/research-arch/orchestrator-facade-finish.md)
- Invariants: [docs/refactor/research-arch/giant-orchestrator.md](../refactor/research-arch/giant-orchestrator.md)
- Predecessor plan: [docs/plans/2026-07-11-003-refactor-orchestrator-dispatch-lifecycle-extraction-plan.md](2026-07-11-003-refactor-orchestrator-dispatch-lifecycle-extraction-plan.md)
- Dependency: issue #943 and merged PR #959
- Implementation ticket: issue #944
