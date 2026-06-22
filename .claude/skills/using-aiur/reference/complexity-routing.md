# Complexity routing

When a GitHub issue has one of `complexity:1` through `complexity:5` as a label,
use it as the portable baseline signal for model choice, agent choice, and CE
skill flow. **Treat the label as a starting hypothesis, not a mandate.** The
creator wrote it before reading the code — once you've read the issue, the linked
context, and the actual implementation surface, you usually know more. If your
read disagrees with the label, adjust freely and document the disagreement in the
PR routing note.

If the issue has no complexity label, treat it as `complexity:3` until evidence
says otherwise. Do not block just because the label is absent.

## `complexity:1` — trivial, one-shot

A rename, copy tweak, config bump, or single-file fix with an understood cause.
Under ~30 minutes; no architectural decisions.

- Suggested model: Codex.
- Suggested skills: `ce-work` only.
- Usually skip: `ce-brainstorm`, `ce-plan`, `ce-doc-review`, full `ce-code-review`.
  A self-read of the diff before pushing is enough.

## `complexity:2` — small, contained

A bounded bug fix or small feature inside one subsystem that extends existing
tests. An hour or two.

- Suggested model: Codex.
- Suggested skills: `ce-work`, then `ce-code-review` on the diff before opening
  the PR for review.
- Usually skip: `ce-brainstorm`, `ce-plan`, `ce-doc-review`.

## `complexity:3` — moderate, multi-file

Multiple files and real sequencing decisions, but contained to one subsystem.
About half a day. Default for unlabelled issues.

- Suggested model: Codex by default. Switch to Claude when the work touches
  concurrency, persistence, or any path where a wrong call is expensive to roll
  back.
- Suggested skills: `ce-plan` (short — 1–2 implementation units) → `ce-work` →
  `ce-code-review`.
- Usually skip: `ce-brainstorm` if scope is clear. `ce-doc-review` only if the
  plan touches more than one subsystem.

## `complexity:4` — cross-cutting, design decisions

Touches multiple subsystems or introduces a new abstraction with decisions others
will live with. A day or more.

- Suggested model: **the latest Claude model** (don't pin to an older version
  unless the user says so).
- Suggested skills: `ce-plan` (full: implementation units, test scenarios, risk
  section) → `ce-doc-review` on the plan → `ce-work` → `ce-code-review`.
- Optional: `ce-brainstorm` first if scope is unclear.
- Treat the plan as a review artifact — push it, link it from the issue, give the
  user a chance to redirect before implementation.

## `complexity:5` — strategic, high-stakes

New architecture, multi-system change, security/auth, data-integrity — anything
where "wrong" means an incident. Multi-day.

- Suggested model: **the latest Claude model** with `model_reasoning_effort=high`.
  Do not downgrade at this tier.
- Suggested skills: `ce-brainstorm` → requirements doc → `ce-doc-review` →
  revise → `ce-plan` → deepen → `ce-doc-review` → revise → `ce-work` →
  `ce-code-review`.
- Strongly suggested: name an adversarial reviewer persona explicitly —
  `ce-security-reviewer`, `ce-data-migration-expert`, `ce-architecture-strategist`,
  `ce-adversarial-reviewer`.
- Land in small, reviewable commits; never one mega-PR.

## Complexity routing note in PR descriptions

Every PR description must include a `### Complexity routing` block answering four
things in a few lines:

1. **Signal** — the complexity label on the issue (or `untagged → treated as
   complexity:3`).
2. **Skills used** — the skill/agent/model path you actually ran.
3. **Rationale** — why those choices fit *this* issue, not just the label.
4. **Adjustment** — whether you followed the recommended path or moved up/down,
   and why.

Example:

```markdown
### Complexity routing

- Signal: `complexity:3`
- Skills used: `ce-plan` → `ce-work` → `ce-code-review`
- Rationale: Two files, one subsystem, but the new path touches the SessionWriter
  callback chain — used Claude instead of Codex so the failure-mode analysis
  stayed sharp.
- Adjustment: Stayed on the complexity:3 recommended path; the SessionWriter touch
  was inside scope and didn't warrant escalating to 4.
```
