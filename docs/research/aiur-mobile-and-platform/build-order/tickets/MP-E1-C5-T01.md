---
ticket_id: MP-E1-C5-T01
feature_id: MP-E1
chunk_id: MP-E1-C5
bucket: 2-platform
title: Attention module - single Alerts caller, durable latches, Executor bindings
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C3-T02, MP-E1-C3-T03]
prior_units: [U3, U6]
prior_boundaries: [BUS #10]
prior_features: [MP-R1, MP-R2]
prior_findings: [MP-E1 F9]
size_owner: n/a (new file; executor_bindings.ex small)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C5-T01 — `Aiur.BuildQueue.Attention`

> **Plan refresh (wave 0).** Component map §4: attention is raised through one
> local function that calls `Aiur.Alerts` today and `Signal.alert/2` after the
> signal port lands (R1 plan-refresh row PR-07). RC-08: the topics in contract
> §4.3 are registered in MP-R2's catalog (R2-C5) later.

## Identity and outcome

- Bucket 2, MP-E1, C5, T01.
- **User value:** each queue problem reaches the Executor once, survives a
  restart without re-firing, and clears itself when fixed.
- **Deliverable:** PROPOSED `src/lib/aiur/build_queue/attention.ex` with
  `open(cause, subject, payload)` and `resolve(cause, subject)`, the only
  module under `build_queue/` that calls `Aiur.Alerts`; latches in the store;
  two `ExecutorBindings` defaults.

## Dependencies and blockers

- DESIGN-E1 §5 (alert copy), C3-T02 (latches persisted), C3-T03.

## Verified starting point (`45a290e3`)

- `Aiur.Alerts.emit_system(topic, opts)` (`alerts.ex:103-106`); `message:` is
  required or the alert is not written (`:144-160`); `issue:` accepts an
  identifier string (`orchestrator/issue_sync.ex:505-516`).
- Firing alerts are not deduplicated (F9); latch-and-resolve pattern:
  `orchestrator/issue_sync.ex:557-608`.
- `executor_bindings.ex:7-36` defaults; `ticket.*.agent.attention.*` is bound
  (`:26`). `Topic` supports `#` (multi-segment, `events/topic.ex:37-56`).
- Test: `src/test/aiur/executor_bindings_test.exs`.

## Chosen design

- Topic per contract §4.3: `ticket.<subject>.queue.attention.<cause>` or
  `system.queue.attention.<cause>`; resolve = same topic + `.resolved`,
  `needs_attention: false`, `severity: "info"`.
- Latch key `{cause, subject}` persisted **before** emitting
  (`Store.save/1`); emission failure keeps the latch and retries on the next
  reconcile (so a crash between save and emit can lose at most nothing: the
  retry is driven by a `emitted?: false` flag on the latch).
- Bindings: `{"ticket.*.queue.attention.#", "attention:auto"}`,
  `{"system.queue.attention.#", "dispatch:auto"}` — `#` so `.resolved` also
  matches.
- Payload: only allowlisted refs/attrs (contract §4.3); the human message is
  built here from DESIGN-E1 copy.

## Implementation steps

1. `attention.ex` (≈ 70 lines). 2. Two lines in `executor_bindings.ex`.

## Non-happy paths

- Alerts ledger unavailable → `{:error, _}` → latch stays `emitted?: false`;
  retried. - Store unavailable → no latch, no emit (the store-unavailable
  alert itself is latched in memory only, C5-T02).

## Compatibility and rollout

New bindings appear in `aiur executor` subscriptions by default.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `src/test/aiur/build_queue/attention_test.exs` (PROPOSED) "open twice emits once" | one event on the topic | the latch |
| "restart with latch persisted does not re-emit" | zero events after reload | persisted latch |
| "resolve emits .resolved once and clears the latch" | one `.resolved` event | resolve path |
| "emit failure retries next reconcile" | event after second reconcile | `emitted?` flag |
| `executor_bindings_test.exs` "queue attention topics are bound, including .resolved" | `Topic.matches?/2` true for `ticket.12.queue.attention.prerequisite_failed.resolved` | the `#` binding |

Mutation check: remove the latch → test 1 sees two events; bind with `*`
instead of `#` → the bindings test fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/attention_test.exs test/aiur/executor_bindings_test.exs
```

## Completion and handoff

- [ ] Single caller, latches, bindings.
- Docs: `website/docs-app/concepts/message-bus.md` lists the two new
  default bindings.
- Dependents: C5-T02, C5-T04, C4-T06.
