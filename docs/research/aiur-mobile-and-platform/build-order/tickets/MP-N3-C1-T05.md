---
ticket_id: MP-N3-C1-T05
feature_id: MP-N3
chunk_id: MP-N3-C1
bucket: 3-mobile-watch
title: "Summary fields build_orders, background_agents and capabilities"
status: blocked
blocked_by: [DESIGN-N3, MP-N3-C1-T01, MP-R1-C3-T02, MP-E1-C7-T01]
prior_units: []
prior_boundaries: [PRJ, BO]
prior_features: [MP-R1, MP-E1, MP-E3]
prior_findings: [RC-10]
size_owner: "n/a (new provider module)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C1-T05 — Build-order progress, background agents, capabilities

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C1.
- **User value:** the row shows build-order progress only where build orders exist, never a fake
  0%, and the phone knows which optional parts the instance has.
- **Deliverable:** providers for `build_orders` (list of open roots `{identity, progress,
  resolution}`, **no titles**), `background_agents` (`unavailable` until MP-E3) and
  `capabilities` (copied from the MP-R1 capability registry).
- **Non-goals:** choosing which root the phone shows (DESIGN-N3 Q3); progress notifications (MP-N5).

## Dependencies and blockers

- DESIGN-N3; MP-N3-C1-T01; MP-R1-C3-T02 (component capability callbacks, incl. `build_orders`,
  `build_orders.progress`).
- MP-E1-C7-T01 (RC-10: progress read API). When it lands, read progress from it; until then read
  `GraphProjection.catalog/1` directly (contract §7 RC-6 note).
- MP-E3-C4-T02 supplies the background-agent roster later; this ticket ships the `unavailable`
  placeholder and the seam.

## Verified starting point (base `45a290e3`)

- `GraphProjection.catalog/1` is a `GenServer.call` (`src/lib/aiur/build_order/graph_projection.ex:43-44`).
  Its handler reconciles in process (`:141-145`); upstream reads run as supervised tasks
  (`:850`, `:1764`), so the call does not wait on GitHub. **RQ-N3-2 resolved:** cost is one call
  into the projection mailbox; the provider uses a 300 ms timeout and catches the exit.
- The projection is always started (`src/lib/aiur.ex:357`) and "Restart deliberately begins
  unavailable" (`graph_projection.ex:5-7`). So "disabled" cannot be derived from process presence:
  it comes from the capability report (`build_orders` state `unavailable`, MP-R1
  capability-matrix.md row `build_orders`).
- Snapshot shape: `%Snapshot{data: Catalog.t() | nil, health: ProviderHealth.t()}`
  (`graph_projection_contract.ex:17-38`); `Catalog` has `entries` (`build_order/catalog.ex:36`).
- `RootSummary` fields: `identity`, `title`, `progress` (0–100 or nil), `progress_resolution`
  (`:resolved | :partial | :unresolved | :unknown`), `completed?`, `updated_at`
  (`build_order/root_summary.ex:6-40`).
- No background-agent source exists (MP-N3 plan G7).

## Chosen design

`build_orders`:

| Condition | Fact |
|---|---|
| capability `build_orders` not `available` | `disabled`, reason = capability reason |
| catalog call times out or exits | `unknown`, reason `"projection_unresponsive"` |
| `data == nil` (unloaded after restart) | `unavailable`, reason `"loading"` |
| otherwise | `available`, value `%{roots: [...], count: n}` with non-completed roots sorted by `updated_at` desc, each `{identity: number, progress: int or nil, resolution}` |

A root with `progress: nil` keeps `nil` (rendered "—"), never 0. Titles are never copied
(contract §7 privacy rule).

`background_agents`: `unavailable`, reason `"capability_not_provided"` unless the capability
report lists an MP-E3 background-agent capability, in which case the injected E3 reader is used.
**Phase D (CR-N3-3):** the capability ID is `executor.background_agents` and the reader is
`Aiur.Executor.BackgroundAgents.snapshot/0` (MP-E3-C4-T02); its `:unsupported` result maps to
`unavailable` with the harness reason, never to zero.

`capabilities`: `available` with the report's `{id => %{state, reason}}` map, trimmed to `state`
and `reason`; the registry's own `revision` and `boot_id` go in the value too.

## Implementation steps

1. `src/lib/aiur/instance_summary/build_orders.ex`, `.../capabilities.ex`,
   `.../background_agents.ex` (PROPOSED), each with an injected source function.
2. About 120 lines.

## Non-happy paths

Restart (loading), slow projection, partial resolution (passed through), capability report
absent (`unknown`), more than 32 roots (bounded by `graph_max_selected_roots`,
`config/schema/build_order.ex:39`, and by T01's truncation).

## Compatibility and rollout

Read-only. After MP-E1-C7 the source swaps without a payload change.

## Verification

`src/test/aiur/instance_summary/build_orders_test.exs` and `capabilities_test.exs`:

1. `"no build-order capability yields disabled"`. Mutation: return `available` with `[]` → fails.
2. `"unloaded projection yields unavailable loading"`.
3. `"catalog timeout yields unknown"` (fake that sleeps past 300 ms).
4. `"nil progress stays nil"`. Mutation: `progress || 0` → fails.
5. `"completed roots are excluded and order is updated_at desc"`.
6. `"no title key appears in the build_orders value"`. *Fails without:* the field projection.
7. `"background agents unavailable with capability_not_provided"`.
8. `"capabilities copy state and reason only"`.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/instance_summary/build_orders_test.exs test/aiur/instance_summary/capabilities_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation checks recorded. Docs: none. Dependents: MP-N3-C2-T01, MP-N5 (reads
      the same progress source), MP-N7 list.
