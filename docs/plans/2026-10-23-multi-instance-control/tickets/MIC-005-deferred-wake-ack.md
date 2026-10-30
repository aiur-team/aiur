# MIC-005 — Deferred acknowledgement for `executor-wait` so a remote consumer never loses wakes

**Kind:** executable
**Provenance:** planned in plan v1
**Extends:** new; server-side prerequisite for MIC-006
**Complexity:** 2 — one function's acknowledgement path plus options
**Risk:** medium (wake loss or duplicate delivery)
**Lane:** PC
**Phase hint:** 1
**Depends on:** none
**Requirements:** R18
**Researched at:** ab0c21424

Plan context: [plan](../../2026-10-23-001-feat-multi-instance-control-plan.md) (KTD10, U5, AE7) · [pack index](../README.md)

## Outcome

A consumer can receive a wake batch without the daemon acknowledging it, and acknowledge it on the next call, so a reply lost on the network is delivered again.

## Context and evidence

- `executor_wait` prints the batch and then acknowledges it inside the same call (`src/lib/aiur/executor_attention/cli.ex:162-183`). Locally, the print reaches the caller through RPC stdout. Over HTTP (MIC-002) the call returns, the acknowledgement is written, and only then is the response sent; a dropped response loses the batch.
- The cursor is one integer, `last_seen_wake_id`, moved only by the owner (`src/lib/aiur/executor_wake_inbox/storage.ex:139-167`, `src/lib/aiur/executor_wake_inbox.ex:27-46`).
- `executor_fast_forward` already advances to an exact id for the owner (`src/lib/aiur/executor_wake_inbox.ex:58-72,317-377`).

## Scope

- New `executor_wait` options: `ack_through: non_neg_integer()` — before waiting, acknowledge as owner through that id (refuse ids above the highest delivered id with a named error); `defer_ack: true` — return the batch without acknowledging it.
- With `defer_ack: true`, the JSON result adds `"ack": "deferred"` and `"max_wake_id": N`.
- Engine flags `--ack-through <id>` and `--defer-ack` on `executor-wait` (`packaging/npm/aiur-cli/libexec/engine/executor_commands.sh:218-236`).
- Defaults unchanged: no option means print-then-acknowledge.

- One live deferred wait per consumer: a new `executor_wait(defer_ack: true)` from the same consumer id ends that consumer's previous deferred wait, which returns `status: "superseded"`, acknowledges nothing, and exits 0. Waits without `defer_ack` are unchanged. This needs consumer-keyed waiters: `Aiur.ExecutorWakeInbox.wait` takes the consumer id and keys waiters by it (today they are keyed by `from`, `src/lib/aiur/executor_wake_inbox.ex`).
- `ack_through` at or below the current cursor is a successful no-op, checked before the journal-presence check that `fast_forward_as` does (a resent id may have been trimmed). `ack_through` above the newest id in the journal returns `{:error, :journal_reset}` (journal trimmed or replaced); the cursor does not move.
- Allowlist: add `ack_through: non_neg_integer` and `defer_ack: boolean` to the `executor_wait` entry in `src/lib/aiur/control_call/allowlist.ex` if MIC-001 has merged; otherwise MIC-001 adds them when it lands second. Never add them to a build that does not implement them.

## Non-goals

- Client cursor storage and fan-out (MIC-006). Changing coalescing or `wake_id` allocation.

## Existing owner and reuse target

`Aiur.ExecutorAttention.CLI.executor_wait/1` and `acknowledge_executor_wakes/3`. Implement `ack_through` by calling the existing owner-only `fast_forward_as` (`src/lib/aiur/executor_wake_inbox.ex:58-72`); do not write a second cursor path.

## Contract and invariants

At least once: a record is never acknowledged before a later call names an id at or above it. An observer passing `ack_through` gets the existing owner-only refusal.

## Refreshable implementation notes

- Edit: `src/lib/aiur/executor_attention/cli.ex`, `src/lib/aiur/executor_wake_inbox.ex` (consumer-keyed waiters; cursor no-op before the presence check), `packaging/npm/aiur-cli/libexec/engine/executor_commands.sh`, `src/lib/aiur/control_call/allowlist.ex` (if present).
- Tests: `src/test/aiur/executor_attention/cli_test.exs` (or the existing executor-wait test file — find with `rg -l executor_wait src/test`).

## Acceptance and verification

### Acceptance criteria

1. `executor_wait(defer_ack: true)` returns records 41-44 and the cursor stays at 40.
2. A second `executor_wait(defer_ack: true)` without `ack_through` returns 41-44 again (AE7).
3. `executor_wait(ack_through: 44, defer_ack: true)` advances the cursor to 44 before waiting and then returns only newer records.
4. `ack_through` above the newest id in the journal returns `journal_reset` and the cursor does not move.
5. Without either option, behaviour and output are unchanged (existing tests pass untouched); two default waits from one consumer both behave as today.
6. A second `defer_ack` wait from the same consumer while the first is open ends the first with `status: "superseded"`, nothing acknowledged.
7. With the cursor at 44 and record 44 trimmed from the journal, `executor_wait(ack_through: 44, defer_ack: true)` succeeds (no `wake_not_found`).
8. If MIC-001 has merged: `Aiur.ControlCall.parse/1` accepts the exact expression the engine emits for `executor-wait --defer-ack --ack-through 44`.

### Test that fails without the change

Criterion 1: after `defer_ack: true`, `Storage.cursor/0` equals 40. Today the option is ignored and the cursor is 44.

### Human/manual evidence

None; MIC-010.

## Docs to update

`website/docs-app/reference/cli.md` `executor-wait` outcomes section (around line 364): add the two flags in the existing row.

## Files it touches

`executor_attention/cli.ex`, `executor_wake_inbox.ex`, `engine/executor_commands.sh`, `control_call/allowlist.ex` (if MIC-001 merged first), a test file, `reference/cli.md`.

## Dependencies and conflicts

- depends_on: none.
- serializes_with: none (`reference/cli.md` row edits fall under the pack's hot-file exception).

## First slice Kevin can try

Locally: `aiur executor-wait --defer-ack --json` twice returns the same batch.
