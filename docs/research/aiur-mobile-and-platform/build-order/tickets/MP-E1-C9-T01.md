---
ticket_id: MP-E1-C9-T01
feature_id: MP-E1
chunk_id: MP-E1-C9
bucket: 2-platform
title: Skill conventions - create waiting members with the marker; queue usage
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C6-T02, MP-E1-C4-T02]
prior_units: [U9]
prior_boundaries: [CLI #31]
prior_features: []
prior_findings: [MP-E1 F10]
size_owner: n/a (skills and docs)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C9-T01 — Update `aiur-build` and `aiur-run`

> **Plan refresh (wave 0).** Skill paths at `45a290e3`. Ship only after the
> queue is enabled by default in a release (C3-T01 with OQ-6), or the new
> convention would leave members unlabelled-for-dispatch on installs without
> the queue.

## Identity and outcome

- Bucket 2, MP-E1, C9, T01. DESIGN-E1 **OQ-7**.
- **User value:** new Build Orders are created so that `agent:todo` means
  "ready" from the start, and the Executor knows how to use and override the
  queue.
- **Deliverable:** skill text and the reconciliation test updated.

## Dependencies and blockers

- DESIGN-E1 (OQ-7 = yes), C6-T02 (verbs exist), C4-T02 (adoption).

## Verified starting point (`45a290e3`)

- `.claude/skills/aiur-build/SKILL.md:218-236`: promotion is not machinery;
  every executable member gets `agent:todo` at creation.
- `.claude/skills/aiur-run/SKILL.md:228-234`: executable work carries
  `agent:todo` at creation.
- `.claude/skills/aiur-build/scripts/tests/test_github_reconciliation.py:48-55`
  rejects `agent:queued` as an unprojected label.
- Docs page: `website/docs-app/skills.md`.

## Chosen design

- aiur-build: members with open prerequisites are created with `agent:queued`;
  members with none get `agent:todo`; then `aiur queue add --build-order <root>`
  adopts the root. Keep "never create first and label second".
- aiur-run: a short "Build queue" subsection: `queue show` in the audit,
  `release` after a manual override, `--todo --only` holds queue items, how to
  read `promoted_unauthorized` and `prerequisite_failed`.
- Reconciliation script: project `agent:queued` as an allowed observed label
  for members with prerequisites; keep rejecting it elsewhere.

## Implementation steps

1. Edit both SKILL.md files; update the Python projection and test.
2. `website/docs-app/skills.md` one-line change note.

## Non-happy paths

Installs with the queue disabled: the skill tells the Executor to check
`aiur queue show` status and fall back to `agent:todo` when disabled.

## Compatibility and rollout

Skill text only; vendored copies follow the repo's normal skill sync.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `test_github_reconciliation.py` "queued is accepted for a member with prerequisites" | no error | the projection change |
| same, existing "rejects unprojected routing families" minus `agent:queued`, plus a case "queued on a member without prerequisites is rejected" | error | the scoping |

```bash
python3 -m pytest .claude/skills/aiur-build/scripts/tests/test_github_reconciliation.py
```

## Completion and handoff

- [ ] Skills, test, `skills.md`.
- Dependents: C9-T03 (e2e follows the new convention).
