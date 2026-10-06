---
ticket_id: MP-N1-C7-T02
feature_id: MP-N1
chunk_id: MP-N1-C7
bucket: 3-mobile-watch
title: "Demo mode entry point and a persistent Demo badge"
status: blocked
blocked_by: [DESIGN-N1, DESIGN-N2, "OQ-N1-1 (= public listing)", "D-N1-7", MP-N1-C7-T01, MP-N1-C4-T06, MP-N3-C4-T01, MP-N6-C3-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N2, MP-N3, MP-N6]
prior_findings: []
size_owner: n/a (new package code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C7-T02 — Demo entry and badge

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C7.
- **User value:** a reviewer (or a curious user without a machine) can start demo mode from the
  first-run screen, and nobody can mistake demo data for live data.
- **Deliverable:** a "Try demo" action on the DESIGN-N2 first-run screen, an "Exit demo" action in
  Settings, and a non-dismissable "Demo" badge in the app frame (native header and the meta list
  title) while `ApiProvider` is in demo mode, per DESIGN-N1 surface 8.
- **Non-goals:** the data (T01).

## Dependencies and blockers

Conditional as T01. DESIGN-N1 surface 8 and DESIGN-N2 first run (entry placement); MP-N1-C7-T01;
MP-N1-C4-T06 (header); MP-N3-C4-T01 (list title); MP-N6-C3-T01 (Command screen shows the badge).

## Verified starting point (base `45a290e3`)

No app. DESIGN-N1 §3 item 8 and §2 D-N1-7.

## Chosen design

Badge is rendered by the app frame from `ApiProvider.mode`, not by each screen, so a new screen
cannot forget it. Entering demo with paired machines present is allowed; exiting returns to the
real list unchanged (T01 storage rule).

## Implementation steps

Frame badge component, first-run action, settings action. About 60 lines.

## Non-happy paths

App killed in demo → restarts in real mode (demo state is not persisted).

## Compatibility and rollout

As T01.

## Verification

Jest `src/shell/__tests__/demoBadge.test.tsx`: `badge_visible_on_every_registered_route_in_demo`
(iterates the MP-N1-C4-T01 route table; mutation: render the badge only in the meta screen →
fails), `badge_absent_in_real_mode`, `restart_returns_to_real_mode`.

```bash
npm --prefix packages/aiur-mobile test -- src/shell/__tests__/demoBadge.test.tsx
```

## Completion and handoff

- [ ] Tests pass; DESIGN-N1 surface 8 approved copy used.
- [ ] Docs: covered by the T01 guide section.
- [ ] Dependents: MP-N1-C8-T02 (review notes).
