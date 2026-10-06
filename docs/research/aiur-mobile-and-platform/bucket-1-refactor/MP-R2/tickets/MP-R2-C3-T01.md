---
ticket_id: MP-R2-C3-T01
feature_id: MP-R2
chunk_id: MP-R2-C3
bucket: 1 (refactor)
title: Aiur.Events.Journal, a thin facade over Aiur.DecisionLog with an injected corrupt-tail reporter; ExecutorEvents uses it
status: ready
blocked_by: [DESIGN-R2 §1, MP-R2-C1-T06]
prior_units: [U3, U6, U8]
prior_boundaries: [BUS #10, EXE #26, K #1]
prior_features: [MP-R1 (C5-T01 journal primitive to kernel)]
prior_findings: []
size_owner: EVENTS (executor_events.ex 525 lines; must not grow); re-check at start per RC-23
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C3-T01 — `Aiur.Events.Journal`

## Identity and outcome

- **Bucket 1, MP-R2, chunk C3 (journal and durable-consumer primitives).**
- **Value.** The bus gets one named journal primitive for its own durable
  artifacts (the Executor stream today, the export journal in C6) without
  copying `Aiur.DecisionLog` and without knowing about `Aiur.Alerts`.
- **Deliverable.** `Aiur.Events.Journal` with `prepare/2`, `append/2` and
  `replay/3`; `Aiur.ExecutorEvents.append_event/1` and `journal_events/0`
  call it. On-disk format, fsync behaviour, torn-tail repair and the
  corruption result are byte-for-byte unchanged.
- **Non-goals.** No change to `DecisionLog` (its location is MP-R1-C5-T01's
  decision: it moves to the kernel component; this facade then follows the
  alias). No migration of `ExecutorWakeInbox` (`executor_wake_inbox.ex:110,
  334,356,363,430,559` call `DecisionLog` directly; it is EXE-owned and its
  journal/cursor contract is the U3 wake-receipt ticket's). No change to
  the 13 other `DecisionLog` callers.

## Dependencies and blockers

- DESIGN-R2 §1; C1-T06 (the boundary test must stay green; this ticket adds
  no non-kernel edge to the bus).
- **RQ-3 resolved (decisions.md):** `Aiur.DecisionLog` is a generic primitive
  used by 16 modules and depends only on `Aiur.Fs` (`decision_log.ex:35`).
  It is kernel material, so the bus wraps it rather than owning it.
- Does **not** wait for MP-R1-C5-T01: if the module is renamed or moved, only
  the alias in `journal.ex` changes.
- Concurrent with C2-*, C3-T03. C3-T02 depends on this ticket.

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| `prepare/3`: owner-only dir (0700) and file (0600), rejects symlinks, one filesystem barrier on first creation | `src/lib/aiur/decision_log.ex:39-52,67-118` |
| `append/2`: one JSON line + `\n`, fsync before return, 0600 on first create, rejects symlink | `decision_log.ex:120-148` |
| `replay/2,3` → `{:ok, records, nil}` / `{:ok, prefix, {:corrupt, line, reason}}` / `{:error, reason}`; truncates and syncs an unterminated tail unless `repair_torn_tail: false`; optional `max_file_bytes`, `max_record_bytes` | `decision_log.ex:150-194,224-278` |
| Executor append: `DecisionLog.prepare(StatePaths.dir(), journal_path())` then `append` | `src/lib/aiur/executor_events.ex:442-452` |
| Executor replay: corruption → `report_corruption/2` (Logger.error `phase=journal_corrupt` + `Alerts.emit_custom("executor_events.corrupted", …, needs_attention: true)`) and `{:error, {:corrupt, line, reason}}`; `{:error, reason}` → Logger.error `phase=journal_unavailable` and `{:error, {:journal_unavailable, reason}}` | `executor_events.ex:416-440` |
| `journal_events/0` callers | `executor_events.ex:148` (replay), `:354` (reconcile_requested), `:390` (requested_event_id), `:405` (deferred_event_id) |
| Journal path | `executor/state_paths.ex:69-70` (`journal_path/0`) |
| Tests | `src/test/aiur/decision_log_test.exs` (primitive), `src/test/aiur/executor_events_test.exs:24-33,313-325` (publish+replay, interior corruption) |

PROPOSED: `src/lib/aiur/events/journal.ex`,
`src/test/aiur/events/journal_test.exs`,
`src/test/fixtures/events/executor_journal_golden.ndjson`.

## Chosen design

```elixir
defmodule Aiur.Events.Journal do
  @moduledoc "Append/replay for bus-owned journals. Thin facade over Aiur.DecisionLog."
  @type replay_error :: {:corrupt, pos_integer(), term()} | {:journal_unavailable, term()}

  @spec prepare(Path.t(), Path.t()) :: :ok | {:error, term()}
  def prepare(dir, path), do: Aiur.DecisionLog.prepare(dir, path)

  @spec append(Path.t(), map()) :: :ok | {:error, term()}
  def append(path, record), do: Aiur.DecisionLog.append(path, record)

  @spec replay(Path.t(), (map() -> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, [term()]} | {:error, replay_error()}
  def replay(path, validator, opts \\ []) do
    {on_corrupt, opts} = Keyword.pop(opts, :on_corrupt, fn _line, _reason -> :ok end)
    case Aiur.DecisionLog.replay(path, validator, opts) do
      {:ok, records, nil} -> {:ok, records}
      {:ok, _prefix, {:corrupt, line, reason}} ->
        _ = on_corrupt.(line, reason)
        {:error, {:corrupt, line, reason}}
      {:error, reason} -> {:error, {:journal_unavailable, reason}}
    end
  end
end
```

- The reporter is injected, so the bus never references `Aiur.Alerts`
  (contract §8 "corrupt tail → one `needs_attention` alert" is the
  caller's reporter; for the export journal, C6-T02 passes one).
- `ExecutorEvents.journal_events/0` becomes
  `Journal.replay(journal_path(), &replay_validator/1, on_corrupt: &report_corruption/2)`
  and keeps its `phase=journal_unavailable` Logger line by matching
  `{:error, {:journal_unavailable, reason}}`. Return values seen by the
  four callers are identical.
- `append_event/1` → `Journal.prepare/2` + `Journal.append/2`.
- The discarded prefix on corruption is today's behaviour (`:421-423`
  returns only the error); the facade keeps that.
- **Invariant:** the bytes written and the values returned by
  `ExecutorEvents.publish/3`, `replay/2`, `reconcile_requested/1`,
  `ensure_requested/1`, `publish_deferred/2` are unchanged for every input.

## Implementation steps

1. Write the golden fixture first, on unmodified `main`: run
   `ExecutorEvents.publish/3` for `executor.notify.release` and
   `executor.decision.requested` in a test with a fixed temp state dir and
   copy the resulting journal into the fixture, normalising only `id`
   values (they are clock-seeded).
2. Add `Aiur.Events.Journal` as above.
3. Edit `executor_events.ex`: replace the `DecisionLog` alias and the two
   private functions' bodies; the file must not grow (it is 525 lines).
4. Add `journal.ex` to the event-bus member list in C1-T06's
   `bus_boundary_test.exs` with `Aiur.DecisionLog` as an allowed kernel
   reference.

## Non-happy paths

- **Torn tail.** Unchanged: `DecisionLog` truncates and fsyncs before
  decoding (`decision_log.ex:189-194`).
- **Interior corruption.** Replay stops at the first bad line, returns
  `{:error, {:corrupt, line, reason}}`, reporter called once per replay
  call (today: once per `journal_events/0` call; unchanged — no new
  deduplication is added in a refactor).
- **Reporter raises.** Today `Alerts.emit_custom/3` raising would propagate
  from `journal_events/0`; the facade does not rescue, so the same.
- **Symlinked or unreadable path.** `{:error, {:symlink_rejected, _}}` from
  `DecisionLog` → `{:error, {:journal_unavailable, …}}`, as today.
- **Concurrency.** Unchanged; appends are single `write`+`fsync` per record
  through a raw descriptor; ExecutorEvents has no extra lock today.

## Compatibility and rollout

No config, no file-format change, no migration. Rollback: revert the PR.

## Verification

New tests in `src/test/aiur/events/journal_test.exs`:

1. `"replay returns the validated records of an intact journal"` — append
   three maps, replay with `&{:ok, &1}` → three records in order.
2. `"replay reports interior corruption once through the injected reporter"`
   — file `{"id":1}\nnot-json\n{"id":2}\n`; reporter sends
   `{:corrupt, line, reason}` to the test pid; expect `{:error, {:corrupt, 2, _}}`
   and exactly one message (`refute_received` a second).
3. `"replay maps an unreadable journal to journal_unavailable"` — path is a
   symlink → `{:error, {:journal_unavailable, {:symlink_rejected, _}}}`.
4. `"append then replay round-trips byte-identically to DecisionLog"` —
   write via `Journal.append/2` and via `DecisionLog.append/2` to two files;
   `File.read!/1` equal.

Characterization (named `executor_journal_golden_characterization_test.exs`,
deliberately green on `main`, says so in a comment; not counted as change
coverage): replay of the golden fixture through `ExecutorEvents.replay/2`
returns the same list before and after the change.

Existing suites unchanged and green: `decision_log_test.exs`,
`executor_events_test.exs` (incl. `:313` interior corruption),
`executor_listener_test.exs`, `executor_wake_inbox_test.exs`,
`decision_store_test.exs`.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/journal_test.exs test/aiur/events/executor_journal_golden_characterization_test.exs \
  test/aiur/decision_log_test.exs test/aiur/executor_events_test.exs \
  test/aiur/executor_listener_test.exs test/aiur/events/bus_boundary_test.exs
env -C <worktree>/src mise exec -- make fmt-check lint
```

Mutation check (clean worktree, `git status --porcelain` shows only the
edit): in `journal.ex` remove the `on_corrupt.(line, reason)` call → test 2
fails; map `{:error, reason}` to `{:error, reason}` instead of
`{:journal_unavailable, reason}` → test 3 fails and
`executor_events_test.exs` still passes only if ExecutorEvents' match was
updated consistently (reviewer checks). Tests 1 and 4 fail if
`journal.ex` is removed (module absent); they are primitive tests, not
change-coverage claims.

## Completion and handoff

- [ ] `executor_events.ex` no longer aliases `Aiur.DecisionLog`; line count ≤ 525.
- [ ] Golden fixture committed and characterization green before and after.
- [ ] Tests 1–4 added; mutation results in the PR body.
- [ ] Docs: none (internal; no user-facing change).
- Dependents: C3-T02 (journaled publish), C3-T03 (DurableConsumer uses
  `Journal.replay/3`), C6-T02 (exporter append + reporter), C6-T03 (trim).
