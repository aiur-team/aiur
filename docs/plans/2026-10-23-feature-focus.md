---
execution: code
artifact_readiness: implementation-ready
---
# Feature header and focus modes

Port the frozen design's feature header and compact entries, using whole-index
server statistics and the existing layout, paging, and filter APIs (#3154).

## Implementation

1. Add `src/priv/static/build-home/features.js`: own-key feature resolution,
   exact header DOM and sparkline, explicit unknown figures, compact entries with
   loaded dependency ghosts, and cancellable `ensureFrom` paging. Wire cards,
   list, columns, render, filters, and hook first-paint/resync/URL handling.
2. Add nullable `oldest` to `src/lib/aiur/build_order/index/catalogue.ex`,
   `src/lib/aiur_web/build/payload_schema.ex`, and the browser fixture mapper.
   Count only closed owning/also-affecting rows, independently of loaded pages.
3. Add focused unit, browser interaction, paging, keyboard and narrow-screen behaviour tests;
   register their package scripts. Update the existing dashboard guide because
   the feature changes a visible surface.

## Verification

- `src/browser/scripts/build-home-features.test.mjs`: own/prototype slugs,
  compact runs, loaded ghosts, date-less gaps, cancellation and unknown figures.
- `src/browser/tests/build-home-features.browser.spec.mjs`: header, mode/clear,
  URL navigation, live diffs, focus dims, compact ghosts and history paging.
- Keyboard mode/Clear focus ownership and 390px overflow checks; parity work
  is excluded by the binding #6061 decision.
- `src/test/aiur/build_order/feature_oldest_test.exs`: earliest owner/also closure,
  no closed members, whole-index result despite a paged window.
- Run affected tests, compile, lint, format, structural and pre-PR gates. Prove
  new tests fail with their production hunks reverted in an isolated worktree.

## Risks and review

Use `Object.hasOwn` everywhere activation matters; retain unknown slugs in the
URL. Preserve unavailable values and reasons, never render a plausible zero.
Keep paging single-flight, cancel between requests, paint before fetching, and
reuse scroll anchoring. Register delegated handlers with hook lifetime.
Keep the PR draft on the direct blocker branch until #5120 merges. No new
config, dependency, or layout algorithm is needed.

Self document review: contracts map to current files; list rendering accepts
explicit data/state so feature resolution must support those arguments. URL
application is now in `hook.js`, not `url.js`; wire the actual owner there.
