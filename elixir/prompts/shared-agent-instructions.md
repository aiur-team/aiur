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

### Closing keyword in PR description

Every PR description must start with `Closes #N` (or `Fixes` / `Resolves`) for the originating issue so GitHub auto-closes it on merge. Multiple issues: `Closes #43, #46`.

### Out-of-scope findings

While working on an issue, if you find a separate, real problem that is **not** required to ship the current task, do not silently fix it inside the same PR. Instead:

1. Open a new GitHub issue describing the finding (clear title, evidence, suggested fix if obvious).
2. Label the new issue `needs-triage` so the user triages it before any agent picks it up.
3. Reference the issue you're currently working on inside the new issue (e.g., "surfaced while working on #N").
4. Add a comment on your current issue with a link to the new issue (e.g., "out-of-scope finding filed as #M").

Keep the current PR focused on the originally-scoped change.

### Complexity routing

When a GitHub issue has one of `complexity:1` through `complexity:5` as a label, use it as the portable baseline signal for model choice, agent choice, and Compound Engineering skill flow. **Treat the label as a starting hypothesis, and the skills below as suggestions, not mandates.** The issue creator wrote the label before reading the code — once you've read the issue, the linked context, and the actual implementation surface, you almost always have more information than they did. If your read of the work disagrees with the label, adjust freely: drop steps that are overhead for what you're actually shipping, add steps the label undersold. Document the disagreement in the PR routing note so the next reader sees why.

If the issue has no complexity label, treat it as `complexity:3` until evidence says otherwise. Existing workflows without complexity labels should continue normally; do not block or fail just because the label is absent.

GitHub Projects numeric fields such as `points` or `complexity` may become a secondary signal in some repositories, but label-based complexity is the default because labels work on ordinary GitHub issues without Projects setup.

#### `complexity:1` — trivial, one-shot

A rename, a copy tweak, a config bump, a single-file bug fix with an already-understood cause. Roughly under 30 minutes; no architectural decisions.

- Suggested model: Codex.
- Suggested skills: `ce-work` only.
- Usually skip: `ce-brainstorm`, `ce-plan`, `ce-doc-review`, full `ce-code-review`. A self-read of the diff before pushing is enough.

#### `complexity:2` — small, contained

A bounded bug fix or a small feature addition that lives inside one subsystem and extends existing tests. Roughly an hour or two.

- Suggested model: Codex.
- Suggested skills: `ce-work`, then `ce-code-review` on the diff before opening the PR for review.
- Usually skip: `ce-brainstorm`, `ce-plan`, `ce-doc-review`. Mental sequencing is enough — no plan document.

#### `complexity:3` — moderate, multi-file

Multiple files, real sequencing decisions, but contained to one subsystem. Roughly half a day. Default for unlabelled issues.

- Suggested model: Codex by default. Switch to Claude when the work touches concurrency, persistence, or any path where a wrong call is expensive to roll back.
- Suggested skills: `ce-plan` (short — 1-2 implementation units) → `ce-work` → `ce-code-review`.
- Usually skip: `ce-brainstorm` if scope is already clear from the issue. `ce-doc-review` optional — run it only if the plan touches more than one subsystem.

#### `complexity:4` — cross-cutting, design decisions

Touches multiple subsystems or introduces a new abstraction. Has design decisions other agents and contributors will live with. A day or more.

- Suggested model: **the latest Claude model** (don't pin to an older version unless the user explicitly says so).
- Suggested skills: `ce-plan` (full plan: implementation units, test scenarios, risk section) → `ce-doc-review` on the plan → `ce-work` → `ce-code-review`.
- Optional: `ce-brainstorm` first if the issue is exploratory or scope is unclear.
- Treat the plan as a review artifact — push the plan, link it from the issue, give the user a chance to redirect before implementation starts.

#### `complexity:5` — strategic, high-stakes

New architecture, multi-system change, security/auth, data-integrity, anything where "wrong" means an incident. Multi-day work.

- Suggested model: **the latest Claude model** with `model_reasoning_effort=high`. Don't downgrade to a smaller or older model at this tier — the depth of reasoning matters more than the speed.
- Suggested skills: `ce-brainstorm` → requirements doc → `ce-plan` → deepen the plan → `ce-doc-review` → revise → `ce-work` → `ce-code-review`.
- Strongly suggested: request adversarial review on the diff by naming the relevant persona explicitly — `ce-security-reviewer`, `ce-data-migration-expert`, `ce-architecture-strategist`, `ce-adversarial-reviewer`. Default checks alone are usually not enough at this tier.
- Land in small, reviewable commits; never one mega-PR.

### Complexity routing note in PR descriptions

Every PR description must include a `### Complexity routing` block that answers four things in a few lines:

1. **Signal** — the complexity label on the issue (or `untagged → treated as complexity:3`).
2. **Skills used** — the skill/agent/model path you actually ran.
3. **Rationale** — why those choices fit *this* issue, not just the label.
4. **Adjustment** — whether you followed the recommended path or moved up/down, and why.

Example:

```markdown
### Complexity routing

- Signal: `complexity:3`
- Skills used: `ce-plan` → `ce-work` → `ce-code-review`
- Rationale: Two files, one subsystem, but the new code path touches the
  SessionWriter callback chain — used Claude instead of Codex so the
  failure-mode analysis stayed sharp.
- Adjustment: Stayed on the complexity:3 recommended path; the SessionWriter
  touch was inside scope and didn't warrant escalating to 4.
```
