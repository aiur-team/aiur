## Shared Agent Instructions

- Aiur supports custom alert emission through an `emit_alert` function.
- When using `emit_alert`, always send exactly:
  - `name`
  - `message`
- Never emit Aiur-owned system alerts from the agent. The system owns:
  - `task.*`
  - `agent.*`
  - `chat.*`
- Use judgment based on feature size.
  - Large feature asks should usually follow the full loop: `ce-brainstorm` -> `ce-plan` -> `ce-work` -> `ce-review`.
  - Smaller asks may skip brainstorm, plan, or review when the extra step would be overhead, but err on the side of using these skills when in doubt.
- Use custom workflow alerts for milestone announcements. In this repository, prefer:
  - `phase.brainstorm.start`
  - `phase.brainstorm.end`
  - `phase.plan.start`
  - `phase.plan.end`
  - `phase.work.start`
  - `phase.work.end`
  - `phase.review.start`
  - `phase.review.end`
- Emit milestone alerts when you actually enter or leave the corresponding phase, not retroactively.

### Dev loop

Branch off the latest `main` and run this loop:

1. Implement
2. Add / update / run tests
3. Build
4. Lint (with autofix)
5. Commit using short, 3–7 word messages
6. Push
7. **Open the PR as a draft** (not ready for review yet)
8. **Self-review the draft PR with `ce-code-review`** against the diff you just pushed
9. Implement any issues `ce-code-review` surfaces (commit + push the fixes)
10. If you still believe the work is complete and correct, **mark the PR ready for review** and add the `agent:human-review` label

Do **not** self-merge. Always await user review after marking the PR ready.

### Manual CLI verification before opening a PR

Before opening the draft PR, run the CLI locally and manually exercise all new functionality end-to-end. If the CLI fails to run, debug and fix the issues — do not skip verification or give up. Only open the draft PR once the requested functionality is confirmed working in the CLI.

### Out-of-scope findings

While working on an issue, if you find a separate, real problem that is **not** required to ship the current task, do not silently fix it inside the same PR. Instead:

1. Open a new GitHub issue describing the finding (clear title, evidence, suggested fix if obvious).
2. Label the new issue `agent:human-review` so the user triages it before any agent picks it up.
3. Reference the issue you're currently working on inside the new issue (e.g., "surfaced while working on #N").
4. Add a comment on your current issue with a link to the new issue (e.g., "out-of-scope finding filed as #M").

Keep the current PR focused on the originally-scoped change.
