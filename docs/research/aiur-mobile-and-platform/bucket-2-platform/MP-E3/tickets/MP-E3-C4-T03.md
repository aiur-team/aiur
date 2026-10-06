---
ticket_id: MP-E3-C4-T03
feature_id: MP-E3
chunk_id: MP-E3-C4
bucket: 2-platform
title: "Executor blockers: Executor Commands, open asks and fleet blockers, with per-source availability"
status: blocked
blocked_by: [DESIGN-E3, MP-E2-C1-T01, MP-E2-C6-T01, MP-E2-C6-T03]
prior_units: [U3]
prior_boundaries: [EXE, DEC]
prior_features: [MP-E2 (Executor-originated Commands, D12)]
prior_findings: [DESIGN-E3 decision 7 (blockers scope); AGENTS.md collapsed-cause rule]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C4-T03 — Executor blockers

## Identity and outcome

- Bucket 2 · MP-E3 · C4 · T03.
- **User value:** one list of what the Executor is waiting on the operator for,
  and an honest "unavailable" when a source cannot be read — never an empty list
  that hides a failure.
- **Deliverable:** `Aiur.Executor.Blockers.snapshot/0 :: %{items: [item],
  sources: %{commands: :ok | {:unavailable, reason}, asks: …, fleet: …},
  observed_at}`; item = `%{kind: :command | :ask | :fleet, id, title, age_ms,
  link}`.
- **Non-goals:** answering (MP-E4-C6-T02 card; Commands inbox).

## Dependencies and blockers

- DESIGN-E3 decision 7 (include fleet blockers or not).
- MP-E2-C6-T01 (`aiur command request`: Executor-originated Commands) and
  MP-E2-C6-T03 (`aiur ask` becomes an alias that raises a Command). Before
  E2-C6-T03 lands, open asks come from `Aiur.Asks.open/1`.

## Verified starting point

- Asks store: `Aiur.Asks.open(repo) :: {:ok, [ask]} | {:error, term}`
  (`src/lib/aiur/asks.ex:59-70`); no dashboard view (baseline E2).
- Fleet blocker topics the Executor binds by default:
  `system.tracker.auth_preflight_failed`, `system.github.connectivity_lost`,
  `system.fleet.capacity.starved`, … (`executor_bindings.ex:9-22`).
- Active system attention check: `Aiur.AlertFeed.active_system_attention?/2`
  (`alert_feed.ex:64-65`); list: `AlertFeed.list/1` (`:15-16`).

## Chosen design

- **Commands source:** DecisionStore open Commands with `origin` /
  `requester` marking Executor origin (field names per MP-E2-C1-T01), oldest
  first; link `/commands/:decision_id`.
- **Asks source:** `Asks.open(Paths.repo_name())` until MP-E2-C6-T03 ships; after
  it, asks are Commands and this source reads nothing new (kept for legacy
  `ask_` records, which E2 keeps readable).
- **Fleet source** (only if decision 7 says yes): `AlertFeed.list/1` filtered to
  open `needs_attention` alerts whose topic matches `ExecutorBindings.patterns/0`
  with prefix `system.`.
- Each source runs under a 2 s timeout; failure → `{:unavailable, reason}` for
  that source and its items absent; the UI must show "unavailable", not zero.

## Implementation steps

1. Three source functions + `snapshot/0` with `Task.async_stream` timeouts.
2. Add to the status snapshot (C4-T05).

## Non-happy paths

- DecisionStore down → `commands: {:unavailable, :decision_store_down}`.
- Asks file locked/corrupt → `asks: {:unavailable, reason}`.
- All sources empty and ok → `items: []` (true empty).

## Compatibility and rollout

- Read-only projection. Rollback: revert.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur/executor/blockers_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "one failing source is unavailable, others still listed" | `sources.asks = {:unavailable, _}`, commands listed | per-source isolation (mutation: render `[]` fails) |
| "all ok and empty → items [] with all sources :ok" | distinct from unavailable | source map |
| "fleet source off when decision 7 = no" | key absent | config pin |
| "Executor Command appears with link" | item with `/commands/…` | commands source |

## Completion and handoff

- Dependents: MP-E3-C4-T05, MP-E3-C6-T03.
