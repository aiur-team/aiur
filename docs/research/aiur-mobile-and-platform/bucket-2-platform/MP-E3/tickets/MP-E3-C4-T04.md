---
ticket_id: MP-E3-C4-T04
feature_id: MP-E3
chunk_id: MP-E3-C4
bucket: 2-platform
title: "(Optional) aiur-run skill emits executor.progress on its progress-table cadence"
status: blocked
blocked_by: [DESIGN-E3, OQ-E3-6, MP-E4-C3-T02]
prior_units: [n/a]
prior_boundaries: [EXE]
prior_features: [MP-E4 (executor_progress jump point)]
prior_findings: [MP-E3 plan §5 last paragraph]
size_owner: n/a (skill text)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C4-T04 — Executor progress events (optional)

## Identity and outcome

- Bucket 2 · MP-E3 · C4 · T04. Optional; only if Kevin answers OQ-E3-6 "yes".
- **User value:** the Executor's periodic progress tables become jump points in
  the Executor conversation.
- **Deliverable:** a short addition to `.claude/skills/aiur-run/SKILL.md`: when
  the Executor posts its progress table, it also runs
  `aiur executor-emit executor.progress --payload '{"done":N,"total":M}'`
  (ids and counts only, no prose).
- **Non-goals:** product code; changing the table's cadence.

## Dependencies and blockers

- **OQ-E3-6** (owner). DESIGN-E3.
- MP-E4-C3-T02 (resolver anchors `executor.*` events; MP-E4-C3-T03 causal rule
  matches the `executor-emit` command entry).

## Verified starting point

- The skill asks for a progress table "on a real cadence"
  (`.claude/skills/aiur-run/SKILL.md:99-120`); aiur never sees it.
- `aiur executor-emit <topic> --payload <json>` publishes `executor.*` only
  (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:472`, `:3290-3300`;
  `agent_control_cli.ex:384-402`).

## Chosen design

One paragraph in the skill's progress-table section with the exact command and
the payload allowlist (`done`, `total`, `blocked`), plus a sentence that the
event is a navigation aid, not a report.

## Implementation steps

1. Edit the skill; 2. add `executor.progress` to MP-E4's jump-point catalogue if
   not already (`executor_progress` kind covers `executor.*`).

## Non-happy paths

- Executor runs without the daemon → `executor-emit` fails; the skill says to
  continue without it.

## Compatibility and rollout

- Skill text only. Rollback: revert.

## Verification

- Manual: an Executor run using the skill shows "Executor: progress" jump points
  in the Executor view (after MP-E3-C6). Mutation check: n/a.

## Completion and handoff

- [ ] `website/docs-app/skills.md` mentions the event if it lists skill outputs.
