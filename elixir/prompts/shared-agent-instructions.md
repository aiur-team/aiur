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

Once finished, open a PR and **await user review before merging**. Do not self-merge.

### Manual CLI verification before opening a PR

Before opening the PR, run the CLI locally and manually exercise all new functionality end-to-end. If the CLI fails to run, debug and fix the issues — do not skip verification or give up. Only open the PR once the requested functionality is confirmed working in the CLI.
