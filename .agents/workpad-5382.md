## Agent Workpad

```text
aiur-team:5382@fce33ac86
```

### Plan

- [x] Make teardown tolerate a missing ActiveTurns table.
- [x] Add shared runtime-child detection, recovery, and regression coverage.
- [ ] Open, self-review, and mark the PR ready.

### Validation

- [x] Focused tests: 46 passed across duration cap release, test support, guard, and ActiveTurns.
- [x] Compile with warnings as errors, format check, strict lint, bare-receive check, and structure gate.
- [ ] Mutation checks and full CI remain outstanding.

### Handoff

- Phase: implementation complete; preparing PR
- Decisions: The partition-3 CI log provides seed 343554 and proves the failure pattern, but does not identify the earlier test that first stopped ActiveTurns. The new guard reports and restores the missing owner at the next sync test boundary.
- Completed validation: focused 46 tests pass; lint and compile pass; structural gate passes.
- Next steps: complete mutation checks, push, open draft PR against main, refresh tested-head evidence, self-review, then mark ready and move to ci-wait.

### Final Notes

- `aiurdev pre-pr` was blocked because `$TMUX` is set; global `aiur pre-pr` was outdated and attempted an OpenCode install to a read-only global npm path.
- Affected-test selector recommended full `make ci` due to shared test support; this was not run locally.
