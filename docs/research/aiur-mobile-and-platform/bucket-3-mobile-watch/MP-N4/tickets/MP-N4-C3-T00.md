---
ticket_id: MP-N4-C3-T00
feature_id: MP-N4
chunk_id: MP-N4-C3
bucket: 3-mobile-watch
title: Post-refactor path refresh for the daemon push-relay component
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-R1 component map landed (R1-C1), MP-R2-C5, MP-R2-C6]
prior_units: [U0–U9 as landed by MP-R1]
prior_boundaries: [EXE #26, DEC #27, BO #30, new #41 candidate push-relay]
prior_features: [MP-R1, MP-R2]
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C3-T00 — Plan refresh after MP-R1/MP-R2

## Identity and outcome

Bucket 3, MP-N4, chunk C3. A documentation-only ticket: before any daemon push code is
written, map every pre-refactor path and module named in the MP-N4 tickets to its
post-refactor location, and record the mapping in MP-N4 `plan.md` §12 and in each
affected ticket's "Verified starting point". Output is a PR that edits only the research
docs (or the in-repo plan if the pack has been promoted by then).

## Dependencies and blockers

- MP-R1 component map and dependency checker (R1-C1) landed; MP-R2 catalog (C5) and
  export journal / DurableConsumer (C6) landed or explicitly deferred.
- Everything in MP-N4-C1-T01..T04 and C3-T01..T07 cites this ticket first.

## Verified starting point

Pre-refactor names to map:

| Pre-refactor (`45a290e3`) | Used by |
| --- | --- |
| `Aiur.DecisionStore` (`src/lib/aiur/decision_store.ex:154,190,388,393`) | C3-T02 boot reconciliation (with MP-N5), N6 |
| `Aiur.Events.Exchange.subscribe/2` (`events/exchange.ex:70`), `Aiur.Events.Publisher` (`events/publisher.ex:57,113`) | MP-N5 Source adapter |
| `Aiur.Config.Paths.runtime_state_dir/0` (`config/paths.ex:243`) | C3-T02 outbox location |
| `Aiur.HttpServer.base_url/0` (`http_server.ex:143`) | none in N4 (reachability is MP-N2's) |
| `Aiur.AgentControlCli.status/1` (`agent_control_cli.ex:100`), `cmd_status` (`aiur-engine.sh:2612`) | C3-T07 status line |
| `src/lib/aiur/push/**` (PROPOSED) | all daemon tickets |

## Chosen design

Mapping rules: daemon push code goes into the `push-relay` package named by MP-R1
(`component-map.md:126`); it may depend only on the edges listed there
(identity, pairing-discovery, event-bus, commands; optional build-orders). Any extra edge
found while mapping becomes a CONTRACT-REQUEST to MP-R1, not an import.

## Implementation steps

1. Read the landed component map and package list.
2. Replace each pre-refactor path in MP-N4 tickets with the package path; keep the
   old path in parentheses for traceability.
3. Run the MP-R1 dependency checker's rule list against the planned imports of
   C3-T02/T03 and record the result.

## Non-happy paths

- MP-R2-C6 deferred: C3 and MP-N5 run in live-subscription mode (MP-N5 PC-7); record that.
- Component map forbids an edge N4 needs: stop and file the request; do not code around.

## Compatibility and rollout

n/a — documentation only.

## Verification

Review checklist: every `src/lib/aiur/...` path in MP-N4 tickets either exists at the
refresh SHA or is marked PROPOSED with its package; the dependency checker passes for the
planned imports (command per MP-R1, recorded in the PR).

## Completion and handoff

- [ ] Mapping table committed; affected tickets updated.
- Dependents: MP-N4-C1-T01 and all C3 tickets.
