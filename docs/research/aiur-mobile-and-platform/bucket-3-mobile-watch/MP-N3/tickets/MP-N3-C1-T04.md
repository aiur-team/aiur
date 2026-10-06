---
ticket_id: MP-N3-C1-T04
feature_id: MP-N3
chunk_id: MP-N3-C1
bucket: 3-mobile-watch
title: "Summary field executor: aggregate roster state without recording an observation"
status: blocked
blocked_by: [DESIGN-N3, MP-N3-C1-T01, MP-R1-C3-T02]
prior_units: []
prior_boundaries: [PRJ, EXE]
prior_features: [MP-R1, MP-E3]
prior_findings: []
size_owner: "n/a (new provider module)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C1-T04 — Executor state fact

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C1.
- **User value:** each phone row tells whether the instance's Executor is working, idle, stalled
  or gone; a stalled consumer is listed and labelled per consumer, while one idle consumer
  keeps the Executor live (RC-37, D9).
- **Deliverable:** provider `Aiur.InstanceSummary.Executor.fact/1` (PROPOSED) returning
  `executor` = Fact with value `%{state, live, consumers}` (`live: true` for `active|idle`
  only).
- **Non-goals:** Executor harness, chat or background agents (MP-E3; `background_agents` is T05).

## Dependencies and blockers

- DESIGN-N3; MP-N3-C1-T01.
- MP-R1-C3-T02 (core providers: the `executor` section and its state projection incl. `absent`;
  MP-R1-C2 has no T04). If R1-C3-T02 exposes a
  projection function, use it; this ticket's aggregation must then equal R1's state vocabulary
  (`identity-and-capabilities.md` §1.4: `active, idle, stalled, expired, absent, unknown`).
- Concurrent with C1-T02, T03, T05.

## Verified starting point (base `45a290e3`)

- `Aiur.Executor.Roster.build/1` (`src/lib/aiur/executor/roster.ex:43-67`) builds entries and, by
  default, records an observation (`:62-64`); `record?: false` inspects "without disturbing it"
  (`:45-48`). Per-consumer state rules: `expired` when the claim is not live, `active` when this
  consumer consumed, `stalled`, `idle` (`:118-122`), else `unknown` (moduledoc `:11-22`).
- Multiple Executors are supported (`:6-9`).
- Tests: `src/test/aiur/executor/roster_test.exs`.

## Chosen design

Aggregation (MP-N3 plan §3, contract §7), evaluated in order:

1. no entries → `absent` (the MP-R1 §1.4 term; contract §7 was changed from `none` to `absent` on 2026-10-06);
2. any `active` → `active`; 3. any `idle` → `idle`; 4. any `stalled` → `stalled`;
5. any `expired` → `expired`; 6. otherwise → `unknown`. This is the pairing contract §7 /
identity §1.4 order `active > idle > stalled > expired > absent > unknown` (RC-37). A stalled
consumer is shown in the per-consumer list and labelled, but one idle consumer keeps the
Executor live (D9 routing, command contract §4); `live` is `true` for `active|idle` only.

`consumers` is the count of entries. The provider always calls `Roster.build(record?: false)`
and never any function that writes `Claims` observations. A crash → Fact `unknown`.

## Implementation steps

1. `src/lib/aiur/instance_summary/executor.ex` (PROPOSED); `roster_fun` injectable, default
   `fn -> Aiur.Executor.Roster.build(record?: false) end`. About 50 lines.

## Non-happy paths

Claims file unreadable (roster returns entries with `unknown` → aggregate `unknown`); roster
crash (`unknown`); two consumers active + stalled → `active` per the rule (the stalled one is
still visible on the dashboard; DESIGN-N3 may ask to surface "1 stalled" later).

## Compatibility and rollout

Read-only; must not change roster evidence.

## Verification

`src/test/aiur/instance_summary/executor_test.exs`:

1. Table test over entry-state lists → aggregate (`[] → absent` (not `none`),
   `[idle, stalled] → idle, live: true`, `[stalled] → stalled, live: false`,
   `[active, stalled] → active`, `[expired] → expired`, `[unknown] → unknown`). Mutation: put
   `stalled` before `idle` (the pre-RC-37 order) → the `[idle, stalled]` row fails; drop rule 3
   → a row fails.
2. `"summary read does not record a roster observation"`: real `Roster.build` with a temp claims
   `path`; read the observation file's bytes, call the provider, assert identical bytes.
   *Fails without:* `record?: false` (mutation: call `Roster.build()` with defaults).
3. `"roster crash yields unknown"`.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/instance_summary/executor_test.exs test/aiur/executor/roster_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation checks recorded. Docs: none. Dependents: MP-N3-C2-T01, MP-N7 list.
