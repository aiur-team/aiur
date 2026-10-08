---
ticket_id: MP-E2-C8-T02
feature_id: MP-E2
chunk_id: MP-E2-C8
bucket: 2-platform
title: aiur-run skill — Executor triage with deadlines, ack and asking the human
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C2-T04, MP-E2-C6-T02, MP-E2-C7-T04]
prior_units: [U6]
prior_boundaries: [DOCS (skills)]
prior_features: [#3005 (operator-relay-answer) if merged]
prior_findings: [plan §1.6 (skill lines), AGENTS.md skills table → website/docs-app/skills.md]
size_owner: "DOCS (.claude/skills/aiur-run/SKILL.md 1,293 — already over 500: put new text in references/executor.md and link; net SKILL.md growth ≤ 5 lines)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C8-T02 — aiur-run skill: Executor triage with deadlines, ack and asking the human

## Identity and outcome

- Bucket 2, MP-E2, chunk C8.
- **User value:** the Executor agent knows a routed Command has a clock, acknowledges it
  cheaply, escalates on purpose, and asks the human through `aiur command request`
  instead of `aiur ask`.
- **Deliverable:** updates to `.claude/skills/aiur-run/references/executor.md` "Command
  decision loop" and a ≤ 5-line pointer in `SKILL.md` "Command decision loop"; mention in
  `website/docs-app/skills.md` if it summarizes the loop.
- **Non-goals:** agent skill (C8-T03).

## Dependencies and blockers

- C2-T04 (`executor-ack`), C6-T02 (answers on `executor-wait`), C7-T04
  (`--filter with-executor`) merged. DESIGN-E2 copy for command names.
- **#3005** (open): if merged, add its `aiur operator-relay-answer` usage in the same
  section ("record an answer the operator gave you in conversation"); if not, omit.

## Verified starting point (`45a290e3`)

- `.claude/skills/aiur-run/SKILL.md:552-617` "Command decision loop"
  (`executor-answer` `:566-600`, `executor-escalate` `:606-617`); file 1,293 lines.
- `.claude/skills/aiur-run/references/executor.md:143-206` "Command decision loop"
  (alert-driven discovery `:152-160`, judgment `:162-183`, escalate `:184-206`).
- `website/docs-app/skills.md` (106 lines).

## Chosen design

Add to `references/executor.md` (≈40 lines):

- "Each worker Command routed to you has a deadline (`decisions.escalation.*`; default
  per DESIGN-E2). Run `aiur executor-ack <id>` as soon as you start on it; answer or
  escalate before the answer deadline, or it moves to the operator on its own."
- "Triage list: `aiur commands --filter with-executor`."
- "Need the human yourself? `aiur command request "<question>" --option …` (2–3 options,
  recommended first). The answer arrives as an `executor.decision.answered` record on
  `executor-wait`; read it with `aiur commands <id> --json`. `aiur ask` is a deprecated
  alias."
- "You cannot answer a Command you raised, nor replace an answer the operator gave."

`SKILL.md`: one pointer line under "Command decision loop" to the reference section.

## Implementation steps

1. Edit `references/executor.md`; add the pointer in `SKILL.md`.
2. Update `website/docs-app/skills.md` if it lists the Executor loop commands.
3. Grep the repo for `aiur ask` in skills/prompts and align (also done in C6-T03).

## Non-happy paths

n/a — documentation; the risk is drift, mitigated by depending on merged behaviour.

## Compatibility and rollout

n/a.

## Verification

```bash
git grep -n -E "executor-ack|command request|with-executor" -- .claude/skills/aiur-run
wc -l .claude/skills/aiur-run/SKILL.md   # growth ≤ 5 lines vs base 1,293
```

Expected: commands named exist in `reference/cli.md`. Manual: a fresh Executor session
reading the skill performs ack → answer on a test Command during `aiurdev --test`.

## Completion and handoff

- [ ] Reference updated; SKILL.md pointer; #3005 line iff merged.
- Dependents: none.
