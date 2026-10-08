---
ticket_id: MP-R1-C3-T01
feature_id: MP-R1
chunk_id: MP-R1-C3
bucket: 1-refactor (Bucket-2 enabling work, RC-12)
title: Capability registry - provider behaviour, crash-proof table, monitor, report assembly with boot_id and revision
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C2-T02]
prior_units: []
prior_boundaries: ["CLI #31 (child_specs composition)", "PRJ #28 (SnapshotStore freshness)"]
prior_features: [MP-N1, MP-N3]
prior_findings: []
size_owner: "src/lib/aiur.ex: U8 APP_BOOT (600 lines) — add ≤ 4 lines"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C3-T01 — Capability registry

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1 (RC-12 enabling), MP-R1, C3. Step S2. Contract
  §2.2, §2.4.
- **User value:** clients (dashboard JS, Stream Deck, phone, watch) learn what an
  instance can do from one report instead of guessing from missing fields and join
  errors (KD3; baseline R1). This ticket builds the engine; providers come in T02/T07.
- **Deliverable (all PROPOSED):**
  - `src/lib/aiur/capabilities.ex` — `Aiur.Capabilities.report/1` (pure read for HTTP
    and CLI) and `refresh/0` (cast).
  - `src/lib/aiur/capabilities/provider.ex` — behaviour (contract §2.4).
  - `src/lib/aiur/capabilities/table.ex` — never-crashing ETS owner.
  - `src/lib/aiur/capabilities/monitor.ex` — 2,000 ms tick, provider tasks, revision.
  - `src/lib/aiur/capabilities/identity_provider.ex` — the `identity` ID, from
    `Aiur.Identity.identity_capability/0` (C2-T02).
  - `config :aiur, :capability_providers, [Aiur.Capabilities.IdentityProvider]` in
    `src/config/config.exs`; two children in `child_specs/1`.
- **Non-goals:** any other provider (T02, T07), HTTP (T03), CLI (T04), event (T05), schema
  package (T06).

## Dependencies and blockers

- DESIGN-R1 §1; C2-T02. **Concurrent:** C3-T06 (schema) can be drafted in parallel from
  the contract. **Dependents:** T02–T07, MP-R1-C6-T03 (reports `run_shape` fields through
  this registry), MP-E1 (`build_queue` provider), MP-R2 (`events.export` provider),
  MP-N2 (`pairing`).

## Verified starting point (`45a290e3`)

- Supervisor strategy `:rest_for_one` (`aiur.ex:117-118`); children in dependency order.
  `Aiur.Webhooks.ModeTable` is placed first because it cannot crash and owns an ETS
  table whose loss would silently empty a view (`aiur.ex:275-296`, #2531). The same
  argument applies to the capability table: losing it would reset `revision`.
- `Aiur.Events.Publisher` child at `aiur.ex:374`; the monitor goes after it because T05
  publishes.
- `Aiur.Boot.run_id/0` (`boot.ex:92-98`): opaque, minted once per BEAM → `boot_id`.
- Typed absence precedent: `Presenter` returns `snapshot_unpublished` /
  `orchestrator_unavailable` (`presenter.ex:24-33`).
- `Aiur.TaskSupervisor` exists (`aiur.ex:321`) for provider tasks.

## Chosen design

- **Table** (`Aiur.Capabilities.Table`): `init/1` creates
  `:ets.new(:aiur_capabilities, [:named_table, :public, read_concurrency: true])` and
  does nothing else; no `handle_call`/`handle_cast`. Keys: `:report` →
  `{report_map, computed_at_ms, digest}`, `:revision` → integer (via
  `:ets.update_counter/4` with default `{:revision, 0}`).
- **Monitor** (`Aiur.Capabilities.Monitor`): on `:tick` and on `{:refresh}` cast,
  computes: context (`Aiur.Identity.instance_section/0` run shape + `Aiur.Config.settings/0`
  result or `:unavailable`), then per provider `Task.Supervisor.async_nolink` +
  `Task.yield(t, 500) || Task.shutdown(t, :brutal_kill)`. Merge rules:
  - a provider may return only IDs it lists in `capability_ids/0`; others are dropped
    and logged once;
  - duplicate ID across providers → both entries become `unknown` (collapsed cause) and
    a warning is logged;
  - failure/timeout → all its IDs `%{state: :unknown, reason: :unknown}`, sections nil.
  - known-but-absent IDs from the static table (`@known_ids`, contract §2.3) with no
    provider → `unavailable/not_installed`.
  Digest = `:erlang.phash2(capabilities)`; if different from stored digest →
  `update_counter(:revision, 1)` and (T05) publish. Then store the report.
- **Reader** `report/1`: read `:report`; compute `age_ms = now_ms − computed_at_ms`,
  `freshness = if age_ms <= 6_000, do: "current", else: "stale"`; add `boot_id`,
  `revision`, `contract`, `contract_version: 1`, `min_client_versions: %{}`
  (`@min_client_versions` module attribute), `observed_at` (ISO8601 from computed_at).
  No report yet → compute synchronously in the caller with `revision: 0`. Table missing
  (`ArgumentError` from `:ets.lookup`) → compute synchronously, `revision: 0`,
  `freshness: "stale"`.
- **Sections** `repository` and `executor` come from `sections/1` (T02 providers); in this
  ticket both are `nil`.
- **Layering:** `Aiur.Capabilities` references only `Aiur.Identity`, `Aiur.Boot`
  (kernel), `Aiur.Config` (config) and the provider list from application env. No
  reference to any provider module (R-down/R-optional clean).

## Implementation steps

1. Behaviour and table modules.
2. Monitor with injectable `:providers`, `:tick_ms`, `:now_fun` options (tests).
3. `report/1` with an injectable table name.
4. `child_specs/1`: add `Aiur.Capabilities.Table` immediately after
   `Aiur.Webhooks.ModeTable`, and `Aiur.Capabilities.Monitor` immediately after
   `Aiur.Events.Publisher`. Update `application_test.exs` expected-children assertions.
5. Config list with the identity provider.
6. Manifest: add files to `identity`.

## Non-happy paths

| Case | Behaviour |
|---|---|
| Provider hangs | killed at 500 ms; its IDs `unknown`; next tick retries |
| Provider raises | same; one log line per provider per state change, not per tick |
| Monitor crash loop | table keeps last report; `freshness` turns `stale` after 6 s |
| Config unreadable | context `settings: :unavailable`; providers must report `unknown` for config-dependent IDs |
| Many concurrent readers | ETS `read_concurrency`; no GenServer call on the read path |
| Clock | `computed_at_ms` monotonic for age; `observed_at` wall clock for display |

## Compatibility and rollout

Two new children; no behaviour change elsewhere. Supervision-order change is the risk:
`SupervisionHealth` receives the expected children (`aiur.ex:108,487-489`), so the expected
list is derived from `children` and updates automatically. Rollback: revert.

## Verification

PROPOSED `src/test/aiur/capabilities_test.exs` (monitor started per test with
`start_supervised!/1`, unique table names):

| Test | Expected |
|---|---|
| `revision increments only when a capability state changes` | flip fake provider → revision +1; unchanged tick → same |
| `revision survives monitor restart` | kill monitor; restart; revision not lower |
| `hung provider becomes unknown within budget` | provider sleeps 5 s → its IDs `unknown`, others intact, tick < 1 s |
| `raising provider becomes unknown` | same |
| `undeclared id from a provider is dropped` | not in report |
| `duplicate id across providers is unknown` | `%{state: :unknown, reason: :unknown}` |
| `known id without provider is not_installed` | `unavailable/not_installed` |
| `age and freshness are computed at read time` | `now_fun` advanced 7 s → `stale`, `age_ms ≥ 7000` |
| `boot_id equals Aiur.Boot.run_id` | equal |
| `no report yet computes synchronously with revision 0` | `revision: 0` |

Plus `application_test.exs`: `child_specs/1` places `Capabilities.Table` directly after
`Webhooks.ModeTable` and `Capabilities.Monitor` after `Events.Publisher` in every run
shape (interactive, headless, no-dashboard).

Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/capabilities_test.exs test/aiur/application_test.exs`.

Mutation check: bump revision on every tick → first test fails; store revision in the
monitor state instead of ETS → second fails; replace the timeout branch with
`available` → third fails (unknown-path rule); compute freshness at store time instead
of read time → eighth fails.

## Completion and handoff

- [ ] Registry merged; all tests fail under their mutations.
- [ ] No operator surface yet (no docs). The concepts page ships with T03.
- **Dependents:** C3-T02..T07, MP-R1-C6-T03, MP-E1, MP-R2, MP-N2, MP-R7 provider tickets.
