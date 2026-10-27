---
ticket_id: MP-N5-C5-T01
feature_id: MP-N5
chunk_id: MP-N5-C5
bucket: 3-mobile-watch
title: Notifications guide page — defaults, options, limits, what Apple/Google/relay see
status: blocked
blocked_by: [DESIGN-N5 (D-1..D-8 answers), DESIGN-N4, MP-N5-C4-T01, MP-N4-C2-T05, REFRESH-MP-N5-C5-T01-4fbe1095]
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

Refreshed against 4fbe109541ba1e279d3eb315d8455c4d139c92ba on 2026-10-26 (MP-R1-C11-T03). Mechanical matches were byte-checked; current starting-point ranges still need the named source review `REFRESH-MP-N5-C5-T01-4fbe1095`. Do not implement from the historical ranges below. base_sha and all prior gates are retained; this is not a design rejection.

Sidebar guide entries at `website/docs-app/.vitepress/config.ts:131-140`; docs build per
`.github/workflows/website.yml:68-71`.

Refreshed against 47140566ffbf8d8ae9b6e031dbedaf0fc3c6ae9f on 2026-10-14 (MP-R1-C11-T02). Verified citations: `.github/workflows/website.yml:68-71`. base_sha retained; other citations need review.

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
