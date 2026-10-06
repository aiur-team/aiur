---
ticket_id: MP-N3-C1-T03
feature_id: MP-N3
chunk_id: MP-N3-C1
bucket: 3-mobile-watch
title: "Summary fields commands.awaiting and commands.awaiting_blocking with partial and unavailable health"
status: blocked
blocked_by: [DESIGN-N3, MP-N3-C1-T01, MP-E2-C7-T1]
prior_units: [U6]
prior_boundaries: [PRJ, DEC]
prior_features: [MP-E2]
prior_findings: []
size_owner: "n/a (new provider module; DecisionQuery is read only)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C1-T03 — Commands-awaiting facts

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C1.
- **User value:** each phone row shows how many Commands are waiting for the human on that
  instance, with the same number and meaning as the instance dashboard banner ("N units
  awaiting commands"), "≥ N" when the count is partial, and an explicit unavailable state.
- **Deliverable:** provider `Aiur.InstanceSummary.Commands.facts/1` (PROPOSED).
- **Non-goals:** Command text or a combined inbox (forbidden, brief §3); answering.

## Dependencies and blockers

- DESIGN-N3; MP-N3-C1-T01.
- **MP-E2-C7-T1** (RQ-N3-3 resolution): E2 redefines the overview banner counts per DESIGN-E2 §6.2
  ("Needs you / With Executor / From Executor"). The summary must report the same "needs you"
  number the dashboard banner shows after E2. Until E2-C7-T1 lands, the definition is today's
  `awaiting = open - deferred` (`decision_store/retained_index.ex:86-93`). This ticket takes
  whatever public count function E2-C7-T1 exposes; if E2 keeps `awaiting`, the dependency is a
  no-op check.
- Concurrent with C1-T02, T04, T05.

## Verified starting point (base `45a290e3`)

- `Aiur.DecisionQuery.counts/1` (`src/lib/aiur/decision_query.ex:76-96`) returns
  `{:ok, %{open, blocking, total, awaiting, awaiting_blocking, deferred, scope, health}}`; on
  `:store_unavailable` every count is `nil` with `StoreReader.unavailable_health()` (`:83-94`).
- `StoreReader.read_counts/1` (`decision_query/store_reader.ex:52-61`) wraps
  `DecisionStore.retained_counts/1` in `safe_store_call`.
- Dashboard wording and states: "N units awaiting commands", aria "Commands awaiting you",
  "Command counts unavailable.", "Partial Command counts. Counts are at least this high."
  (`src/lib/aiur_web/components/operator_control_center/overview.ex:53,65,79-89,168-169`).
- Existing tests: `src/test/aiur/decision_query_test.exs`.

## Chosen design

| `counts/1` result | `commands.awaiting` |
|---|---|
| integers, `health.status == :ok` (or equivalent complete) | `available`, value |
| integers, `health.status == :partial` | `available`, value, `lower_bound: true` |
| `nil` counts (store unavailable) | `unavailable`, reason `"store_unavailable"` |
| crash or unexpected shape | `unknown` |

Same rule for `awaiting_blocking`. The health status atom names are read from
`StoreReader.health/1` at implementation; any status other than complete/partial/unavailable
maps to `unknown` (never to a specific cause).

## Implementation steps

1. `src/lib/aiur/instance_summary/commands.ex` (PROPOSED); `counts_fun` injectable.
2. After E2-C7-T1, point `counts_fun` at E2's "needs you" count. About 60 lines.

## Non-happy paths

Store unavailable, partial health, unknown health status, crash. A deferred-to-Executor Command
is not counted (dashboard semantics, MP-N3 plan G1).

## Compatibility and rollout

Read-only. Field names stay stable across the E2 change (contract §7).

## Verification

`src/test/aiur/instance_summary/commands_test.exs`:

1. `"complete counts map to available values"`.
2. `"partial health sets lower_bound"`. *Fails without:* the partial clause (mutation: drop `lower_bound`).
3. `"nil counts map to unavailable store_unavailable, never 0"`. Mutation: `nil -> 0` → fails.
4. `"unknown health status maps to unknown"`.
5. `"a deferred command does not increase awaiting"` — uses a real `DecisionStore` started with a
   temp store path (pattern from `decision_query_test.exs`), records one open and one deferred
   Command, asserts `awaiting == 1`. *Fails without:* reading `awaiting` (a mutation reading
   `open` fails it).

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/instance_summary/commands_test.exs test/aiur/decision_query_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation checks recorded. Docs: none (internal).
- [ ] Dependents: MP-N3-C2-T01; MP-N3-C3-T01 renders "≥ N".
