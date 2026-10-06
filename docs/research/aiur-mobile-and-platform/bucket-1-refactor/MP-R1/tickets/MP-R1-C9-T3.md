---
ticket_id: MP-R1-C9-T3
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: Comments listener process owns the comment-poll cursor and the owned-poll protocol
status: blocked   # research complete; only DESIGN-R1 and named predecessors remain
blocked_by: [DESIGN-R1, MP-R1-C9-T1, MP-R1-C9-T2, MP-E1-C1]
prior_units: [U2, U3, U5, U8]
prior_boundaries: [ING #9, ORC #12]
prior_features: []
prior_findings: [orch-a-26, orch-a-29, orch-b-12]
size_owner: LIFECYCLE_DISPATCH (orchestrator.ex, orchestrator/state.ex, orchestrator/lifecycle.ex, orchestrator/comment_polling*); EVENTS (events/github_webhook.ex tests)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T3 — Comments listener process

## Identity and outcome

- Bucket 1, MP-R1, chunk C9, step S15.
- **User value:** none visible. The comment poll's process-ownership protocol (finding
  `orch-a-26`: "~400-line process-ownership protocol with unbounded receives in the
  Orchestrator") leaves the orchestrator mailbox. The orchestrator stops receiving
  `{:github_comment_poll_started, …}`, `{:github_comment_poll_guarding, …}` and the poll's
  `:DOWN`.
- **Deliverable:** `Aiur.GitHub.Listeners.Comments` (PROPOSED,
  `src/lib/aiur/github/listeners/comments.ex`), a second child of
  `Aiur.GitHub.Listeners`. It holds the `%CommentPolling.Cursor{}` from C9-T2, runs the
  owned poll, and sends one result message per completed poll back to the orchestrator.
  The C9-T2 modules (`comment_polling.ex`, `owned_poll.ex`, `target_selection*.ex`,
  `cursor.ex`, `input.ex`) move under `src/lib/aiur/github/listeners/comments/`
  (PROPOSED) with module names `Aiur.GitHub.Listeners.Comments.*`.
- **Non-goals:** no cadence change (the poll is still started from the dispatch tick, at
  `dispatcher.ex:137`); no change to the webhook route, debounce or delivery log; no
  change to which targets are polled.

## Dependencies and blockers

- DESIGN-R1 §1; C9-T1 (supervisor exists); C9-T2 (plain inputs); MP-E1-C1 (RC-19).
- U3 owns event ordering. This ticket does not touch `subscription_store.ex`,
  `executor/claims.ex` or `executor_wake_inbox.ex`; publication still happens inside
  `GithubCommentsPoller` exactly as today.
- **Concurrent with:** C9-T5–T7, C9-T10–T14. Not with C9-T4 (same supervisor file) —
  serialize T3 before T4.

## Verified starting point (45a290e3)

- Start: `Dispatcher.do_maybe_dispatch/1` calls `CommentPolling.start_async(state)`
  (`dispatcher.ex:137`, comment `:134-136` explains #1837: the orchestrator was parked in
  the fan-out with 5,729 queued messages).
- Orchestrator handlers to remove: `orchestrator.ex:202-211` (`:github_comments_polled`,
  `:github_comment_poll_started`, `:github_comment_poll_guarding`), the
  `CommentPolling.apply_async_down/2` branch at `:84-87`, `:62-63`
  (`:run_github_comment_reconcile` timer), and `lifecycle.ex:205`
  (`CommentPolling.terminate_poll/1` on terminate).
- Webhook hint: `Aiur.Events.GithubWebhook` sends `{:github_webhook_reconcile, hint}` to
  `Keyword.get(opts, :orchestrator, Aiur.Orchestrator)` (`events/github_webhook.ex:272-277`);
  the orchestrator handles it at `orchestrator.ex:59-60`.
- Reconcile backoff reads `TrackerHealth.github_next_poll_delay_ms/1`
  (`comment_polling.ex:438`), which reads `State.github_poll_delays` — orchestrator state.

## Chosen design

**Messages.**

| From → to | Message | Today's equivalent |
|---|---|---|
| orchestrator → listener | `Listeners.start_comment_poll(%Input{}, opts)` (cast) | `CommentPolling.start_async/2` |
| orchestrator → listener | `Listeners.reconcile_hint(hint, %Input{})` (cast) | `CommentPolling.request_reconcile/2` |
| orchestrator → listener | `Listeners.update_backoff(next_github_delay_ms)` (cast, sent whenever `TrackerHealth` changes `github_poll_delays`) | read of `State.github_poll_delays` at schedule time |
| listener → orchestrator | `{:github_listener_outcome, :comments, outcome}` | `{:github_comments_polled, ref, payload}` folded by `apply_async/3` |

`outcome` is the C9-T2 map (`connectivity`, `pr_review_seen_at`,
`pr_draft_observations`). The orchestrator folds it with the C9-T2 wrapper — unchanged
order.

**Webhook hint routing.** Keep `GithubWebhook` sending to the orchestrator (no change to
`events/github_webhook.ex`, which U3/EVENTS own). The orchestrator forwards the hint with
a fresh `%Input{}`. This preserves the existing test seam `:orchestrator` and costs one
extra message hop that does no I/O.

**Ownership key.** `Input.ownership_key` is still the orchestrator's `snapshot_key`, so a
same-name orchestrator successor keeps today's single-poll guarantee.

**Restart semantics** (same rule as C9-T1): the listener sits before the orchestrator in
the `:rest_for_one` root. `Lifecycle.init/2` calls `Listeners.reset/0`; the comments
child's reset runs `OwnedPoll.terminate_poll/1` on any in-flight poll and resets the
cursor to `%Cursor{}`. That reproduces today's terminate-then-fresh-state on orchestrator
restart (`lifecycle.ex:205` plus defstruct defaults). An outcome that arrives after a
reset carries a stale poll ref and is dropped by the listener (today: `apply_async/3`
second clause).

**Invariants:** at most one in-flight comment poll per ownership key; the orchestrator
mailbox never receives owned-poll protocol messages; a reconcile requested during a poll
runs after it (`reconcile_test.exs` cases unchanged); cadence gate
(`within_review_cadence?/2`) evaluated in the listener with the same monotonic clock.

## Implementation steps

1. `git mv` the C9-T2 modules into `src/lib/aiur/github/listeners/comments/` and rename
   the modules; no body changes except `self()` now being the listener.
2. Add `comments.ex` GenServer: `handle_cast` for the three inbound messages,
   `handle_info` for the owned-poll protocol messages and `:DOWN` that moved out of
   `orchestrator.ex`.
3. Orchestrator: replace the removed handlers with one
   `handle_info({:github_listener_outcome, :comments, outcome}, state)`; keep the
   `{:github_webhook_reconcile, …}` clause but forward; send `update_backoff/1` from
   the places `TrackerHealth.note_github_poll_interval/3` changes the delay.
4. `State`: delete `github_comment_cursor`.
5. `lifecycle.ex`: delete the `terminate_poll` call (reset now covers it).
6. Move the tests (`comment_polling_test.exs`, `comment_polling/*_test.exs`) to
   `src/test/aiur/github/listeners/comments/` and adjust them to drive the listener.
   `regression/orchestrator_blocking_http_test.exs` keeps asserting that the orchestrator
   answers `:sys.get_state`/status while a poll is blocked on HTTP — this is the #1837
   property and it must still hold.

Estimated: ≈200 changed lines, ≈900 moved lines (pure `git mv` plus rename).

## Non-happy paths

| Case | Behaviour |
|---|---|
| Poll hangs | Abandon rule unchanged (`comment_poll_abandon_after_ms`), now in the listener. |
| Listener crash mid-poll | Linked poll tree is reaped by the owned-poll protocol (unchanged code); `:rest_for_one` restarts the orchestrator after it (today: an owned-poll crash does not crash the orchestrator because it is monitored, not linked; that stays true — only a crash of the listener GenServer itself cascades, which has no equivalent today and is the price of the separate process. It is logged as a crash and visible in `SupervisionHealth`). |
| Outcome after orchestrator restart | Dropped by ref (stale). |
| Backoff update lost (listener restarting) | Next `start_comment_poll` carries `Input.next_github_delay_ms`, so the listener is never more than one tick stale — same freshness as today, where the value is read at the next schedule. |
| Duplicate webhook hints | Coalesced into `reconcile_targets` as today. |

## Compatibility and rollout

No config/flag/API/disk change. `polling.intervals.review` semantics unchanged. Rollback
is a revert of this PR (C9-T2 can stay).

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/github/listeners/comments \
  test/aiur/regression/orchestrator_blocking_http_test.exs \
  test/aiur/events/github_webhook_equivalence_test.exs test/aiur/events/github_webhook_test.exs \
  test/aiur/orchestrator/comment_wake_test.exs test/aiur/application_test.exs
python3 scripts/check-components.py
```

New tests:

| Test | Expectation | Fails without |
|---|---|---|
| `comments_listener_test "orchestrator mailbox never sees owned-poll messages"` | trace the orchestrator pid during one full poll; no `:github_comment_poll_started`/`_guarding` received | the move of the protocol handlers into the listener |
| `comments_listener_test "reset terminates the in-flight poll and clears the cursor"` | start a blocking poll, `reset/0`, assert poll pid dead and cursor `== %Cursor{}` | the reset clause |
| `comments_listener_test "a webhook hint reaches the listener through the orchestrator"` | send `{:github_webhook_reconcile, %{kind: :review_thread, ticket: "7"}}` to the orchestrator; listener cursor `reconcile_targets` contains `"7"` | the forward clause |
| `comments_listener_test "outcome after reset is dropped"` | deliver an outcome with the pre-reset ref; orchestrator `pr_review_seen_at` unchanged | the stale-ref check |

Mutation check per AGENTS.md. Manual: wrapper-tmux `aiurdev --test`; while an agent runs,
post a trusted comment on its sandbox PR; the chat pane shows the incoming comment event;
`aiurdev status` stays responsive during the poll (the #1837 property).

## Completion and handoff

- [ ] Orchestrator has no comment-poll fields and no owned-poll handlers.
- [ ] `orchestrator_blocking_http_test.exs` green.
- [ ] Checker ratchet ≤ before; no file > 500 lines.
- Docs: none (internal). Re-read `website/docs-app/apis/github.md` comment-poll cadence
  section and fix any sentence that names the orchestrator process as the poller.
- Dependents: C9-T4, C9-T7, MP-R1-C11 path-map row PR-12. size_owner re-resolved at
  ticket start (RC-23).
