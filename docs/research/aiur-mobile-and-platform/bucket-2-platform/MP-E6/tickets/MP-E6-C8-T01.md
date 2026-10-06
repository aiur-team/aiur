---
ticket_id: MP-E6-C8-T01
feature_id: MP-E6
chunk_id: MP-E6-C8
bucket: 2-platform
title: Voice conversation history — per-target list and full transcript view
status: blocked
blocked_by: [DESIGN-E6, MP-E6-C6-T02, MP-E6-C7-T02]
prior_units: []
prior_boundaries: [VOX, WEB]
prior_features: []
prior_findings: []
size_owner: n/a (new LiveView component; not inside dashboard_live.ex)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C8-T01 — History views

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C8 transcript review UI and resume.
- **User value:** the operator can reread exactly what was discussed, what the assistant was
  told, and what was confirmed and delivered — the full transcript, never a summary.
- **Deliverable:** a history list per target (DESIGN-E6 "Transcript history per target") and
  a detail view rendering every record kind (turns, context blocks collapsed by default,
  tool calls, drafts with outcomes, end reason), paginated with the C6-T02 API; empty state
  "No past sessions for this target" (DESIGN-E6 copy).

## Dependencies and blockers

DESIGN-E6 (placement and layout). Predecessors C6-T02, C7-T02.

## Verified starting point

New UI. Pagination via `TranscriptStore.get/2` `after` cursor (C6-T02).

## Chosen design

- Separate LiveView component (U8 rule: no growth of `dashboard_live.ex`, 2,903 lines).
- Detail loads 200 records, "Load more" by cursor; torn tail shown with a note.
- No summarise/delete control unless C6-T04 is built (then Delete with confirmation).

## Implementation steps

Component, routes or panel placement per DESIGN-E6, tests, docs (`gui.md`).

## Non-happy paths

Store unavailable → "Voice history unavailable" (not "No past sessions"); unknown record
kind → shown as raw JSON line.

## Compatibility and rollout

Ships with DESIGN-E6. Rollback: revert.

## Verification

| Test (LiveView) | Expected |
| --- | --- |
| "a 2,000-turn transcript loads in pages" | 10 pages of 200 |
| "store failure renders unavailable, not empty" | — |
| "drafts show their final outcome" | delivered/stale chips |
| "no element offers to summarise" | no such text/button |

```bash
env -C src mise exec -- mix test test/aiur_web/voice_history_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check (unknown path).** Render the empty-state copy on store error: the
unavailable test fails.

## Completion and handoff

- [ ] History list + detail; docs in PR.
- **Dependents:** C8-T02, C8-T03.
