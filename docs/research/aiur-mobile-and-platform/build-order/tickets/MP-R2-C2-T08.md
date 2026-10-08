---
ticket_id: MP-R2-C2-T08
feature_id: MP-R2
chunk_id: MP-R2-C2
bucket: 1 (refactor)
title: Aiur.Events facade and caller migration batch A (ingestion producers)
status: ready
blocked_by: [DESIGN-R2 §1, MP-R2-C1-T06, MP-R2-C2-T04, MP-R2-C2-T06]
prior_units: [U5, U7, U8]
prior_boundaries: [BUS #10, ING #9]
prior_features: []
prior_findings: []
size_owner: EVENTS (github_comments_poller.ex, github_firehose.ex, github_webhook.ex if > 500 at start); re-check per RC-23
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C2-T08 — `Aiur.Events` facade + batch A

## Identity and outcome

- **Bucket 1, MP-R2, chunk C2.** No user-visible change.
- **Deliverable:** the public module `Aiur.Events` (the event-bus
  component's single facade in the MP-R1 manifest, plan §4.2) and the
  migration of the **ingestion producers** to it. Batches B (C2-T09) and C
  (C2-T10) migrate the rest; one PR per batch so each review stays small
  and conflicts with in-flight PRs stay local.
- **Non-goals:** no behaviour change, no signature change, no new option.
  The old modules (`Publisher`, `Exchange`, `IdGenerator`, `Topic`) stay
  public until C4-T03's checker marks them private to the component.

## Dependencies and blockers

- DESIGN-R2 §1; C1-T06.
- **C2-T04** (EventSource now calls `Publisher.publish/3`; this batch
  switches it to the facade) and **C2-T06** (Publisher SourcePolicy; both
  edit near the same publish options, and the facade must forward to the
  post-T06 Publisher). C2-T03/T05 are not required.
- **U5 overlap:** `github_comments_poller.ex` and `github_webhook.ex` are
  ingestion files U5 may touch ("one complete issue-comment reader"); each
  edit here is a one-token rename, so rebase rather than wait.
- Concurrent with C2-T07, C3-*.

## Verified starting point (45a290e3)

Facade targets (all public today):

| Facade function | Delegates to | Today's spec |
| --- | --- | --- |
| `publish(topic, payload, opts \\ [])` | `Aiur.Events.Publisher.publish/3` | `publisher.ex:111-113` → `{:ok, id, n} | :filtered | :deduped | {:error, :decision_requires_durable_publish | :executor_namespace_rejects_github_source}` |
| `publish_persisted(topic, payload, id, opts \\ [])` | `Publisher.publish_persisted/4` | `publisher.ex:257-260` |
| `subscribe(pattern)` / `unsubscribe(pattern)` | `Exchange.subscribe/2`, `unsubscribe/2` (default server) | `exchange.ex:70,80` |
| `bindings_for(pid)` | `Exchange.bindings_for/2` | `exchange.ex:115` |
| `matches?(pattern, topic)` | `Topic.matches?/2` | `exchange.ex:127` / `topic.ex` |
| `next_id/0`, `peek/0`, `reserve_durable_id/0` | `IdGenerator` | `id_generator.ex:82-107` |
| `set_tracked_fn(fun)` | `Publisher.set_tracked_fn/1` | `publisher.ex:374-377` |

Batch A call sites (from `git grep` at base):

| File | Line | Call |
| --- | --- | --- |
| `src/lib/aiur/events/github_comments_poller.ex` | 798 | `Publisher.publish(topic, sanitized, publish_opts)` |
| `src/lib/aiur/events/github_firehose.ex` | 358 | `Publisher.publish(topic, sanitized, publish_opts)` |
| `src/lib/aiur/events/ls_remote_ticker.ex` | 205 | `Publisher.publish(topic, payload, opts)` |
| `src/lib/aiur/events/github_webhook.ex` | 244 | default `&Publisher.publish/3` for `:publish_fun` |
| `src/lib/aiur/webhooks/event_source.ex` | 54 | after C2-T04: `Aiur.Events.Publisher.publish/3` |
| `src/lib/aiur/progress_checkin/worker.ex` | 9 (moduledoc), 102 | `Publisher.publish(topic, payload)` |
| `src/lib/aiur/allowed_contributors/state.ex` | 78 | default `&Publisher.publish/3` for `:publish_fun` |

Tests: `test/aiur/events/{github_comments_poller,github_firehose,ls_remote_ticker,github_webhook,github_webhook_equivalence}_test.exs`,
`test/aiur/webhooks/*`, progress-checkin and allowed-contributors tests.

## Chosen design

`src/lib/aiur/events.ex` (PROPOSED, ≈60 lines): `defdelegate` for each row
above, each with `@spec` copied from the target. Pure delegation, no logic,
so behaviour is identical by construction. `@moduledoc` states that this is
the event-bus component facade and links the contract
(`contracts/events-and-replay.md`).

Migration rule for every call site: replace the module prefix and the
alias only (`alias Aiur.Events.Publisher` → `alias Aiur.Events`;
`Publisher.publish(` → `Events.publish(`; `&Publisher.publish/3` →
`&Events.publish/3`). Line counts unchanged. Test doubles that inject
`:publish_fun` are unaffected.

## Implementation steps

1. Add `Aiur.Events` with delegates and specs.
2. Migrate the seven batch-A files.
3. C1-T06 allowlist: these files are *outside* the bus, so no row changes;
   add the facade to the "public API" list the C4-T03 checker will use.

## Non-happy paths

Delegation adds no failure mode. A missing `Publisher` process fails the
same way through the facade (exit from `IdGenerator.next_id/0`).

## Compatibility and rollout

No config, no API change. Rollback: revert (callers can use either module).

## Verification

1. `src/test/aiur/events/facade_test.exs` (PROPOSED)
   `"facade delegates to the bus with identical results"` — subscribe via
   `Aiur.Events.subscribe("ticket.31.pr.opened")`, `Aiur.Events.publish(…)`
   returns `{:ok, id, 1}` and the test receives `{:event, %{id: ^id}}`;
   `Aiur.Events.bindings_for(self())` contains the pattern;
   `Aiur.Events.publish("ticket.1.agent.decision.requested", %{})` returns
   `{:error, :decision_requires_durable_publish}`. **Fails without step 1**
   (module undefined). This guards the facade, not the migration.
2. Migration is a pure rename; its guard is the unchanged producer suites
   listed above (they exercise each call site). This is stated in the PR
   body as "no new test for the rename; existing suites cover each site".
3. `mix compile --warnings-as-errors` (part of `make lint`) catches a
   missed alias.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/facade_test.exs test/aiur/events/ test/aiur/webhooks/
env -C <worktree>/src mise exec -- make fmt-check lint
```

Mutation check: delete `src/lib/aiur/events.ex` → test 1 fails to compile;
restore → passes.

## Completion and handoff

- [ ] `Aiur.Events` exists with every function in the table.
- [ ] No batch-A file references `Aiur.Events.Publisher`/`Exchange` directly.
- [ ] Docs: none (internal API). C4-T05 mentions the facade in
      `concepts/message-bus.md`.
- Dependents: C2-T09, C2-T10, C4-T01 (facade listed in `components.json`).
