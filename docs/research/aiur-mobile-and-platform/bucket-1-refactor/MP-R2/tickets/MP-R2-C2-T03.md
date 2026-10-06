---
ticket_id: MP-R2-C2-T03
feature_id: MP-R2
chunk_id: MP-R2-C2
bucket: 1 (refactor)
title: Aiur.Events.HistoryStore write sink for per-ticket event markers
status: ready
blocked_by: [DESIGN-R2 §1, MP-R2-C1-T01, MP-R2-C1-T06]
prior_units: [U3, U7, U8]
prior_boundaries: [BUS #10, RUN #18]
prior_features: []
prior_findings: []
size_owner: EVENTS (publisher.ex 539, subscription_store.ex 748); LIFECYCLE_STATUS (issue_log.ex 1049, not edited). Re-check at start per RC-23.
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C2-T03 — `HistoryStore` write sink

## Identity and outcome

- **Bucket 1, MP-R2, chunk C2.** No user-visible change.
- **Deliverable:** behaviour `Aiur.Events.HistoryStore` with one callback
  `record/3`; the bus's three write calls go through it; the default
  implementation is `Aiur.IssueLog.record_event/3`.
- **Scope decision (Phase C):** write side only. The readers of the
  per-ticket log — `BootstrapDigest`, `AgentEventFeed`,
  `TicketHistoryProvider` — are not event-bus members (agent-runner,
  conversations and build-orders components in the MP-R1 map) and keep
  calling `IssueLog.event_history/2` directly. A read callback would add a
  seam with no second implementation. `read_tail` (transcript) belongs to
  MP-E4 and is out of scope.
- **Non-goals:** no change to which events are written (F1 semantics,
  witnessed by C1-T01); no change to `IssueLog`.

## Dependencies and blockers

- DESIGN-R2 §1; C1-T01 (persistence-matrix witness must be green before and
  after); C1-T06 (boundary baseline).
- **File overlap:** touches `subscription_store.ex:424,449` (one line each).
  Land before C2-T01 or rebase after it; both are mechanical. Not blocked by
  U3 because it does not touch stall logic, but if U3's fix is open, rebase
  on it rather than racing.
- Concurrent with C2-T02, T04, T05, T07.

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| Publisher writes a marker for every `ticket.*` topic: kind `:self` when `opts[:self_emit]` or `ticket.<id>.agent.*`, else `:emit` | `src/lib/aiur/events/publisher.ex:337-357` (call at `:355`); used by `do_publish/3` `:225` and `publish_persisted/4` `:267` |
| SubscriptionStore writes `:consumed` after a successful enqueue | `subscription_store.ex:424` (retry path), `:449` (first delivery) |
| `IssueLog.record_event/3` is an async send, filters on joinable identity and a registered writer, always returns `:ok` | `src/lib/aiur/issue_log.ex:535-560,573-581,616-621` |
| Readers (unchanged by this ticket) | `agent_runner/bootstrap_digest.ex:87`; `agent_event_feed.ex:111`; `build_order/ticket_history_provider_options.ex:34` |
| Tests | `test/aiur/issue_log_event_history_test.exs`, `test/aiur/events/publisher_test.exs`, `subscription_store_test.exs`, C1-T01 `issue_log_persistence_characterization_test.exs` (PROPOSED by C1-T01) |

PROPOSED: `src/lib/aiur/events/history_store.ex`,
`src/test/aiur/events/history_store_test.exs`.

## Chosen design

```elixir
defmodule Aiur.Events.HistoryStore do
  @callback record(identifier :: String.t(),
                   kind :: :emit | :emit_alert | :consumed | :self,
                   event :: map()) :: :ok
  @spec record(String.t(), atom(), map()) :: :ok
  def record(identifier, kind, event) do
    case Application.get_env(:aiur, __MODULE__, :none) do
      :none -> :ok
      module -> module.record(identifier, kind, event)
    end
  end
end
```

- Default in `src/config/config.exs`: `config :aiur, Aiur.Events.HistoryStore, Aiur.IssueLog`.
  `Aiur.IssueLog` gets `@behaviour Aiur.Events.HistoryStore` and
  `@impl true def record(id, kind, event), do: record_event(id, kind, event)`
  (two lines; `issue_log.ex` already > 500 lines, so offset by removing two
  blank/comment lines in the same file or place the `record/3` delegate in
  a 10-line `Aiur.IssueLog.EventHistorySink` module — **choose the separate
  module** so `issue_log.ex` is untouched and the size gate is trivially met).
- `:none` (no history store, a reusable-bus deployment) keeps the bus
  working; agent bootstrap replay is then empty, which equals today's
  behaviour for non-joinable events (plan §4.3).
- **Invariant:** the same `(identifier, kind, event)` triples reach
  `IssueLog.record_event/3` in the same order.

## Implementation steps

1. Add `Aiur.Events.HistoryStore` (behaviour + dispatch function above).
2. Add `Aiur.IssueLog.EventHistorySink` implementing `record/3` by delegation.
3. Config default → `Aiur.IssueLog.EventHistorySink`.
4. `publisher.ex:355` → `Aiur.Events.HistoryStore.record(ticket_id, kind, event)`.
5. `subscription_store.ex:424,449` → same call with `:consumed`.
6. Remove the `Aiur.IssueLog` rows for `publisher.ex` and
   `subscription_store.ex` from the C1-T06 allowlist.

## Non-happy paths

- **Sink raises:** today `record_event/3` cannot raise for valid input
  (guards + `send`). A custom sink that raises would crash the publisher's
  caller or the SubscriptionStore. Do **not** add a rescue (it would differ
  from today only for a non-default sink); document "implementations must
  not raise or block" in the behaviour doc.
- **Writer not registered / non-joinable event:** unchanged (dropped inside IssueLog).
- **Ordering:** unchanged; still an async send per call.

## Compatibility and rollout

Internal app-env key only; no `.aiur/config` key, no migration. Rollback: revert.

## Verification

1. `history_store_test.exs` `"routes bus writes to the configured store"` —
   app env → `FakeHistory` that sends `{:recorded, id, kind, topic}`;
   `Publisher.publish("ticket.42.pr.merged", %{}, issue_number: nil)` (with
   the test tracked fun default) → expect `{:recorded, "42", :emit,
   "ticket.42.pr.merged"}`. **Fails without step 4.**
2. `"SubscriptionStore records :consumed through the store"` — attach a
   store with `set_enqueue_fn(fn _, _ -> :ok end)`, send `{:event, %{id: 5,
   topic: "ticket.42.branch.push"}}` → `{:recorded, id, :consumed, _}`.
   **Fails without step 5.**
3. `"no store configured is a no-op"` — app env `:none`; publish returns
   `{:ok, _, _}`; nothing recorded.
4. C1-T01 characterization suite unchanged and green (proves F1 semantics
   identical through the default sink).
5. Existing: `publisher_test.exs`, `publisher_identity_mode_test.exs`,
   `subscription_store_test.exs`, `issue_log_event_history_test.exs`,
   `agent_runner/bootstrap_digest_test.exs`, `aiur_web/streamdeck_logs_test.exs`.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/history_store_test.exs test/aiur/events/publisher_test.exs \
  test/aiur/events/publisher_identity_mode_test.exs test/aiur/events/subscription_store_test.exs \
  test/aiur/issue_log_event_history_test.exs test/aiur/agent_runner/bootstrap_digest_test.exs \
  test/aiur_web/streamdeck_logs_test.exs test/aiur/events/issue_log_persistence_characterization_test.exs
```

Mutation check: revert step 4 only → test 1 fails; revert step 5 only →
test 2 fails; restore → pass. Clean worktree, `git status --porcelain`
shows only the reverted file each time.

## Completion and handoff

- [ ] No `Aiur.IssueLog` reference in `publisher.ex` or `subscription_store.ex`.
- [ ] Neither file grows (each edit replaces one call with one call).
- [ ] Tests 1–3 added, mutation-checked; C1-T01 green.
- [ ] Docs: none (internal).
- Dependents: MP-R2-C4-T01; MP-E4-C3 (anchor resolver reads history through
  IssueLog/E4 journal, not this sink); MP-R7 (adapters must keep the
  joinable identity from `tool_executor.ex:123,441`, plan §11).
