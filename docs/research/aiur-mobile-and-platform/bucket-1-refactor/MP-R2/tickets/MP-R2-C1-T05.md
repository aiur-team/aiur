---
ticket_id: MP-R2-C1-T05
feature_id: MP-R2
chunk_id: MP-R2-C1
bucket: 1 (refactor)
title: Enforce the placement rule — topic prefixes and the Exchange-to-PubSub bridge allowlist
status: ready
blocked_by: [DESIGN-R2 §1]
prior_units: [U3, U7]
prior_boundaries: [BUS #10, signal port #11, PRJ #28, DEC #27]
prior_features: []
prior_findings: []
size_owner: n/a (test-only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C1-T05 — Placement-rule test (plan AC5)

## Identity and outcome

- **Bucket 1, MP-R2, C1, T05.**
- **Value.** Contract §2 rules R-1..R-5 and §9 (frozen grammar) are only words
  until a test fails on a violation. This adds a source-scan test that fails when a
  new Exchange topic literal leaves the `ticket.|system.|executor.` grammar, or when
  a new module both subscribes to the Exchange and broadcasts PubSub.
- **Deliverable.** `src/test/aiur/events/placement_rule_test.exs` (PROPOSED).
- **Non-goals.** Renaming the non-conforming topics found below (a rename is a
  breaking change, DESIGN-R2 §1 second box). No production change.

## Dependencies and blockers

- DESIGN-R2 §1. Concurrent with other C1 tickets.
- The known violations are reported to the coordinator in
  `MP-R2/tickets/CONTRACT-REQUESTS.md` (written by the feature owner) for the
  signal-port owner (MP-R1-C5).

## Verified starting point (45a290e3)

- Contract topic grammar: `website/docs-app/concepts/message-bus.md:5-14`.
- `Aiur.Alerts` publishes **every** alert name to the Exchange as its topic,
  matched alert definition or not (`src/lib/aiur/alerts.ex:144-152,293-313`).
- **New finding (multi-line literal scan at base):** seven alert names reach the
  Exchange outside the grammar:
  `decision_store.ex:684` `decision_store.unrecognized_event_types`,
  `decision_store.ex:706` `decision_store.corrupted`,
  `decision_store.ex:742` `decision_store.repair_failed`,
  `executor_events.ex:435` `executor_events.corrupted`,
  `github/dispatch_authorization.ex:740` `github.dispatch_authorization.ambiguous`,
  `github/dispatch_authorization.ex:755` `github.dispatch_authorization.timeline_unreadable`,
  `orchestrator/retry_engine.ex:1115` `orchestrator.claim_released`.
  They are routed and delivered like any event (no subscriber pattern matches them
  today except `#`-style debug), so contract §9 "grammar is frozen" is already
  violated by these seven.
- Exchange subscribers at base (files containing `Exchange.subscribe` or an
  `exchange_subscribe_fun` default): `build_order/ticket_history_provider_options.ex:37`,
  `decision_metrics.ex:64`, `events/subscription_store.ex:304,564,671`,
  `executor_events.ex:127`, `executor_listener.ex:116`, `orchestrator/lifecycle.ex:410`,
  `run_telemetry/writer.ex:412`, `ticket_activity.ex:73`.
- Of those, the modules that also broadcast PubSub (the bridges, R-4) are exactly
  `Aiur.TicketActivity` (`ticket_activity.ex`), `Aiur.BuildOrder.TicketHistoryProvider`
  (`build_order/ticket_history_provider.ex:557-560`) and `Aiur.DecisionMetrics`.
  `DecisionStore` and `Alerts` are dual *writers* (publish to both), not bridges.
  `SubscriptionStore` broadcasts only indirectly through `DebugLog`
  (`events/debug_log.ex:68-104`), which C2-T05 moves behind a sink.

## Chosen design

A pure source-scan ExUnit test (no app processes), reading `lib/**/*.ex` from the
`src/` working directory:

1. **Topic literal rule.** Regex over each file with comments and heredoc docs
   stripped, multi-line aware:
   `(emit_custom|emit_system|Publisher\.publish(?:_persisted)?|ExecutorEvents\.publish|Exchange\.publish)\(\s*"([^"#]+)"`.
   Every captured literal must match `^(ticket|system|executor)\.`, except an
   explicit `@known_violations` list of the seven `{file, topic}` pairs above.
   The test also fails if a listed violation no longer exists (ratchet: the list
   only shrinks).
2. **Bridge rule.** A file is a subscriber if it contains `Exchange.subscribe(`
   or `exchange_subscribe_fun`; it is a broadcaster if it contains
   `Phoenix.PubSub.broadcast` / `local_broadcast` or a known wrapper call
   (`DecisionPubSub.broadcast_changed`, `ObservabilityPubSub.broadcast_update`,
   `AgentPubSub.broadcast`). Subscriber ∧ broadcaster must be in
   `@bridges = ["ticket_activity.ex", "build_order/ticket_history_provider.ex", "decision_metrics.ex"]`
   (provider and its options file are treated as one module).
3. **No reverse bridge.** A file that calls `Phoenix.PubSub.subscribe` and also
   calls `Publisher.publish` / `ExecutorEvents.publish` / `Exchange.publish` must
   be in an allowlist; the list is computed at implementation time and expected to
   be empty for direct calls. If non-empty, record each entry with file:line in the
   PR body and in CONTRACT-REQUESTS (R-4 audit).

Limits stated in the module doc: interpolated topics (`"ticket.#{id}..."`) are not
checked by the literal rule; runtime topics are checked by C5-T01's catalog census.

## Implementation steps

1. Create the test; implement `source_files/0`, `strip_docs/1`, and the three rules
   as private helpers in the test file (no production module).
2. Fill `@known_violations` with the seven pairs and `@bridges` with the three.
3. Each assertion message names the rule (R-4 or §9) and the offending file:line.

## Non-happy paths

- False positives from strings in docs: handled by stripping `@moduledoc`/`@doc`
  heredocs and `#` comments before scanning.
- A wrapper rename (for example a new PubSub helper) would evade rule 2; the
  helper list is in one module attribute and C2-T05 updates it.

## Compatibility and rollout

n/a — test-only. The seven violating topics are unchanged.

## Verification

Tests:

- `"every literal Exchange topic follows the ticket/system/executor grammar except the recorded violations"`.
- `"recorded grammar violations still exist (ratchet only shrinks)"`.
- `"only the three recorded bridges subscribe to the Exchange and broadcast PubSub"`.
- `"no module bridges PubSub back into the Exchange"`.

```bash
env -C <worktree>/src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= \
  mise exec -- mix test test/aiur/events/placement_rule_test.exs
```

Mutation check: in a worktree add `Alerts.emit_custom("orphan.topic", "x")` to any
module; test 1 must fail. Add `Phoenix.PubSub.broadcast(Aiur.PubSub, "x", :y)` to
`run_telemetry/writer.ex`; test 3 must fail. Delete
`decision_store.ex:684`'s literal; test 2 must fail. Record commands.

## Completion and handoff

- [ ] Four tests green on main; three mutations fail them.
- [ ] The seven violations are listed in the PR body and in
      `MP-R2/tickets/CONTRACT-REQUESTS.md` for the signal-port owner.
- Docs: none here; C4-T05 adds the placement rule to `message-bus.md`.
- Dependents: C2-T05 (removes DebugLog from the bus core), C5-T01 (runtime catalog
  census), C4-T03 (acceptance).
