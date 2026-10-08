---
ticket_id: MP-N5-C5-T01
feature_id: MP-N5
chunk_id: MP-N5-C5
bucket: 3-mobile-watch
title: Notifications guide page — defaults, options, limits, what Apple/Google/relay see
status: blocked
blocked_by: [DESIGN-N5 (D-1..D-8 answers), DESIGN-N4, MP-N5-C4-T01, MP-N4-C2-T05]
prior_units: []
prior_boundaries: [website docs]
prior_features: [MP-N4]
prior_findings: [AGENTS.md "Docs ship with the change"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C5-T01 — Notifications guide

## Identity and outcome

Bucket 3, MP-N5, chunk C5. A user guide page `website/docs-app/guide/notifications.md`
(PROPOSED) plus sidebar entry in `website/docs-app/.vitepress/config.ts`: defaults (D18),
every option and its availability reasons, the progress step rule (highest threshold
only, no repeats, no backlog after reconnect), the coalescing window and hourly cap, the
privacy table (what Apple, Google and the relay see — linking the MP-N4 relay guide from
MP-N4-C2-T05 and the contract), and the `push:` machine settings (whose reference rows ship
with MP-N4-C3-T01).

## Dependencies and blockers

**Blocked** on DESIGN-N5 answers (option names, D-1 mute, D-4/D-5/D-8 defaults) and
DESIGN-N4 (what users see); C4-T01 (screens exist to describe); MP-N4-C2-T05 (relay page
to link).

## Verified starting point

Sidebar guide entries at `website/docs-app/.vitepress/config.ts:131-140`; docs build per
`.github/workflows/website.yml:50-53`.

## Chosen design

Prefer one guide page; no duplicate of the contract — link it (AGENTS.md: "a second copy is
a copy that goes stale").

## Implementation steps

Write page, add sidebar link, build docs.

## Non-happy paths

n/a — documentation.

## Compatibility and rollout

n/a.

## Verification

`env -C website/docs-app bun run build` succeeds; reviewer checks every option in the
settings screen appears with its default.

## Completion and handoff

- [ ] Page reachable from the sidebar.
