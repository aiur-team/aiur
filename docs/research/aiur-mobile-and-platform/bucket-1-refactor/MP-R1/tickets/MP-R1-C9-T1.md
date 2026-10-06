---
ticket_id: MP-R1-C9-T1
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: GitHub listener supervisor and the firehose listener (firehose cursor fields leave Orchestrator.State)
status: blocked   # research complete; only DESIGN-R1 and named predecessors remain
blocked_by: [DESIGN-R1, MP-R1-C1-T1, MP-R1-C1-T2, MP-R1-C7-T6, MP-R2-C2-T08, U5, MP-E1-C1]
prior_units: [U2, U3, U5, U8]
prior_boundaries: [ING #9, ORC #12, GHC #5]
prior_features: []
prior_findings: [orch-a-26, orch-b-12, events-webhooks-executor-30, orch-a-09]
size_owner: LIFECYCLE_DISPATCH (orchestrator/state.ex, orchestrator/dispatcher.ex, orchestrator/comment_polling.ex); EVENTS (tests under src/test/aiur/events/)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T1 — Listener supervisor + firehose listener

## Identity and outcome

- Bucket 1 (behaviour-preserving refactor), feature MP-R1, chunk C9 (migration step S15,
  prior carve-order §7 step 9).
- **User value:** none visible. The GitHub repo-events firehose stops being state of the
  orchestrator GenServer, which is the first cut of the `github-listeners` component out of
  `orchestration` (component-map.md §3 L2 row `github-listeners`).
- **Deliverable:**
  1. `Aiur.GitHub.Listeners` (PROPOSED, `src/lib/aiur/github/listeners.ex`): a
     `Supervisor` (`:one_for_one`) that owns one process per GitHub poll source. This ticket
     adds only its first child.
  2. `Aiur.GitHub.Listeners.Firehose` (PROPOSED,
     `src/lib/aiur/github/listeners/firehose.ex`): a GenServer that owns the five firehose
     cursor/latch fields now in `Orchestrator.State` and runs `GithubFirehose.poll/1`.
  3. The orchestrator calls it synchronously at the exact point it polls today, so the
     tick order is unchanged.
- **Non-goals:** no cadence change (the firehose still runs once per dispatch tick, from the
  same call site); no change to `Aiur.Events.GithubFirehose` itself; no physical package; no
  move of `LsRemoteTicker` (it is already its own process, `aiur.ex:446`, and stays where it
  is so its restart position is unchanged — only its manifest owner becomes
  `github-listeners`, done by C1-T1); no change to connectivity/alert wording.

## Dependencies and blockers

- **DESIGN-R1 §1** (no runtime change you see). Implementation gate.
- **MP-R1-C1-T1/T2**: the manifest must contain `github-listeners`, and the rule "only
  `github-listeners` may reference `Aiur.GitHub.Listeners.*` internals; orchestration
  may call only the facade `Aiur.GitHub.Listeners`" must exist so the move ratchets.
- **MP-R1-C7-T6** (GitHub umbrella component) and **U5** (typed GitHub outcomes,
  KTD11): the new files live under `src/lib/aiur/github/`, which U5 owns. Start after
  U5's access-layer PRs merge so this does not conflict with them.
- **MP-R2-C2-T08**: the `Aiur.Events` facade migration edits `orchestrator/` callers in
  batches; land after its `orchestrator/` batch to avoid a same-file conflict in
  `comment_polling.ex`.
- **MP-E1-C1** (RC-19): E1's hooks in `issue_sync.ex`/`dispatch_policy.ex` must already
  be on `main`; this ticket rebases over them and must not touch them.
- **U2** owns `src/lib/aiur/orchestrator/`. This ticket does **not** change any ticket
  transition, so it is not blocked on RQ-U2-TRANSITION; it does need the U2 owner's
  review because it edits `dispatcher.ex`, `state.ex` and `lifecycle.ex`.
- **May run concurrently with:** C9-T5 (PR health scanner move), C9-T7 (owner table,
  docs+test only), C9-T10 (CLI output kernel). **Not** with C9-T2/T3/T4 (same files).

## Verified starting point (45a290e3)

- The firehose is polled inline in the orchestrator tick:
  `Dispatcher.do_maybe_dispatch/1` calls `CommentPolling.poll_github_firehose(state)`
  (`src/lib/aiur/orchestrator/dispatcher.ex:133`), before the async comment poll
  (`:137`), the CI poll (`:138`) and the candidate poll.
- `CommentPolling.poll_github_firehose/2` (`orchestrator/comment_polling.ex:36-62`) passes
  `state.events_etag` / `state.events_last_id` to `GithubFirehose.poll/1`, then updates
  connectivity (`Orchestrator.note_github_connectivity_success/2`, `:47`), the poll interval
  (`Orchestrator.note_github_poll_interval/3`, `:48`), recent-merge persistence (`:49`,
  `:64-68`, `:144-173`) and the truncation latch (`note_firehose_window/3`, `:76-97`;
  `reconcile_firehose_truncation_alert/3`, `:106-119`; arm/resolve `:121-141`).
- Fields that only this code writes (all in `orchestrator/state.ex` defstruct `:207-348`):
  `events_etag` (`:289`), `events_last_id` (`:290`), `firehose_partial_streak` (`:291`),
  `firehose_truncation_alert_active` (`:292`), `firehose_truncation_alert_resolution_emitted`
  (`:293`). A `git grep` at the base finds them only in `state.ex` and `comment_polling.ex`.
- **Same-tick dependency:** `GithubFirehose.poll/1` records recent merges, and
  `Dispatcher.dispatch_candidate_poll/2` reads them in the same tick through
  `reconcile_merged_tickets/2` (`dispatcher.ex:158`). The poll must therefore stay
  synchronous and before the candidate poll.
- Connectivity and poll-delay state stay in the orchestrator: `github_connectivity` and
  `github_poll_delays` are written by `TrackerHealth` (`orchestrator/tracker_health.ex:21,31,96`)
  and read by the poll scheduler (`tracker_health.ex:344`).
- Supervision: `Aiur.Supervisor` is `:rest_for_one` (`src/lib/aiur.ex:118`).
  `Aiur.Orchestrator` is started at `aiur.ex:442`, right after `Aiur.GitHub.ViewStateSweep`
  (`:441`). Today a crash inside `GithubFirehose.poll/1` crashes the orchestrator, which
  restarts it and every later child, and the restarted orchestrator starts with
  `events_etag: nil, events_last_id: nil` (defstruct defaults).
- Existing tests: `src/test/aiur/orchestrator_firehose_test.exs` (streak, truncation
  alert, recent-merge persistence), `src/test/aiur/events/github_firehose_test.exs`.
  Nine test files build `%State{events_etag: …, events_last_id: …}` (listed in Step 6).

## Chosen design

**Process placement (preserves crash and restart semantics).** Insert
`Aiur.GitHub.Listeners` in `child_specs/1` **immediately before** `Aiur.Orchestrator`
(`aiur.ex:441-442`). Because the root is `:rest_for_one`:

- a listener crash restarts the orchestrator and every later child — the same blast radius a
  firehose crash has today;
- an orchestrator restart does **not** restart the listener, so the orchestrator's
  `Lifecycle.init/2` calls `Aiur.GitHub.Listeners.reset/0` once. Reset drops the firehose
  cursor and latches to their defstruct defaults, which reproduces today's "a restarted
  orchestrator re-reads from a nil cursor".

**Call shape.** `Aiur.GitHub.Listeners.poll_firehose(opts) :: outcome` is a
`GenServer.call(..., :infinity)`. The infinite timeout matches today (the poll runs inline
with no timeout). The orchestrator does **not** catch an exit from that call, so a listener
crash behaves like today's inline crash.

**Outcome payload** (the only data that returns to `Orchestrator.State`):

```elixir
%{
  connectivity: [{:firehose, :ok} | {:firehose, {:error, reason}} |
                 {:recent_merge_store, :ok} | {:recent_merge_store, {:error, term}}],
  poll_interval: pos_integer() | nil      # X-Poll-Interval seconds, for TrackerHealth
}
```

`Dispatcher.do_maybe_dispatch/1` replaces line 133 with
`state |> apply_listener_outcome(Aiur.GitHub.Listeners.poll_firehose([]))`, where
`apply_listener_outcome/2` folds each entry through the same `TrackerHealth`
functions in the same order as `comment_polling.ex:46-49` and `:153-158`.

**What moves into the listener:** the cursor fields, the truncation streak and its
attention (`system.firehose.event_truncation[.resolved]`, same text, same
`Alerts.emit_system/2` default, same `AlertFeed.active_system_attention?/1` check after a
restart), the recent-merge persistence retry counter. The retry counter today reads
`github_connectivity[:recent_merge_store]` (`comment_polling.ex:164-169`); in the
listener it becomes a private integer, and the listener still reports each failure in
`connectivity` so `github_connectivity[:recent_merge_store]` is written exactly as before.

**Invariants:**
- I1: one firehose poll per dispatch tick, before the comment poll, CI poll and candidate
  poll (unchanged order).
- I2: the cursor advances only on `{:ok, …}`, or after the persistence retry limit — the
  same branches as `comment_polling.ex:42-61`.
- I3: after the orchestrator restarts, the first firehose poll sends `etag: nil,
  last_event_id: nil`.
- I4: no `Orchestrator.State` field named `events_*` or `firehose_*` remains.
- I5 (RC-19): MP-E1-C1 hooks in `issue_sync.ex` and `dispatch_policy.ex` are untouched.

## Implementation steps

1. Add `src/lib/aiur/github/listeners.ex` (supervisor, facade with `poll_firehose/1`,
   `reset/0`; `reset/0` is a call to every child that implements it).
2. Add `src/lib/aiur/github/listeners/firehose.ex`. Move, without changing logic,
   `poll_github_firehose/2` and its private helpers from `comment_polling.ex:36-227` into
   it; the state is the listener's own struct with the five fields. Replace the calls to
   `Orchestrator.note_*` with appends to the outcome list.
3. In `orchestrator/comment_polling.ex`, delete the moved code (≈190 lines) and the
   `GithubFirehose` alias. The module keeps the comment poll (moved by C9-T2).
4. In `orchestrator/dispatcher.ex:133`, call the facade and fold the outcome with
   `TrackerHealth` (≈15 lines).
5. In `orchestrator/state.ex`, delete the five fields from `@type` and `defstruct`.
6. In `orchestrator/lifecycle.ex` `init/2`, call `Aiur.GitHub.Listeners.reset/0` when the
   process exists (`Process.whereis/1`; tests that start the orchestrator without the
   listener pass).
7. In `aiur.ex`, add `Aiur.GitHub.Listeners` before `Aiur.Orchestrator`. Request the
   child-order change through the `APP_BOOT` U8 owner (proposal.md "Other runtime packages
   request child-order changes through this owner").
8. Tests: move the firehose cases from `orchestrator_firehose_test.exs` to
   `src/test/aiur/github/listeners/firehose_test.exs` (PROPOSED); drop `events_etag` /
   `events_last_id` from `%State{}` literals in `blocker_merge_wake_test.exs`,
   `command_scan_test.exs`, `comment_polling_test.exs`,
   `comment_rework_active_entry_test.exs`, `comment_wake_test.exs`, `pr_anchored_test.exs`,
   `push_routing_test.exs`, `rework_review_transition_test.exs` and
   `orchestrator_firehose_test.exs` (all under `src/test/aiur/`).
9. `components.json`: add the new paths to `github-listeners`, so no allowlist entry is
   added (ratchet ≤ before).

Estimated production diff: ≈230 moved lines, ≈90 new lines.

## Non-happy paths

| Case | Behaviour |
|---|---|
| Listener crashes inside a poll | Caller exits; orchestrator restarts with everything after it (same as today). Listener restarts from defaults under its own supervisor. |
| Orchestrator restarts, listener alive | `Lifecycle.init` calls `reset/0`; I3 holds. |
| Listener not started (unit tests, `child_specs` variants) | `reset/0` is skipped when the name is not registered; `poll_firehose/1` is only called from `do_maybe_dispatch/1`, which only runs in a full tree. A missing listener in a full tree is a boot bug: the call exits, and the orchestrator crashes loudly rather than silently skipping. |
| `tracker.kind` is not `github` | Unchanged: `GithubFirehose.poll/1` decides; the listener adds no gate. |
| Recent-merge store read-only | Retry counter and attention identical to `comment_polling.ex:144-206`. |
| Privacy | Payload crossing the process boundary carries no comment bodies; bodies are published by `GithubFirehose` as today. |

## Compatibility and rollout

No config, flag or on-disk change. `polling.*` keys keep their names (owner moves to
`github-listeners` in the manifest only). Rollback is a revert of the PR. Restart
behaviour equals today's (I3), so a daemon upgrade needs no migration.

## Verification

Run every Elixir test with an isolated home so the local run cannot overwrite the real
`~/.aiur/github-budget/agent-token`:

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= \
  mise exec -- mix test test/aiur/github/listeners/firehose_test.exs \
  test/aiur/orchestrator_firehose_test.exs test/aiur/application_test.exs \
  test/aiur/orchestrator/comment_polling_test.exs test/aiur/events/github_firehose_test.exs
python3 scripts/check-components.py   # MP-R1-C1 checker; violation count must not rise
```

New tests (PROPOSED names) and the production hunk each must fail without:

| Test | Expectation | Fails without |
|---|---|---|
| `firehose_test "reset/0 makes the next poll send nil etag and last_event_id"` | after a successful poll and `reset/0`, the stubbed poller receives `etag: nil, last_event_id: nil` | the `reset/0` handler |
| `orchestrator lifecycle test "init resets the firehose listener cursor"` | start listener, poll once, start orchestrator; listener cursor is nil | the `Listeners.reset/0` call in `Lifecycle.init` |
| `dispatcher test "firehose outcome reaches TrackerHealth in order"` | outcome `[{:firehose, :ok}]` + `poll_interval: 60` gives `github_connectivity[:firehose]` success and `github_poll_delays[:firehose] == 60_000` | the `apply_listener_outcome/2` fold |
| `application_test "github listeners start immediately before the orchestrator"` | index(`Aiur.GitHub.Listeners`) + 1 == index(`Aiur.Orchestrator`) in every run shape | the `aiur.ex` insertion |
| `firehose_test "a listener exit propagates to the caller"` | `catch_exit` on `poll_firehose/1` when the stub raises | (guard) — would pass if someone adds a rescue; keep it as a regression guard and label it so |

Moved truncation/persistence tests must pass unchanged in assertion content (only the
module under test changes). Mutation check: in a separate worktree, revert only the named
hunk, confirm `git status --porcelain` shows only that file, run the test, see it fail;
restore and see it pass. Record the commands in the PR body (AGENTS.md).

**Manual (AGENTS.md "Manual testing"):** foreground `scripts/aiurdev --test` in the wrapper
tmux; merge a sandbox PR or push to a sandbox ticket branch; open the agent chat pane
(`Enter` on a running row) and see the `pr.merged`/`pr.opened` incoming-event row; run
`aiurdev status` and see the firehose connectivity line unchanged.

## Completion and handoff

- [ ] Five fields removed from `Orchestrator.State`; firehose state lives in the listener.
- [ ] Tick order I1 and restart behaviour I3 proven by tests.
- [ ] Checker violation count ≤ before; no file over 500 lines created or grown.
- [ ] MP-E1-C1 hooks untouched (diff of `issue_sync.ex`/`dispatch_policy.ex` is empty).
- [ ] Mutation results named per test in the PR body.
- Docs: none required (internal refactor, AGENTS.md "Docs ship with the change").
  `website/docs-app/apis/github.md` describes cadences, not process placement; re-read it
  and confirm no sentence names the orchestrator as the firehose poller — if one does, fix it.
- Dependents: C9-T2, C9-T3, C9-T4 (reuse the supervisor), C9-T7 (owner table),
  MP-R1-C11-T2 (path map rows PR-12). size_owner re-resolved at ticket start against the
  then-current U8 ledger (RC-23, MP-R1-C11-T2).
