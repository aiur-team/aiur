Closes #5382

#### Context

Teardown must remain reliable when its optional ActiveTurns ETS owner is unavailable.

#### TL;DR

Make agent teardown tolerate a missing ActiveTurns table and guard its shared owner.

#### Summary

- Treat a missing ActiveTurns table as no active turns during teardown.
- Detect and restore an ActiveTurns owner left down by a test.
- Cover teardown, shared-child recovery, and guard attribution.

#### Alternatives

- Requiring the table during teardown would let optional registry loss crash issue cleanup.

#### Complexity routing

- Signal: complexity:1
- Skills used: aiur-agent
- Rationale: The ticket is a focused teardown resilience fix with a bounded test-isolation guard.
- Adjustment: No adjustment needed.

#### Docs

- [x] Docs not required — bug fix with no user-facing interface change.

## Local tests

Policy: partial
Tested head: fce33ac86369a713d06494df0d81a1151234c8c8
Base: main @ 3c97c70b7e382960735b07ef5d8b049ab3d55dc6
Selection: Ran the teardown regression, runtime-child recovery and guard tests, plus ActiveTurns tests; affected-test selection recommended full make ci because shared test support changed. Full suite deferred to CI.
- `mise exec -- mix test --max-cases 4 test/aiur/orchestrator/duration_cap_release_test.exs test/aiur/test_support_test.exs test/aiur/test_support/orchestrator_guard_test.exs test/aiur/opencode/active_turns_test.exs` -> 46 tests, 0 failures
- `mise exec -- mix compile --warnings-as-errors` -> passed
- `mise exec -- mix format --check-formatted` -> passed
- `mise exec -- mix lint` -> passed; 69 strict Credo checks, 4,349 files
- `python3 scripts/check-bare-assert-receive.py` -> passed (2,122 test files)
- `mise exec -- python3 scripts/check-pr-structure.py --base 3c97c70b7e382960735b07ef5d8b049ab3d55dc6` -> passed

The partition-3 CI log records seed 343554 and six failures. Its last-finished attribution names a DurationCapReleaseTest case after the supervisor and PubSub were already missing; it does not establish which earlier test first stopped ActiveTurns. The guard now attributes and restores an ActiveTurns leak at the next synchronous test boundary. `aiurdev pre-pr` could not run because `$TMUX` is set; global `aiur pre-pr` was outdated and attempted a blocked OpenCode install. The specific original culprit remains unconfirmed.
