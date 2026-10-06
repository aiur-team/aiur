---
ticket_id: MP-R2-C1-T03
feature_id: MP-R2
chunk_id: MP-R2-C1
bucket: 1 (refactor)
title: Witness that non-executor wakes published while ExecutorListener is unbound are not replayed
status: ready
blocked_by: [DESIGN-R2 §1]
prior_units: [U3]
prior_boundaries: [EXE #26, BUS #10]
prior_features: []
prior_findings: [loose-4-04 (wake receipt/replay, related)]
size_owner: n/a (test-only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C1-T03 — Executor wake gap witness (plan F5)

## Identity and outcome

- **Bucket 1, MP-R2, C1, T03.**
- **Value.** Contract §7.1 says: non-`executor.*` wakes published while the
  listener is unbound are lost; only `executor.*` is replayed from the journal.
  This pins that in a test, so the packaging chunks cannot change it silently and a
  later Bucket 2 fix (for example adopting `DurableConsumer`, C3-T03) has a red/green
  starting point.
- **Deliverable.** New test cases in a new file
  `src/test/aiur/executor_wake_gap_characterization_test.exs` (PROPOSED).
- **Non-goals.** No fix. The fix is a separate Bucket 2 decision (contract D-1).

## Dependencies and blockers

- DESIGN-R2 §1. Concurrent with other C1 tickets.
- Related prior work: U3 wake receipt/replay (`loose-4-04`) owns
  `executor_wake_inbox.ex`; this ticket only reads its API.

## Verified starting point (45a290e3)

- `ExecutorListener.init/1` subscribes, then replays **only** `executor.#` from the
  journal (`executor_listener.ex:45-75`, `replay_and_deliver/2` at `:133-142`).
- Non-`executor.*` events are projected and enqueued only when received live
  (`executor_listener.ex:180-191`); the watermark advances only for `executor.*`
  (`:149-153`).
- `ExecutorBindings.patterns/0` includes `ticket.*.pr.merged` (`executor_bindings.ex:25`).
- `ExecutorWakeInbox.wait/2` returns `{:ok, records} | :timeout | {:error, _}`
  (`executor_wake_inbox.ex:26-29,153-167`).
- Existing pattern to reuse: listener restart test
  (`src/test/aiur/executor_listener_test.exs:278-305`), wake test (`:201-216`),
  setup (`:15-43`).

## Chosen design

Two tests in the style of `executor_listener_test.exs:278`:

1. **Wake gap.** Start `ExecutorWakeInbox` (`debounce_ms: 10`). Start the listener,
   stop it with `stop_supervised!/1`, publish
   `Exchange.publish("ticket.42.pr.merged", %{id: id, topic: "ticket.42.pr.merged", pr: %{"number" => 7}})`
   (no listener bound), restart the listener, then
   `assert ExecutorWakeInbox.wait(300) == :timeout`. Expected today: the merge wake
   is absent.
2. **Control.** Same sequence with `ExecutorEvents.publish_requested(decision)`:
   the Command alert is replayed (proved by the existing test at `:278`; this file
   asserts the replayed watermark `>= id` to show the contrast in one place).

## Implementation steps

1. Module `Aiur.ExecutorWakeGapCharacterizationTest`, `use Aiur.TestSupport`,
   `async: false`; copy setup and `start_listener/1`, `command_decision/1`,
   `watermark/0` helpers from `executor_listener_test.exs:15-71`.
2. Write test 1 and test 2 as above. Use `refute_receive`/`wait` with explicit
   short timeouts; no `Process.sleep`.
3. Comment: "Characterization, deliberately green on main: documents contract §7.1
   gap. A Bucket 2 fix must flip test 1 and say so in its PR."

## Non-happy paths

- The listener's own resubscribe tick (`resubscribe_interval_ms`) must not run
  during the gap: start with `resubscribe_interval_ms: :infinity` as at
  `executor_listener_test.exs:99`.
- A global `ExecutorWakeInbox` is not running in the shared test app (the existing
  tests start their own); keep that assumption explicit with
  `assert Process.whereis(Aiur.ExecutorWakeInbox)` after `start_supervised!`.

## Compatibility and rollout

n/a — test-only.

## Verification

Tests:

- `"an allowlisted ticket wake published while the listener is down is not replayed (characterization)"`.
- `"an executor.* Command published while the listener is down is replayed (characterization)"`.

```bash
env -C <worktree>/src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= \
  mise exec -- mix test test/aiur/executor_wake_gap_characterization_test.exs
```

Mutation check:

- Test 2: replace the body of `replay_and_deliver/2` (`executor_listener.ex:133-142`)
  with `state` in a worktree; test 2 must fail (no replay).
- Test 1: in a worktree, make `ExecutorListener.init/1` enqueue a projected record
  for any event the test passes in through a temporary `:replay_fixture` option
  — this needs a production hook, which this ticket must not add. Therefore test 1
  has no clean single-hunk mutation; the PR body states this explicitly (AGENTS.md
  permits it) and instead shows that test 1 fails when the publish is moved to
  *after* the listener restart (a test-side control proving the assertion can fail).

## Completion and handoff

- [ ] Both tests green on main; test 2 mutation fails it; test 1 mutation result or
      the explicit "could not mutate cleanly" statement is in the PR body.
- Docs: none in this ticket; C4-T05 cites it in `message-bus.md` durability classes.
- Dependents: any Bucket 2 ticket that closes the wake gap; C3-T03 (DurableConsumer
  design reference).
