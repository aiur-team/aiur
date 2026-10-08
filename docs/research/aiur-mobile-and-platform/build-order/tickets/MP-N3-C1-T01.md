---
ticket_id: MP-N3-C1-T01
feature_id: MP-N3
chunk_id: MP-N3-C1
bucket: 3-mobile-watch
title: "Aiur.InstanceSummary.v1/0 skeleton: Fact envelope, provider injection, size budget and redaction guard"
status: blocked
blocked_by: [DESIGN-N3, MP-R1-C2-T02, MP-R1-C3-T01]
prior_units: [U6]
prior_boundaries: [PRJ]
prior_features: [MP-R1, MP-N2]
prior_findings: []
size_owner: "n/a (new module; PRJ boundary owner per U8 ledger at implementation time)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C1-T01 — Instance summary skeleton and Fact envelope

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C1 "Instance summary provider".
- **User value:** the phone meta-dashboard can show one row per instance from a small, honest
  payload in which a missing value can never be read as zero.
- **Deliverable:** `Aiur.InstanceSummary` (PROPOSED `src/lib/aiur/instance_summary.ex`) with
  `v1/0` and `v1/1` (opts for injected providers), the `Fact` type, the top-level envelope, a
  4 KiB size guard and a redaction guard. Field providers return `unavailable` placeholders;
  C1-T02..T05 fill them.
- **Non-goals:** the gateway call (MP-N3-C2), any HTTP route (the summary is RPC-only), the
  phone rendering (MP-N3-C3/C4).

## Dependencies and blockers

- DESIGN-N3 (feature gate, MP-REQ2; this ticket has no UI).
- MP-R1-C2-T02 (the daemon knows its `instance_key` and composes `instance_id`, RC-02).
- MP-R1-C3-T01 (capability registry; the `capabilities` field is copied from it).
- Concurrent with: MP-N2-C1..C3, MP-N3-C3 (works from the contract and fixtures).
- Dependents: MP-N3-C1-T02..T05, MP-N3-C2-T01.

## Verified starting point (base `45a290e3`)

- No summary exists. `/api/v1/state` (`src/lib/aiur_web/presenter.ex:24-80`) returns the full fleet
  with ticket detail; it is too heavy for a per-row read (MP-N3 plan G4).
- The control RPC plane the gateway will use: `"$release_bin" rpc <expr>` with a watchdog
  (`run_release_rpc_with_timeout`, `packaging/npm/aiur-cli/libexec/aiur-engine.sh:2333-2387`);
  `aiur status` is `Aiur.AgentControlCLI.status()` (`src/lib/aiur/agent_control_cli.ex:100`).
- Value-free degraded precedent: `FinancialDataAccess.locked_capability/0`
  (`src/lib/aiur_web/financial_data_access.ex:143-152`).
- Contract: `contracts/pairing-and-instance-registry.md` §7 (Fact shape, field table, 4 KiB, no
  Command text, no ticket or build-order titles).

## Chosen design

```elixir
@type fact_status :: :available | :unavailable | :disabled | :unknown
@type fact :: %{status: fact_status, value: term() | nil, observed_at: String.t(),
                age_ms: non_neg_integer(), reason: String.t() | nil, freshness: :current | :stale | nil}

v1(opts \\ []) :: %{
  contract: "aiur.instance_summary", version: 1,
  instance_id: String.t() | nil, observed_at: String.t(),
  agents: %{active: fact, capacity: fact}, fleet: %{globally_paused: fact},
  commands: %{awaiting: fact, awaiting_blocking: fact},
  executor: fact, build_orders: fact, background_agents: fact, capabilities: fact }
```

- **Invariant 1:** `value` is present only when `status == :available`; a constructor
  `Fact.available(value, observed_at, opts)` and `Fact.unavailable(reason)` are the only
  builders, so no caller can create `%{status: :unavailable, value: 0}`.
- **Invariant 2:** every provider runs inside `safe/2` with a per-field budget (default 300 ms,
  total 1 500 ms, below the gateway's 2 s RPC timeout in MP-N3-C2). An exception, exit or
  timeout yields `Fact.unknown("provider_failed")` — a collapsed cause is `unknown`, never a
  specific cause (AGENTS.md).
- **Invariant 3:** after building, `byte_size(:erlang.term_to_binary(...))` is not the measure;
  the JSON encoding (`Jason.encode!/1`) must be ≤ 4 096 bytes. Over budget → `build_orders`
  is truncated first (keep the 3 most recently updated roots, add `truncated: true`), then
  the call raises in test and logs in prod.
- **Invariant 4 (redaction):** the encoder walks the map and rejects any key outside an
  allow-list (`contract, version, instance_id, observed_at, agents, fleet, commands, executor,
  build_orders, background_agents, capabilities, status, value, reason, age_ms, freshness,
  lower_bound, active, capacity, globally_paused, awaiting, awaiting_blocking, state, consumers,
  roots, identity, progress, resolution, truncated, count`). Unknown keys fail tests.
- Providers are injected by `opts[:providers]` so tests never read real state (AGENTS.md
  "Reading real state").
- `instance_id` nil (empty instance key, identity contract §1.2) → the summary still returns,
  with `instance_id: nil`, and the gateway reports it as `unknown`.

## Implementation steps

1. `src/lib/aiur/instance_summary.ex` and `src/lib/aiur/instance_summary/fact.ex` (PROPOSED).
2. Default providers return `Fact.unavailable("not_implemented")` until T02..T05.
3. `safe/2` with `Task.async` + `Task.yield/2` + `Task.shutdown(:brutal_kill)`.
4. Size and allow-list guards. About 150 production lines.

## Non-happy paths

Provider crash, timeout, nil instance id, oversize payload — each covered above. The summary
never mutates state (Invariant checked in C1-T04 for the roster).

## Compatibility and rollout

New module, RPC-only. An instance on an older release has no module; the gateway maps `undef`
to `unsupported` (MP-N3-C2-T01). Plan refresh: after MP-R1-C8 moves projections, the module
moves to the projections package (`PRJ`) unchanged.

## Verification

`src/test/aiur/instance_summary/fact_test.exs` and `src/test/aiur/instance_summary_test.exs`:

1. `"unavailable fact never carries a value"` (property over all builders). *Fails without:*
   the builder guard (mutation: let `unavailable/1` accept a value of 0).
2. `"a crashing provider yields unknown with reason provider_failed"`. *Fails without:* `safe/2`.
   Mutation: map the rescue to `:unavailable` with reason `"orchestrator_unavailable"` → the test
   asserting `:unknown` fails.
3. `"a slow provider is cut at its budget and the summary returns within 1.6 s"`.
4. `"encoded summary with 30 agents and 32 roots stays under 4096 bytes"`. *Fails without:* truncation.
5. `"unknown key in a provider result fails the allow-list"`. *Fails without:* the redaction walk.
6. `"nil instance id still returns a summary"`.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/instance_summary/fact_test.exs test/aiur/instance_summary_test.exs
```

## Completion and handoff

- [ ] Tests 1–6 pass; mutation checks recorded.
- [ ] Docs: none (internal RPC); the summary contract is `contracts/pairing-and-instance-registry.md` §7.
- [ ] Dependents: MP-N3-C1-T02..T05, MP-N3-C2-T01.
- [ ] Publish `packages/aiur-contracts/schemas/instance-summary.v1.schema.json` with a golden
      fixture (Phase D, MP-N1 request A3).
