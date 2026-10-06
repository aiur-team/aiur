---
ticket_id: MP-E1-C8-T02
feature_id: MP-E1
chunk_id: MP-E1-C8
bucket: 2-platform
title: Queue view navigation, docs page and browser check
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C8-T01]
prior_units: [U6]
prior_boundaries: [WEB #34]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C8-T02 — Make the view reachable and prove it renders

> **Plan refresh (wave 0).** Docs paths at `45a290e3`; MP-R1's public component
> directory page (MP-REQ4) later lists `build-queue`.

## Identity and outcome

- Bucket 2, MP-E1, C8, T02.
- **User value:** the operator finds the view from the dashboard and the docs,
  and it works on a phone-width browser.
- **Deliverable:** docs (`website/docs-app/guide/gui.md` page table row, with
  the `aiur queue show` mirror), sidebar entry in
  `website/docs-app/.vitepress/config.ts` only if a new docs page is added
  (AGENTS.md), and a browser check at desktop and phone widths.

## Dependencies and blockers

- DESIGN-E1, C8-T01.

## Verified starting point (`45a290e3`)

- `website/docs-app/guide/gui.md:3, 29-30` page table with CLI mirrors.
- Browser harness: `src/test/browser/fixture_server.exs`,
  `src/test/support/browser_harness/fixtures.ex`,
  `src/test/aiur/browser_harness/fixtures_test.exs`.

## Chosen design

- Add a fixture read model to the browser harness fixtures (no live agents,
  memory note "OCC dashboard local parity run").
- Check the page at 1280 px and 390 px: no horizontal scroll, all states
  legible, screenshot attached to the PR (memory note: "healthy" means no rule
  matched — look at the screenshot).

## Implementation steps

1. `gui.md` row; optional new docs page + sidebar.
2. Harness fixture + check script run.

## Non-happy paths

n/a — docs and verification only.

## Compatibility and rollout

None.

## Verification

| Check | Expected | Fails without |
| --- | --- | --- |
| `src/test/aiur/browser_harness/fixtures_test.exs` "build queue fixture renders" | fixture loads | the fixture |
| Browser run at 1280 and 390 px (ce-test-browser or the harness) | screenshots show the approved layout; no horizontal scroll | — (manual evidence) |
| `env -C website/docs-app bun run build` (`website/docs-app/package.json` script `build` = `vitepress build .`) | builds | docs syntax |

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/browser_harness/fixtures_test.exs
```

## Completion and handoff

- [ ] Docs row; screenshots at two widths in the PR.
- Dependents: none.
