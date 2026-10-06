---
ticket_id: MP-E1-C4-T06
feature_id: MP-E1
chunk_id: MP-E1-C4
bucket: 2-platform
title: Merged PR but issue still open - grace timer and attention
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C4-T04, MP-E1-C4-T05, MP-E1-C3-T03, MP-E1-C3-T01, MP-E1-C5-T01]
prior_units: [U5]
prior_boundaries: [BO #30, PRL #15]
prior_features: []
prior_findings: [MP-E1 F7]
size_owner: n/a (build_queue files only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C4-T06 — The closing-keyword gap

> **Plan refresh (wave 0).** Uses only the Exchange hint and tracker
> observations; moves unchanged after MP-R1/R2.

## Identity and outcome

- Bucket 2, MP-E1, C4, T06.
- **User value:** when a prerequisite's PR merged but its issue stayed open
  (no closing keyword), the dependents do not wait forever in silence: one
  attention tells the Executor to close it.
- **Deliverable:** observer tracks `pr.merged` hints per prerequisite; after
  `merged_open_grace_seconds` with the issue still open the verdict stays
  `pending` and the planner opens `ticket.<id>.queue.attention.merged_issue_open`.

## Dependencies and blockers

- DESIGN-E1 (copy), C4-T04, C3-T03, C3-T01 (grace key).

## Verified starting point (`45a290e3`)

- On `pr.merged`, `CommentWake.mark_pr_merged_issue_done` writes `done` only
  when the PR body has a closing keyword; otherwise `human-review`
  (`orchestrator/comment_wake.ex:30, 250-291`;
  `orchestrator/merged_ticket_reconciler.ex:175-215`); same-repository
  keywords only (`recent_merge.ex:100-148, 428-448`).
- `ticket.<id>.pr.merged` is `live` and may be lost (events contract §11), so
  the merged flag also comes from `ticket_pull_request/1` (`merged?: true`, C4-T05).

## Chosen design

- `merged_at_ms` per prerequisite = first time either source says merged.
- Still open after the grace → attention (latched; resolves when the issue
  closes). Never a write.

## Implementation steps

1. Observer field + planner rule (≈ 30 lines).

## Non-happy paths

Event lost and no deposit (poll-only) → not detected; dependents keep
waiting (no alert). Stated in docs.

## Compatibility and rollout

No config beyond C3-T01's key.

## Verification

| Test (`src/test/aiur/build_queue/observer_test.exs`) | Expected | Fails without |
| --- | --- | --- |
| "merged + open beyond grace → one merged_issue_open attention" (injected clock) | one attention action | the timer rule |
| "merged + closed within grace → no attention" | none | the closed check |
| "duplicated pr.merged events → one attention" | one | latch (AC10 for attentions) |

Mutation check: drop the grace comparison → test 2 fires early.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/observer_test.exs
```

## Completion and handoff

- [ ] Detection + attention. Docs: attention listed in C9-T02.
- Dependents: C5-T02.
