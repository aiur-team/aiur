# U0 row 215: bundled Aiur Build Order pack

Research base: `origin/main@220b8f25313acf92799f25af9a6db09583ef207d` (2026-09-29). The unresolved-row source is the separate research ref `research/refactor-owner-map-audit-2@f435525bf406c945be525b75062f9b680161d42d`; that branch was read only. This note changes no product behavior.

## Reachability on current main

- `src/priv/build_orders/aiur-build-order.json` is 729 physical lines, 54 tickets, `completed: true`, and `permanent: true`. It is an embedded display pack for `aiur-team/aiur:build-order-dashboard` root 1084, not the canonical planning source.
- The normal pack discovery in `src/lib/aiur/build_order/pack_paths.ex:41-45,83-107` searches `.aiur/build_orders`, the repository state node, and `AIUR_BUILD_ORDER_DIRS`. It does **not** search `src/priv/build_orders` or release `priv/build_orders`. `PlanningSource.pack_paths/0` uses this discovery unless a planning-pack override is set (`src/lib/aiur_web/build_order/planning_source.ex:568-584`).
- `AIUR_BUILD_ORDER_DEMO=1` selects `PlanningSource` at build time (`src/config/config.exs:20-25`); it does not select this pack. The local `src/priv/build_orders/README.md:7-17` separately documents `config :aiur, :build_order_planning_pack, "priv/build_orders/<file>.json"`, which *does* make an embedded pack reachable through `PlanningSource.load_pack/2` (`planning_source.ex:610-615`). The feature is therefore opt-in and documented, even though the flag alone does not load this fixture.
- A current-main search found no direct reference to `aiur-build-order.json` in product code, checked-in app config, tests, or website docs. PlanningSource tests set explicit paths to their own fixtures; they do not assert this file's bytes. An outside operator configuration can still name the documented override, so the repository search does not prove zero use.
- `docs/build-order/build-order.json` has the same 54 ticket IDs but a different repository identity and a richer publication schema. It cannot simply be substituted for the embedded display pack. The historical baseline remains available in Git independently of the runtime fixture.

## Proposed disposition

**Candidate cut from the shipped runtime, scoped to the 729-line Aiur display pack.** Keep the general `PlanningSource`, `PackPaths`, and canonical `docs/build-order/build-order.json`. Removing this completed, default-undiscovered fixture avoids adding a generator and source-shard protocol solely to preserve an opt-in snapshot. Update the `src/priv/build_orders/README.md` example so it does not promise the removed file; document how an operator can point the existing override at a current, operator-owned pack. Do not treat this as permission to remove the other bundled packs or to one-line-minify them. The adjacent `croptracker-demo.json` is 1,611 lines and needs its own source/consumer review.

## Gates before an implementation PR

1. Confirm whether any supported demo, package smoke test, operator config, or external documentation deliberately uses `priv/build_orders/aiur-build-order.json`. In particular, inspect the release's effective `:build_order_planning_pack` setting or an equivalent configuration census, without printing private configuration values. If used, preserve the path and plan a compatible migration instead of deleting it.
2. Obtain the product choice to retire the bundled *Aiur* snapshot. The internal README explicitly offers embedded packs as focused demos; deleting one changes that offer even though default discovery does not use it.
3. In the implementation PR, prove the normal catalog and an explicit operator-owned pack still load, and prove packaging has no stale reference to the removed asset. Update the internal README in that PR. Compare a release build's `priv` contents before and after, and report the measured package-size change if one is claimed.

This resolves the action direction for row 215 as **cut, gated by supported-consumer confirmation**. Runtime use outside this repository remains unknown; no line or package-size saving is claimed yet.
