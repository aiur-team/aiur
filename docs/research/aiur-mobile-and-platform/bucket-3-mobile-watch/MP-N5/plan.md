# MP-N5 — Post-refactor notification policy refresh

## 10. Notification policy starting point

Refresh SHA: `3b00b8f2cd0bfc9acdffe3b07ee5f1c6ca2ab56a` (2026-10-27).
This checkout had tickets but no MP-N5 `plan.md`; this section supplies the
requested mapping without reconstructing §§1–9. Historical `base_sha: 45a290e3`
is retained. DESIGN-N5 uses the recommended defaults resolved in epic #6663;
this audit does not reopen that choice or waive downstream implementation gates.

### Package and symbol mapping

Components remain manifest-owned modules inside the application; the refactor
has not moved every component into a separate physical package. Paths below
are relative to `src/lib/aiur/` unless a full repository path is given.

| Historical citation | Landed source and consumer entry | Owner / scope |
| --- | --- | --- |
| `Aiur.Events.Exchange.subscribe/2`, `events/exchange.ex:70,93-108` | `Aiur.Events.subscribe/1,2`, `events.ex:23-27`; implementation `events/exchange.ex:70,99` still sends `{:event, event}` | event-bus; C2-T01; Exchange is private |
| `DurableConsumer.replay(after)` | `Aiur.Events.DurableConsumer.start_link/1`, `events/durable_consumer.ex:37`; replay is a Source callback, not a Consumer function | event-bus; C2-T01 |
| MP-R2-C6 export source | `events/durable_consumer/export_source.ex`, public `Aiur.Events.DurableConsumer.ExportSource` | event-bus; landed, not deferred |
| `events.export.enabled` | `config/schema/events_export.ex:16`, default `false`; runtime capability `events.export` | config schema; event-bus owns the key |
| `Aiur.DecisionStore.list/1`, `decision_store.ex:393` | `Aiur.Commands.list_decisions/0,1,2`, `commands.ex:182-190`; delegates to `decision_store.ex:377` | commands; C2-T01 reconciliation; Store is private |
| `Aiur.DecisionStore.get/2`, `decision_store.ex:388` | implementation `decision_store.ex:365`; public `Aiur.Commands.get/1,2`, `commands.ex:36-37` | commands; C3-T03; envelope differs, CR-N5-PATH-1 |
| `lifecycle_slug/1`, `decision_store.ex:2633-2653` | `decision_store/requests.ex:349-381`; publication via `commands/topics.ex:11-16` | commands; C2-T02; implementation evidence only |
| `Aiur.Decision` fields, `decision.ex:18-42,120-136` | `decision.ex:170-204` struct; `commands/event_data.ex:20` validates `short_label` | commands; C2-T02; public Decision type |
| Re-ask at `decision_attention.ex:17` | `decision_attention.ex:20,204-215` (15 min default) | commands; C2-T01/T02 exclude attention re-asks |
| `Aiur.BuildProgress.facts/1`, `subscribe/0` | `build_progress.ex:36-42`; facts filter is `:all` or `{:queue, id}` / `{:build_order, id}` | build-orders; C2-T01/T03; not a declared facade, CR-N5-PATH-2 |
| `RootSummary.progress`, `root_summary.ex:6,8-27` | `build_order/root_summary.ex` (`Aiur.BuildOrder.RootSummary`); semantics precedent only | build-orders; private, do not import from push-relay |
| `runtime_state_dir/0`, `config/paths.ex:243` | `Aiur.Config.Paths.runtime_state_dir/0`, `config/paths.ex:329` | config; no declared push edge, CR-N4-PATH-1 |
| `executor_bindings.ex:25,29,32` | `executor_bindings.ex` default bindings still include merge, retry-exhausted and CI failure topics | executor-attention; topic evidence, no import |
| `CiLifecycle.publish_ci_terminal_event/4`, `ci_lifecycle.ex:333-345` | facade `orchestrator/ci_lifecycle.ex:156`, implementation `orchestrator/ci_lifecycle/terminal_event.ex:19-29` | orchestration; C2-T04; payload still carries `head_sha`, `pr_number` |
| Merge source `events/github_firehose.ex:21` | `events/github_firehose/pull_request.ex`; catalog `events/catalog/entries.ex:33-35` | github-listeners; C2-T04 |
| `src/lib/aiur/push/policy/**`, `Aiur.Push.Policy.*` | Same **PROPOSED** paths; tests `src/test/aiur/push/policy/**` also **PROPOSED** | push-relay; C2/C3 |
| `Aiur.Push.Outbox.accept/2`, `StalenessHook`, `Aiur.Push.Supervisor` | **PROPOSED** `src/lib/aiur/push/**`, MP-N4-C3-T02/T04 | push-relay; not shipped APIs |

### Topics and delivery contracts

The catalog is authoritative: `events/catalog/planned_entries.ex:13-28` and
`commands/topics.ex:11-16` agree on `ticket.<id>.agent.decision.human-needed`
and `executor.decision.human-needed`. The RC-08 spelling without `.agent.` is
historical and must not become a subscription. Terminal slugs stay `answered`,
`expired`, `mooted`, `resolved`; `dismissed`/`deferred` are not retraction triggers.

Progress topics are exactly `system.build_order.*.progress` and
`system.queue.*.progress`, with **no trailing `.*`** (catalog
`planned_entries.ex:48-64`). They are ledgered, exported 25/50/75/100 milestones.
The finer E1 signal remains `Aiur.BuildProgress.subscribe/0` on PubSub
`"build_progress"`, message `{:build_progress_changed, fact}`. Use that signal
and `facts/1` for per-device thresholds; do not infer 10% updates from milestones.
Its component facade approval remains open (CR-N5-PATH-2).

Opt-in topics remain `ticket.*.pr.merged`, `ticket.*.agent.retry_exhausted`,
`ticket.*.ci.failed` (`entries.ex:33-40`, `ticket_entries.ex:44`). Merge and CI
are live-class and exported when observed; export cannot recover events never
observed while the daemon was down. Retry-exhausted is ledgered; do not
substitute `ticket.*.agent.attention.error-retry_exhausted`.

### Replay, availability and integration gates

Start a named DurableConsumer with `source: {ExportSource, source_opts}`,
`handler: {handler_module, state}` and `cursor_path`; pass the same cursor path
in source options. Source callbacks are `subscribe/2`, `replay/3`, `position/1`;
handlers implement `handle_record/2`, `handle_reset/2`, `handle_unavailable/2`.
Export positions are dense `"seq"` values, never event IDs. The source tracks
its epoch beside the cursor and reads the complete feed; filter topics in the
handler without skipping cursor advancement for irrelevant records.

A source reset is `{:reset, oldest}`; DurableConsumer calls `handle_reset/2`,
persists `oldest - 1`, then replays retained records. It does **not** move to
head automatically. C2-T01 must reconcile and suppress historical notification
intents during catch-up, including explicit export `gap` records. Reconciliation
also runs at boot and on the policy timer. Handler success advances the cursor;
errors retry, so ledger/outbox effects must be idempotent.

When export is disabled (default) or unavailable, Live remains the explicitly
planned fallback. No claim is made that export is enabled in this run.
`components/push-relay.json` is still planned with `paths: []`; register future
paths there. Required edges include commands and event-bus; build-orders and
build-queue are optional. Their presence does not approve private imports.
See [contract requests](CONTRACT-REQUESTS.md) for changed lookup shape and the
missing progress facade and handler behaviour, and [CR-N4-PATH-1](../MP-N4/CONTRACT-REQUESTS.md) for
runtime-path/persistence approval. These are downstream integration gates, not
permission to import private modules or silently change the policy contract.

### Planned-import audit

The dependency checker's `components.reference_rules.edge_rules` was evaluated
with the shipped push-relay manifest at the refresh SHA. `Aiur.Commands`,
`Aiur.Events`, `Aiur.Events.DurableConsumer` and `ExportSource` pass.
`Aiur.DecisionStore`, `Aiur.BuildProgress` and the DurableConsumer `Handler` /
`Source` behaviours fail `R-private`; `Aiur.Config.Paths` fails `R-declared`.
These findings are recorded in the linked contract requests. This audit does
not claim the source walker can validate nonexistent push code.
