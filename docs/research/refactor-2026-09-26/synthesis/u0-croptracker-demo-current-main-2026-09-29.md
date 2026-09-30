# U0 adjacent fixture: bundled CropTracker demo pack

Research base: `origin/main@220b8f25313acf92799f25af9a6db09583ef207d` (2026-09-29). The frozen owner map names `src/priv/build_orders/croptracker-demo.json` as a Build Order fixture with a provisional regenerate action. This note is a current-main disposition, not an implementation.

## Reachability and provenance

- The tracked JSON has 1,611 physical lines, 116 distinct tickets, nine phases, six workstreams, and 299 `depends_on` entries. It declares `demo: true`, plan version 2, and repository `its-everdred/croptracker`; none of its tickets has a GitHub mapping. The internal `src/priv/build_orders/README.md:42-49` says it was generated from the sibling CropTracker pre-ticket planning pack and ticket headers, and explicitly calls it deletable demo data. Git history introduced it in `21a5b5af2` on 2026-07-19 and refreshed it in `4c7c6a677`.
- The sibling CropTracker checkout still has nine `docs/build-order/build-order-phase-*.json` files at plan version 2. Their 116-member ID union exactly matches the embedded pack. They do **not** by themselves establish full regeneration parity: the current phase JSON files contain no `dependency_edges`, while the embedded pack carries 299 dependencies and derives titles from ticket documents.
- `AIUR_BUILD_ORDER_DEMO=1` switches the application data source to `PlanningSource` (`src/config/config.exs:20-25`), but `PackPaths.discovered_sources/0` searches only workspace mirrors, repository state packs, and `AIUR_BUILD_ORDER_DIRS` (`src/lib/aiur/build_order/pack_paths.ex:41-45,83-107`). It never searches bundled `priv/build_orders`; the flag alone cannot surface this fixture. Normal catalogs also filter foreign repositories (`src/lib/aiur_web/build_order/planning_source.ex:554-565`).
- An explicit `:build_order_planning_pack` override **can** load the embedded file and bypass the repository filter (`planning_source.ex:554-579,610-615`), as the internal README documents. The current product code, checked-in application configs, website docs, and tests contain no reference to `croptracker-demo.json` by name. Test fixtures exercise the generic source instead. External operator overrides remain uncounted.
- A July decision document explicitly said to keep the CropTracker demo while removing a separate Units demo (`docs/plans/2026-07-20-001-feat-commands-decisions-redesign-plan.md:35,140`). That is historical intent, not evidence of a current default consumer; it must be acknowledged before retirement. Current user documentation describes workspace/state packs as visible and `docs/` or inactive-branch packs as invisible (`website/docs-app/concepts/build-orders.md:9-24`).

## Proposed disposition

**Candidate cut of the bundled 1,611-line CropTracker snapshot**, while retaining the generic `PlanningSource` and `AIUR_BUILD_ORDER_DEMO` opt-in mode. The fixture is foreign to Aiur's tracked repository and unreachable by default; retaining the entire historical snapshot in every release has no demonstrated current consumer. Keep the authoritative CropTracker plan and ticket documents in CropTracker, and Git's immutable old blob for historical reproduction. Update the internal README so the override example points to an operator-owned or deliberately installed pack. Do not remove the general planning mode merely because its old README says the demo flag can be deleted with the fixture.

## Gates before an implementation PR

1. Check supported demo scripts, package smoke tests, effective release configuration, and external instructions for an explicit override naming this file. A repository text search cannot establish zero external use. If still supported, choose a compatible path-preserving split or generator instead of deleting it.
2. Confirm retirement of the July keep-demo choice with the product owner. Preserve one executable generic PlanningSource example in tests or docs so cutting the bundled sample does not silently remove the demonstrated pre-ticket flow.
3. If the decision is **keep**, a regeneration plan must source all 116 IDs, titles, phases, lanes, and 299 dependencies, emit the same runtime JSON deterministically, keep every tracked source under 500 lines, and prove rendered catalog/selected-root and release-asset parity. The nine phase JSONs alone are insufficient for that gate.
4. If the decision is **cut**, remove only the data fixture and stale README claims, then test default discovery, explicit operator-owned override, and release contents. Measure actual package-size change before claiming a saving.

No runtime use outside this repository, net line saving, or package-size saving is claimed here.
