## Agent Workpad

```text
workspace:/home/everdred/code/aiur-workspaces/aiur-team/aiur/5057@cd470534
```

### Plan

- [x] Inspect the website workflow and visual-test Docker command.
- [x] Add finite job and visual-step timeouts and assertions.
- [ ] Commit, run post-commit gates, push, open and ready PR.

### Validation

- [x] `node scripts/test-ci-events.mjs` -> passed; new website timeout assertions executed.
- [x] `python3 scripts/check-bare-assert-receive.py` -> passed.
- [ ] `mise exec -- python3 scripts/check-pr-structure.py --base <origin/main SHA>` -> run after commit (gate requires committed changes).
- [ ] `mise exec -- mix lint` -> run before PR handoff.

### Handoff

- Phase: implementation and focused validation.
- Decisions: 45-minute job timeout; 20-minute Docker visual step timeout.
- Hang cause: not reproduced; the reported workflow evidence identifies the visual Docker command but no run logs identifying the blocking subcommand. The entire Docker pull/install/build/Playwright sequence is now bounded by the step timeout.
- Completed validation: focused workflow test and bare-assert-receive check pass.
- Next steps: commit, run structural/lint/pre-PR gates, push branch `aiur/5057-guards-job-hung-6`, open PR against `main`, mark ready, and move issue to `agent:ci-wait`.

### Final Notes

- No manual CLI/TUI acceptance check applies to this workflow-only change.
