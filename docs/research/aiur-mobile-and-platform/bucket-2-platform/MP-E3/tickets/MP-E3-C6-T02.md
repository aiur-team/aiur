---
ticket_id: MP-E3-C6-T02
feature_id: MP-E3
chunk_id: MP-E3-C6
bucket: 2-platform
title: "Executor status header: harness state with age, read capability, wakes and roster"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C6-T01, MP-E3-C4-T05]
prior_units: [U8]
prior_boundaries: [WEB, EXE]
prior_features: [MP-N3 (compact form reused on the meta-dashboard)]
prior_findings: [plan §5 table; AGENTS.md computed-age and unknown-path rules]
size_owner: "U8 WEB owner"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C6-T02 — Executor status header

## Identity and outcome

- Bucket 2 · MP-E3 · C6 · T02.
- **User value:** at a glance: is the Executor working, waiting for me, idle,
  ended or unknown — and how long ago aiur last heard from it.
- **Deliverable:** `AiurWeb.Executor.StatusHeader` component rendering
  `Executor.Status.snapshot/0` (C4-T05) per DESIGN-E3 field order, with a compact
  variant for MP-N3; live refresh on `{:executor_hook, _}` and a 5 s tick.
- **Non-goals:** blockers/background panels (T03).

## Dependencies and blockers

- DESIGN-E3 (fields, order, compact form). MP-E3-C6-T01, MP-E3-C4-T05.

## Verified starting point

- Snapshot shape: MP-E3-C4-T05. Harness states and freshness: MP-E3-C4-T01.
- The CLI emits `observed_at`, `age_ms`, `freshness`; a web surface computing the
  same must render them (AGENTS.md "Computed ages and collapsed causes", rule 1).

## Chosen design

- Fields (pending DESIGN-E3 order): state badge, "last heard N min ago"
  (rendered from `age_ms`, re-computed each tick), harness + CLI version, read
  capability status + reason, wakes `cursor/pending` or "unavailable", roster
  count and owner.
- `:unknown` renders "Status unknown, last seen N min ago" (DESIGN-E3 §4) and
  never the idle badge.
- Any snapshot key `:unavailable` renders "unavailable" for that field.

## Implementation steps

1. Component + compact variant; 2. subscribe/tick in `ExecutorLive`.

## Non-happy paths

- Snapshot call timeout → whole header "unavailable" with retry; history below
  keeps working.

## Compatibility and rollout

- UI only. Rollback: revert.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/executor/status_header_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "unknown renders last-seen age, not idle" | text with minutes; no idle badge | unknown branch (mutation: replace with idle or "0 min" fails) |
| "age re-renders on tick" | text changes after tick | tick |
| "unavailable wakes render 'unavailable'" | text | per-key branch (mutation: render 0 fails) |
| "compact variant fields" | DESIGN-E3 compact set | variant |

## Completion and handoff

- Dependents: MP-N3.
