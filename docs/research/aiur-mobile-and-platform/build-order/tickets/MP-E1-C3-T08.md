---
ticket_id: MP-E1-C3-T08
feature_id: MP-E1
chunk_id: MP-E1-C3
bucket: 2-platform
title: Capability provider for build_queue and build_queue.build_order_source
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C3-T03, MP-R1-C3-T01]
wave: 1  # Phase D inversion rule: waits on MP-R1-C3-T01 (wave 1); the rest of MP-E1 stays wave 0
prior_units: [U3]
prior_boundaries: [BO #30]
prior_features: [MP-R1, MP-N3, MP-N5]
prior_findings: [X-21, RC-11, CR-N5-5]
size_owner: "new file; one line in src/config/config.exs (composition root); provisional, RC-23"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C3-T08 — Capability provider for `build_queue`

> **Plan refresh.** MP-E1 is wave 0, but this ticket needs the capability
> registry of MP-R1-C3-T01, so it is recorded as **wave 1** (inversion rule,
> graph-check.md) and merges after C3-T01. Nothing in wave 0 depends on it. Until
> then clients see `build_queue` as `unavailable/not_installed` from the static
> known-ID table (identity contract §2.4), never as a missing field.

## Identity and outcome

- Bucket 2, MP-E1, C3, T08. Closes Phase D finding X-21 for the queue.
- **User value:** the dashboard, phone and watch can tell "no queue in this build",
  "queue turned off", "tracker cannot run a queue", "queue store lost" and "queue
  writes paused by the GitHub budget" apart, instead of rendering every one of
  them as `unknown`.
- **Deliverable:** PROPOSED `src/lib/aiur/build_queue/capability_provider.ex`
  (`Aiur.BuildQueue.CapabilityProvider`, implementing `Aiur.Capabilities.Provider`)
  and one entry in `config :aiur, :capability_providers` (`src/config/config.exs`).
- **Non-goals:** the `build_orders` ID (build-orders component, MP-R1-C3-T02);
  progress gating in MP-N5 (RC-40: build-order notifications gate on
  `build_orders`, queue notifications on `build_queue`).

## Dependencies and blockers

- DESIGN-E1 (gate, as every MP-E1 ticket).
- MP-E1-C3-T03: `Aiur.BuildQueue.status/0` and the selected `DependencySource`.
- MP-R1-C3-T01: the `Aiur.Capabilities.Provider` behaviour, the monitor and the
  registry. Identity contract §2.2 lists the reasons `store_unavailable` and
  `writes_paused` (registered in Phase D for this provider).

## Verified starting point (`45a290e3`)

- No capability registry exists at base; the behaviour, the 500 ms provider
  budget and the provider list in application config are defined in
  `contracts/identity-and-capabilities.md` §2.4 and shipped by MP-R1-C3-T01.
- `Aiur.BuildQueue.status/0` returns
  `:running | :disabled | :unsupported_tracker | :store_unavailable | :writes_paused`
  (MP-E1-C3-T03, PROPOSED).
- The dependency source is chosen at runtime: `BuildOrder` when capability
  `build_orders` is available, else `ExecutorList` only (component map §4,
  MP-E1-C4-T02).

## Chosen design

- `capability_ids/0` → `["build_queue", "build_queue.build_order_source"]`.
- `capabilities(context)` reads `Aiur.BuildQueue.status/0` (ETS-backed read; no
  GenServer call, so the 500 ms budget is never at risk) and maps:

  | `status/0` | `build_queue` |
  | --- | --- |
  | `:running` | `available` |
  | `:disabled` (or no child: `build_queue.enabled: false`) | `unavailable` / `disabled` |
  | `:unsupported_tracker` | `unavailable` / `unsupported_tracker` |
  | `:store_unavailable` | `unavailable` / `store_unavailable` |
  | `:writes_paused` | `degraded` / `writes_paused` |
  | any other value, raise or exit | `unknown` / `unknown` (never a specific cause) |

- `build_queue.build_order_source`:
  - `build_queue` not `available` or `degraded` → `unavailable` /
    `dependency_unavailable`, `depends_on: ["build_queue"]`;
  - BuildOrder source selected → `available`;
  - otherwise (`build_orders` not available) → `unavailable` /
    `dependency_unavailable`, `depends_on: ["build_orders"]`.
- The provider references only `Aiur.BuildQueue` (its own facade) and the
  capability behaviour. It never reads `Orchestrator.State` (seam rule, C1-T07).

## Implementation steps

1. `capability_provider.ex` with the two callbacks and the mapping table as one
   `case`.
2. Register it in `config :aiur, :capability_providers`.
3. Extend the C1-T07 source-scan allowlist only if needed: the provider must not
   reference `Aiur.Orchestrator` or `Aiur.GitHub.*`.
4. Tests below.

## Non-happy paths

- Queue child not started (disabled run) → `Aiur.BuildQueue.status/0` answers
  `:disabled` from the facade without a process; mapped to `unavailable/disabled`.
- Status read raises → `unknown/unknown` for both IDs (collapsed cause names the
  collapse, AGENTS.md).
- Registry absent (build before MP-R1-C3-T01) → this module is not compiled into
  the provider list; nothing else changes.

## Compatibility and rollout

Additive: two IDs in the capability report. No config key, no wire change for
existing clients (unknown IDs are ignored, identity §3 rule 2). Rollback: remove
the provider line; clients then see `unavailable/not_installed`.

## Verification

| Test (`src/test/aiur/build_queue/capability_provider_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "each status maps to its state and reason" — table test over the five statuses | exact `{state, reason}` per row above | the mapping `case` |
| "writes_paused is degraded, not unavailable" | `%{"state" => "degraded", "reason" => "writes_paused"}` | the paused row |
| "an unrecognised status is unknown/unknown" — status stub returns `:weird` | `unknown`/`unknown` | the fallback clause (replace it with `:disabled` and the test fails) |
| "source depends on build_orders when no BuildOrder source" | `depends_on == ["build_orders"]` | the source clause |
| "source depends on build_queue when the queue is unavailable" | `depends_on == ["build_queue"]` | the ordering of the source clauses |

Mutation check: revert the provider hunk in a worktree (`git status --porcelain`
shows only that revert) and run the file; every test fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/capability_provider_test.exs
```

## Completion and handoff

- [ ] Provider registered; both IDs reported in every run shape with the bus.
- Docs: `website/docs-app/concepts/` capability page (owned by MP-R1-C3) gains the
  two IDs and their reasons; `reference/cli.md` `aiur capabilities` example
  unchanged.
- Dependents: MP-N3 (queue tile), MP-N5 (queue progress options), MP-E1-C8-T01.
