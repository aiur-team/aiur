---
ticket_id: MP-R1-C8-T8
feature_id: MP-R1
chunk_id: MP-R1-C8
bucket: 1-refactor
title: Build-orders component — declared facades, component-owned child specs, and a separate ticket-context component
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C8-T5, MP-R1-C8-T7, MP-R1-C5-T2 (Bounded to kernel), U2 graph contract (prior unit, via U8 BO_RUNTIME prerequisite)]
prior_units: [U2, U6, U5]
prior_boundaries: [BO #30, WEB #34, SD #35, APP_BOOT]
prior_features: []
prior_findings: []
size_owner: BO_RUNTIME (graph_projection.ex 1,825, build_order_presenter.ex 1,046 — not edited) and APP_BOOT (src/lib/aiur.ex child order) — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T2
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C8-T8 — Build-orders facades, child specs, ticket-context

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C8 (step S12, path-map row PR-10).
- **User value:** none visible. Build orders become a declared optional component with
  a known public surface, so MP-E1's `BuildOrder` dependency source, MP-N3 and MP-N5
  (progress) depend on named facades, and the composition root no longer names
  build-order internals.
- **Deliverable:**
  1. `components.json` `build-orders` entry with `facades` = the modules surfaces
     already use (list below) and the remaining allowlist entries named.
  2. `Aiur.BuildOrder.Component.child_specs(:early | :late, opts)` (PROPOSED
     `src/lib/aiur/build_order/component.ex`) returning exactly today's specs; `aiur.ex`
     calls it at the two existing positions. U8 `APP_BOOT` owns `aiur.ex`: child order
     must not change.
  3. A new manifest component **`ticket-context`** (L3, optional, requires `github`,
     `tracker`, `projections`) owning the 15 `build_order/ticket_detail*` and
     `ticket_history*` files and `AiurWeb.BuildOrder.TicketContext*`. They serve the
     dashboard ticket dialog for every ticket, not only build orders, and read GitHub
     (`GitHub.ResourceStore`, `GitHub.RequestOrigin`).
- **Non-goals:** no file moves or renames; no disable flag (build orders stay on by
  default — removability needs a capability report, MP-R1-C3, and a DESIGN-R1
  answer); no change to the `AiurWeb.BuildOrder.DataSource` behaviour (16 callbacks,
  already clean) or the `:build_order_data_source` config switch.

## Dependencies and blockers

- DESIGN-R1 §1.
- MP-R1-C8-T5 (sanitizer out of build-orders), MP-R1-C8-T7 (GitHub → build-orders
  edges cut), MP-R1-C5-T2 (`Aiur.BuildOrder.Bounded` → kernel; used at
  `github/issues.ex:375`, `global_config_startup.ex:71`, `units_table.ex:332`).
- MP-R1-C4 build-orders section registration (`config.ex:8,616-657` →
  `BuildOrder.Cadence`) — may land before or after; this ticket names the edge.
- U8 `BO_RUNTIME` lists "U2 graph contract" as its start prerequisite; this ticket
  edits no `BO_RUNTIME` file, only `aiur.ex` and the manifest, so it waits only for U2
  if U2 changes `aiur.ex` child order (`APP_BOOT` start prerequisite "U0/U2 startup contract").
- MP-E1 (if shipped) references `Aiur.BuildOrder.GraphProjection` only from its
  `sources/build_order.ex`; that reference must match a declared facade below.
- Not concurrently with C8-T7 (manifest entry).

## Verified starting point (45a290e3)

- Children: `aiur.ex:356` `{Aiur.BuildOrder.TicketDetailCoordinator, runtime_config?: true}`,
  `:357` `{Aiur.BuildOrder.GraphProjection, runtime_config?: true}`,
  `:433` `{Aiur.BuildOrder.TicketHistoryProvider, runtime_config?: true}`,
  `:434` `{Aiur.BuildOrder.AdHocSource, poll_on_start: …}`, `:435` `{Aiur.BuildOrder.PackStatus, poll_on_start: …}`,
  then `:436` `OpenTicketSource` and `:441` `GitHub.ViewStateSweep` (which must start
  after its sources, per the comment at `:437-440`).
- Surface references (`git grep -o 'Aiur\.BuildOrder(\.[A-Z][A-Za-z]+)+' 45a290e3 -- src/lib/aiur_web src/lib/aiur/build_orders_cli.ex`):
  `build_orders_cli.ex:13-17` → `Catalog`, `ProgressRenderer`, `ProviderHealth`,
  `RootSummary`, `GraphProjection`, `GraphProjection.Snapshot`, `AiurWeb.BuildOrder.{DataSource, Runtime}`;
  `live/build_order_live.ex:6` and `operator_control_center/analytics/scope_resolver.ex:11,15,33`
  → `GraphProjection.Snapshot`, `AiurWeb.BuildOrder.Runtime`, `DataSource`;
  `stream_deck_grid.ex:12` → `BuildOrder.Metadata`;
  `live/dashboard_live.ex:11-14,1886-2003` → `TicketDetail.State`, `TicketDetailCoordinator`,
  `TicketHistory.Snapshot`, `TicketHistoryProvider` (ticket dialog; → `ticket-context`).
- `GraphProjection` public API: `catalog/1`, `selected/2`, `demand/2`, `refresh/2`,
  `read_due?/2`, `release/2`, `refresh_catalog/1`, `subscribe_catalog/1`,
  `subscribe_selected/2`, `reset_topic/0` (`graph_projection.ex:36-127`).
- No orchestrator module references `Aiur.BuildOrder` (component-map §4 fact).
- Tests: `src/test/aiur/build_orders_cli_test.exs`, `build_orders_cli_first_read_test.exs`,
  `build_orders_cli_stale_read_test.exs`, `src/test/aiur/build_order/**`,
  `src/test/aiur_web/build_order/**`, the application child-spec test owned by
  `APP_BOOT` (`src/test/aiur/application_test.exs`). Note `Aiur.BuildOrder.Readiness` is defined in `build_order/edge_state.ex:25` and `Aiur.BuildOrder.ProviderHealth` in `build_order/lifecycle.ex:1`.

## Chosen design

- **Facades, not a new wrapper module.** The surfaces already call a small set of
  stable modules; declaring them is cheaper and truer than a pass-through.
  `build-orders.facades` = `Aiur.BuildOrder.GraphProjection`,
  `Aiur.BuildOrder.GraphProjection.Snapshot`, `Aiur.BuildOrder.Catalog`,
  `Aiur.BuildOrder.ProgressRenderer`, `Aiur.BuildOrder.ProviderHealth`,
  `Aiur.BuildOrder.RootSummary`, `Aiur.BuildOrder.Readiness`, `Aiur.BuildOrder.Metadata`,
  `Aiur.BuildOrder.GitHubGraph` (for MP-R1-C8-T7's tests),
  `Aiur.BuildOrder.Component`, `AiurWeb.BuildOrder.DataSource`, `AiurWeb.BuildOrder.Runtime`.
  Anything else under `build_order/` becomes private (checker).
- **Component-owned child specs** (promotion test §5 item 2): `child_specs(:early, opts)`
  returns `[{GraphProjection, runtime_config?: true}]`; `child_specs(:late, opts)` returns
  `[{AdHocSource, …}, {PackStatus, …}]` reading the same `Application.get_env` keys.
  `ticket-context` gets `Aiur.TicketContext.child_specs/2` (PROPOSED module name only; file
  `src/lib/aiur/ticket_context.ex`) returning `TicketDetailCoordinator` (early) and
  `TicketHistoryProvider` (late). `aiur.ex` splices them at the same indices, so the
  resulting child list is **identical** element for element.
- **Declared optional edges:** `dashboard-ui → build-orders` (opt), `streamdeck-server →
  build-orders` (opt, `Metadata`), `github → build-orders` via `OpenTicketSource →
  AdHocSource` (allowlisted; see non-happy paths), `ticket-context → build-orders`
  (`TicketDetail` references `Aiur.BuildOrder.Lifecycle`; allowlisted, to be cut when
  ticket-context files are renamed — out of scope).

## Implementation steps

1. Add `build_order/component.ex` and `ticket_context.ex` (≈60 lines total).
2. Replace the five child tuples in `aiur.ex` with the four `child_specs/2` splices at
   the same positions (≈10 lines).
3. `components.json`: `build-orders` entry, new `ticket-context` entry (paths: the 15
   files from `git ls-tree -r 45a290e3 -- src/lib/aiur/build_order | grep -E 'ticket_(detail|history)'`
   plus `src/lib/aiur_web/build_order/ticket_context_*.ex`), dependency declarations,
   allowlist edits.
4. Run the checker; record counts.

## Non-happy paths

- **Child order drift:** the main risk. A child-list equality test (below) is the guard.
- **`OpenTicketSource` → `AdHocSource`** (`open_ticket_source.ex` references
  `Aiur.BuildOrder.AdHocSource`; at base the reference is in the moduledoc at `:44` —
  verify at head whether any code reference exists). If code-only-in-docs, no edge.
- **Build orders configured off in future:** not supported by this ticket; the
  `build_orders.progress` capability (MP-R1-C3) reports `unavailable` only once a
  disable path exists. No flag is added here.

## Compatibility and rollout

No config, data or behaviour change. Revert restores the literal tuples.

## Verification

- New `src/test/aiur/build_order/component_test.exs`:
  `test "application child list is unchanged by component child specs"` — compute
  `Aiur.Application.child_specs/1` for the default foreground opts and for
  `dashboard?: false`; assert the list equals a golden list of child ids captured from
  base `45a290e3` in the PR (stored inline in the test). **Mutation:** swap the order of
  `AdHocSource` and `PackStatus` inside `child_specs(:late, _)` → test fails.
- Existing suites green:
  `env -C src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/build_order test/aiur/build_orders_cli_test.exs test/aiur/build_orders_cli_first_read_test.exs test/aiur/build_orders_cli_stale_read_test.exs test/aiur_web/build_order test/aiur/github/view_state_sweep_test.exs test/aiur/build_order/component_test.exs`
  plus `test/aiur/application_test.exs`.
- Checker mutation: a scratch reference from `stream_deck_grid.ex` to
  `Aiur.BuildOrder.Graph` (private) → `check-components.py` fails.
- `make -C src fmt-check lint`; `python3 scripts/check-components.py`.
- Manual (AGENTS.md): foreground `scripts/aiurdev --test`; open `/build-orders`, a
  ticket dialog, and run `aiurdev build-orders` (verb at `aiur-engine.sh:463`); captures
  identical; `aiurdev status` shows the same supervision (no crash on boot).

## Completion and handoff

- [ ] `aiur.ex` names no `Aiur.BuildOrder.*` module directly; child list identical.
- [ ] `build-orders` and `ticket-context` manifest entries present; count ≤ baseline.
- **Docs:** none now. The component directory page (MP-R1-C10) will list
  `ticket-context`; DESIGN-R1 §3 decides whether it is shown separately.
- **Dependents:** MP-R1-C8-T9 (build-queue `BuildOrder` source references a declared
  facade); MP-E1-C7 / MP-N5 progress reads `RootSummary`/`ProgressRenderer`;
  component-map.md gains the `ticket-context` row (C11 refresh).
