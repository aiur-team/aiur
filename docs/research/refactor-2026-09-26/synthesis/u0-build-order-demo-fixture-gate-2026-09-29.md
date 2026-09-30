# U0 row 215: bundled Aiur Build Order pack

Research-only source check against clean candidate
`0299daca28383a336682374e19e90d6434aa4e1a`; no merged-main or live-use
claim. The tracked
`src/priv/build_orders/aiur-build-order.json` is 729 LF physical lines and
contains 54 tickets. Its owner-map action remains **conditional**.

## Runtime reachability

- `AIUR_BUILD_ORDER_DEMO=1` only selects `PlanningSource` in
  [config.exs](../../../../src/config/config.exs) (lines 20–25). The
  [bundled-pack README](../../../../src/priv/build_orders/README.md) (lines
  3–17) documents that switch and a separate explicit
  `:build_order_planning_pack` path. The switch alone does not select this JSON.
- Current [PackPaths](../../../../src/lib/aiur/build_order/pack_paths.ex)
  (lines 39–63, 83–107, 112–133) discovers workspace mirrors, repository
  state packs and `AIUR_BUILD_ORDER_DIRS` override paths. It does **not** scan
  `priv/build_orders`; `PlanningSource` uses that discovery list unless an
  explicit/configured pack path is supplied
  ([planning_source.ex](../../../../src/lib/aiur_web/build_order/planning_source.ex),
  lines 568–584). A `git grep` of candidate tracked files found no exact
  `aiur-build-order.json` reference outside the generic README example.
  External app configuration could still point at it; source search cannot
  prove absence of such consumers. OTP releases ship `priv` on disk
  ([mix.exs](../../../../src/mix.exs), lines 190–191, 234).
- This was once a deliberate default: introduction commit `d7c205b14`
  included this pack in `PlanningSource.@default_packs` with the CropTracker
  pack. The default-list reference disappeared before the frozen main (visible
  by comparing that commit's `planning_source.ex:25–35,223–228` with the
  current code). Historical intent is therefore stronger than an incidental
  unused fixture, while current automatic reachability is absent.

## The docs manifest is related but not a drop-in replacement

The [docs manifest](../../../../docs/build-order/build-order.json) has the
same 54 ticket IDs. Every ticket's title, lane/workstream, phase/phase_hint,
complexity/complexity_points, dependency list and issue number match the
bundled pack in a read-only JSON comparison. Its schema is broader: 7,822
lines with requirements, decisions, acceptance, publication and reconciliation
fields; the bundled pack has only the planning-source view. The docs manifest
still names `its-everdred/aiur` in `repository`, `build_order_id`, root and
ticket GitHub records, while the bundled pack names `aiur-team/aiur`. A direct
copy would change the selected repository and be filtered out by
`PlanningSource.filter_for_tracked_repository/1`
([lines 554–566](../../../../src/lib/aiur_web/build_order/planning_source.ex)).

The bundled pack's 54 `doc` values are short names such as
`tickets/BO-001.md`; **none** exists relative to `src/priv/build_orders` or
`docs/build-order`. All 54 docs-manifest `document` values resolve under
`docs/build-order`. `PlanningSource.ticket/3` accepts a safe relative path
without checking existence, then reads it only for an unmaterialized draft
([planning_source.ex lines 764–810](../../../../src/lib/aiur_web/build_order/planning_source.ex)); this pack has numeric issue IDs, so the broken paths may remain latent. No checked-in generator for this exact bundled pack was found, and its Git introduction added the JSON directly.

## Decision and acceptance gate

**Preferred if the bundled demo remains supported:** choose a single
authoritative, reviewable source for the compact planning view, then generate
the pack deterministically outside tracked text or as bounded tracked shards.
Normalize repository identity explicitly; preserve 54 IDs, root number 1084,
completion state, five workstreams, order, issue mappings and dependency graph.
Resolve document paths against a real packaged source or omit them by an
explicit supported policy. Compare `PlanningSource.catalog/0` and selected
snapshot semantics before/after, plus package/release inclusion and the
documented explicit-pack path. The 7,822-line docs manifest has its own U8
size debt; merely reading it at runtime is not a stable source contract.

**If removing this particular bundled pack:** first decide that the old
permanent-plan demo is retired; verify no shipped config, external pack-path
contract or acceptance test promises it; update the README/config demo wording
and any package example that names it. Keep `PlanningSource` and the
`AIUR_BUILD_ORDER_DEMO` switch if other pre-ticket packs remain supported.
The code search establishes lack of an automatic path, not permission to
delete the historic pack today. Recheck these facts on merged main before
assigning a U8 worker.
