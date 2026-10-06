---
ticket_id: MP-E1-C9-T02
feature_id: MP-E1
chunk_id: MP-E1-C9
bucket: 2-platform
title: Concept docs - queue states, marker, Build Order queueing
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C5-T02, MP-E1-C6-T02]
prior_units: [U9]
prior_boundaries: []
prior_features: []
prior_findings: [MP-E1 F9]
size_owner: n/a (docs)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C9-T02 — Explain the build queue

> **Plan refresh (wave 0).** Docs paths at `45a290e3`.

## Identity and outcome

- Bucket 2, MP-E1, C9, T02. AGENTS.md "Docs ship with the change": the
  per-ticket docs (config, CLI, bus topics) ship in their own tickets; this one
  covers the model explanation that spans them.
- **Deliverable:**
  - `website/docs-app/concepts/ticket-lifecycle.md`: a "Build queue" section —
    marker vs state, item states (contract §2.3), promotion/withdrawal rules,
    competing writers, the attention list, the "downgrading" runbook pointer,
    webhook-only detection of closed-unmerged PRs, unauthorized detection
    needs a free slot.
  - `website/docs-app/concepts/build-orders.md`: "Queueing a Build Order".
  - `website/docs-app/reference/cli.md:99` note that `units --condition queued`
    means "has `agent:todo`", unrelated to `agent:queued`.

## Dependencies and blockers

- DESIGN-E1 (final names and copy), C5-T02, C6-T02.

## Verified starting point (`45a290e3`)

- Pages exist: `concepts/ticket-lifecycle.md`, `concepts/build-orders.md`,
  `reference/cli.md` (`:99` units condition).

## Chosen design

Edit existing pages; no new page (AGENTS.md "Prefer editing an existing page").

## Implementation steps

1. Three page edits.

## Non-happy paths

n/a — documentation.

## Compatibility and rollout

n/a.

## Verification

| Check | Expected |
| --- | --- |
| `env -C website/docs-app bun run build` | builds |
| `bash website/docs-app/scripts/check-cli-reference.sh` | passes |
| Review: every state, attention and config key named in the docs exists in code (grep) | no stale names |

## Completion and handoff

- [ ] Three pages updated.
- Dependents: none.
