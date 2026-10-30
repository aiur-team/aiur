# MIC-006 — One Executor for every instance: `aiur --instance all executor-wait` merges wake streams

**Kind:** executable
**Provenance:** planned in plan v1
**Extends:** new; reverses the need created by #5803 (each instance now filters out the other's wakes, so the per-instance streams are disjoint and a union is complete)
**Complexity:** 3 — concurrent long-polls, per-instance cursors, skill update
**Risk:** medium
**Lane:** PC
**Phase hint:** 3
**Depends on:** MIC-002, MIC-004, MIC-005
**Requirements:** R17, R18
**Researched at:** ab0c21424

Plan context: [plan](../../2026-10-23-001-feat-multi-instance-control-plan.md) (KTD10, F3, U6) · [pack index](../README.md)

## Outcome

The operator runs one Executor on one machine. Its loop `aiur --instance all executor-wait --as fleet-executor --json` returns wakes from whichever instance has them, each record naming its instance, and no wake is lost when a reply is dropped.

## Context and evidence

- Each instance keeps its own wake journal and cursor in its own executor directory (`src/lib/aiur/executor/state_paths.ex:12-30`); `wake_id` is a per-journal counter (`src/lib/aiur/executor_wake_inbox.ex:134`), so ids collide across instances and the instance name must travel with each record.
- Each instance already drops wakes for tickets it does not own (`src/lib/aiur/executor_listener.ex:240-242`, #5803), so streams do not overlap.
- Claims are per host (`src/lib/aiur/executor/claims.ex:26-40`); a remote Executor holds a separate owner lease on each instance under the same `--as` id. No cross-machine lease is needed.

## Scope

- `executor-wait` with `--instance all` (and with a single `--instance <name>`): for each registered instance, start a remote wait with `--defer-ack --ack-through <stored id>` (MIC-005); return when the first instance answers with records or when all time out; cancel the rest (safe: nothing they would return is acknowledged).
- Client cursor file per instance: `~/.aiur/remote-state/<name>.wake-ack` holding the result's `instance_id` and the highest delivered `wake_id`, written after the batch is printed. If the `instance_id` changes, or the server answers `journal_reset` (MIC-005), reset the cursor to 0 and print a warning naming the instance.
- `--instance all executor-wait` is the one write command allowed under `all` (R4); it needs a write token on every instance and sends `max_scope: "write"`. Every other fan-out keeps `max_scope: "read"`.
- Remote `--timeout` is capped at 600 s (refuse higher with exit 64); `timeout_ms` sent equals it.
- An instance that answers `unknown_on_build` or `option_not_allowed` for `defer_ack`/`ack_through` is reported as unsupported and skipped; the client never waits on it without `defer_ack`.
- Output: JSON mode prints `{"instance":"nuc","status":"woken","role":"owner","records":[...]}` per instance with records; text mode prefixes each record line with `[nuc]`.
- `--instance all executor-roster` works through MIC-004 (read) — verify and document.
- Refuse `--as` absent with `--instance` (the consumer id must be explicit for remote ownership).
- In remote mode, do not send the harness `env:` list (`packaging/npm/aiur-cli/libexec/aiur-executor-session.sh:23-31`): the daemon would check the caller's pid and cwd on its own host (`src/lib/aiur/harness_session.ex:79-113`) and report a wrong liveness. The remote Executor's liveness is its lease renewals.
- Update `.claude/skills/aiur-run/SKILL.md`: fleet mode — one Executor, the wait command, and the rule that per-machine Executors stop (decision D10).

## Non-goals

- Server-side merged journals or SSE. Fixing same-host `wake_id` collisions (deferred ledger DF-1).

## Existing owner and reuse target

`engine/remote.sh` fan-out from MIC-004; `cmd_executor_wait` in `packaging/npm/aiur-cli/libexec/engine/executor_commands.sh:218-236`.

## Contract and invariants

At least once per instance. A batch is acknowledged on an instance only by the next call to that same instance. Records from different instances are never merged into one id space.

## Refreshable implementation notes

- Edit: `engine/remote.sh`, `engine/executor_commands.sh`, `.claude/skills/aiur-run/SKILL.md`.
- Test: `packaging/npm/aiur-cli/test/launcher-remote-wait.test.mjs` with two fake servers that record the `ack_through` they receive.

## Acceptance and verification

### Acceptance criteria

1. Fake `pc` idle, fake `nuc` returns records 41-44: output has four records tagged `nuc`; the next call sends `ack_through: 44` to `nuc` and `ack_through: <previous>` to `pc`.
2. If the client is killed after receiving but before writing the cursor, the next call re-sends the previous `ack_through` and `nuc` returns 41-44 again.
3. Both idle until timeout: exit 0 with `status: "timeout"` per instance.
4. One instance unreachable: the others still deliver; the unreachable one is reported, not dropped.
5. Missing `--as` with `--instance` exits 64.
6. A fake answering `journal_reset` makes the next call to it send `ack_through: 0` and a warning is printed; a changed `instance_id` does the same.
7. A fake answering 422 `unknown_on_build` is reported as unsupported; no later request to it omits `defer_ack`.
8. The request body sent for each instance has no `env:` and parses with `Aiur.ControlCall.parse(expr, remote: true)` (shared fixture).

### Test that fails without the change

Criterion 1: before the change `executor-wait --instance all` is refused as a write command by MIC-004.

### Human/manual evidence

MIC-010: one Executor session runs the loop against PC and NUC for at least one wake from each.

## Docs to update

- `website/docs-app/reference/cli.md` wake section (lines ~364-395): one row for remote/fleet wait.
- `.claude/skills/aiur-run/SKILL.md` and `website/docs-app/skills.md` if it summarizes the loop.

## Files it touches

`engine/remote.sh`, `engine/executor_commands.sh`, a new test, `reference/cli.md`, the `aiur-run` skill.

## Dependencies and conflicts

- depends_on: MIC-002 (endpoint), MIC-004 (fan-out code it extends), MIC-005 (server options).

## First slice Kevin can try

Stop the NUC Executor; from the PC session run the fleet wait and handle one NUC wake.
