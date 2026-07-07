# T-025: orchestrator wave 4: sync, subscriptions, operator messages

**Phase:** 3
**Depends-on:** T-024
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3`

## Problem / context

`src/lib/aiur/orchestrator.ex` is a 7,617-line GenServer (774 def/defp clauses)
being decomposed into ~26 modules per the binding name map in
`docs/refactor/research-arch/giant-orchestrator.md` §2. This is wave 4 of 6
(T-022..T-027). Waves 1-3 already extracted: `State`, `EventTopics`,
`DispatchPolicy`, `Slots` (T-022); `Dispatcher`, `RetryEngine`, `Reconciler`
(T-023); `CommentWake`, `PrAnchored`, `PushRouting`, `CommentPolling`,
`CommandScan` (T-024) — all under `src/lib/aiur/orchestrator/`.

This wave extracts five modules: `Aiur.Orchestrator.IssueSync` (sync polled
issues into state and emit derived dependency/label/todo-capacity events),
`Aiur.Orchestrator.AutoSubscriptions` (automatic blocker/blockee pub-sub wiring
and blocker-critical event classification), `Aiur.Orchestrator.TrackerHealth`
(tracker/GitHub preflight + connectivity streaks/backoff), `Aiur.Orchestrator.OperatorMessages`
(operator-message and event-digest enqueueing, delivery-policy normalization,
wake decisions, control capabilities), and `Aiur.Orchestrator.DigestCoalescer`
(pure drain-time coalescing of queued events-digest items).

The **blocker auto-subscription + blockee auto-resume chain is a preserved
invariant** (`FI-EVT-058`, `FI-ORC-048`, `FI-ORC-049`): `AutoSubscriptions`
owns the *subscribe* half (the exact blockee/blocker topic sets that a paused
blockee needs so a `ticket.<blocker>.branch.push` reaches it); the *auto-resume*
half lives in `PushRouting` (T-024). If the subscription topic strings drift by
even one segment, or the `first-write-wins`/reason-scoped subscription contract
is broken, blockee auto-resume stops firing **silently** — no crash, no failing
compile. This is a verbatim code MOVE, not a rewrite: every function body is
copied byte-identical (comments and topic literals included), public signatures
and observable behavior are unchanged, and all extracted code keeps executing as
plain function calls inside the orchestrator GenServer process (no new
processes, no GenServer calls back into the orchestrator — that deadlocks).

## Scope (exact)

Line numbers below are from the current `main` snapshot of
`src/lib/aiur/orchestrator.ex` (7,617 lines). Waves T-022..T-024 will have
shifted them: locate every function by its exact name/arity (each name/arity is
unique in the file); use the line numbers only as orientation.

1. **Precondition check.** Verify these files (created by T-022) exist:
   `src/lib/aiur/orchestrator/state.ex`,
   `src/lib/aiur/orchestrator/dispatch_policy.ex`,
   `src/lib/aiur/orchestrator/slots.ex`. This wave's moved code calls into all
   three. If any is missing, STOP: comment the blocker on the issue and end your
   turn. Do not start extraction.

2. **Create `src/lib/aiur/orchestrator/digest_coalescer.ex`** defining
   `defmodule Aiur.Orchestrator.DigestCoalescer`. Move these functions VERBATIM
   (bodies byte-identical, comments included) out of
   `src/lib/aiur/orchestrator.ex`:

   Public (`def` + `@spec`; called from code remaining in the facade):
   - `coalesce_events_digests/3` (was ~7356; move its preceding drain-time
     comment block untouched)

   Private (`defp`, internal-only to this module):
   - `do_coalesce_events_digests/3` (was ~7360)
   - `merge_events_digest_items/2` (was ~7378)
   - `event_sort_key/1` (all three clauses, was ~7395)
   - `event_dedupe_key/1` (both clauses, was ~7399)
   - `event_topic/1` (was ~7411)
   - `event_comment_id/1` (was ~7414)

3. **Create `src/lib/aiur/orchestrator/tracker_health.ex`** defining
   `defmodule Aiur.Orchestrator.TrackerHealth`. Move VERBATIM:

   Public (`def` + `@spec`):
   - `ensure_tracker_preflight/1` (was ~2230)
   - `next_poll_delay_ms/1` (was ~1497)
   - `note_github_connectivity_success/2` (was ~1434)
   - `note_github_connectivity_failure/3` (was ~1444)
   - `log_tracker_fetch_error/1` (was ~2290)

   Private (`defp`):
   - `ensure_github_auth_preflight/1` (was ~2243)
   - `log_tracker_preflight_error/1` (ALL 13 clauses, was ~2250-2288)
   - `tracker_log_label/0` (was ~2294)
   - `connectivity_classification/1` (all three clauses, was ~1465)
   - `connectivity_streak_count/2` (was ~1476)
   - `normalize_github_backoff_ms/2` (all three clauses, was ~1483)
   - `note_github_poll_interval/3` (both clauses, was ~1490)
   - `github_next_poll_delay_ms/1` (both clauses, was ~1501)
   - `emit_github_connectivity_alert/1` (was ~1510)

4. **Create `src/lib/aiur/orchestrator/auto_subscriptions.ex`** defining
   `defmodule Aiur.Orchestrator.AutoSubscriptions`. Move VERBATIM:

   Public (`def` + `@spec`):
   - `subscribe_for_declared_blocker/2` (was ~7468; KEEP its existing `@spec`
     at ~7467 — this is a public client API called by
     `src/lib/aiur/agent_runner.ex`, do not narrow its type)
   - `auto_subscribe_for_dependency/2` (both clauses, was ~7426; called from
     `IssueSync` this wave)
   - `auto_unsubscribe_for_dependency/2` (both clauses, was ~7487; called from
     `IssueSync` this wave)
   - `direct_blockers_for/2` (both clauses, was ~7569; called from a facade
     `handle_call`)
   - `blocker_critical_digest?/2` (both clauses, was ~7586; called from a
     facade `handle_call`)

   Private (`defp`):
   - `attach_and_subscribe/3` (was ~7508)
   - `remove_auto_subscriptions/3` (was ~7516)
   - `default_blockee_subscriptions/1` (was ~7522; the 9-topic list is the
     `FI-EVT-058` contract — keep every literal, including the dead-but-reserved
     `ticket.<id>.branch.force-push` per `FI-EVT-034`)
   - `default_blocker_subscriptions/1` (was ~7543)
   - `blockee_identifier_for/1` (both clauses, was ~7552)
   - `blocker_identifier_for/1` (all clauses, was ~7557)
   - `blocker_critical_event?/2` (both clauses, was ~7596)
   - `blocker_critical_topic?/2` (was ~7608)

5. **Create `src/lib/aiur/orchestrator/issue_sync.ex`** defining
   `defmodule Aiur.Orchestrator.IssueSync`. Move VERBATIM:

   Public (`def` + `@spec`):
   - `sync_polled_issue_state/2` (both clauses, was ~3272; called from facade
     `do_maybe_dispatch/1` and the `*_for_test` seam)
   - `sync_todo_capacity_alert/2` (both clauses, was ~6900; called from facade
     `do_maybe_dispatch/1` and the `*_for_test` seam)

   Private (`defp`):
   - `issues_by_id/1` (was ~3289)
   - `emit_dependency_transition_events/3` (both clauses, was ~3296)
   - `emit_task_state_transition_alert/3` (all clauses, was ~3344)
   - `task_state_alert_reason/1` (both clauses, was ~3372)
   - `task_state_alert_severity/1` (both clauses, was ~3380)
   - `blocker_map/1` (both clauses, was ~3383)
   - `blocker_terminal?/1` (both clauses, was ~3395)
   - `maybe_enqueue_blocker_terminality_event/4` (was ~3401)
   - `enqueue_dependency_event/4` (both clauses, was ~3414)
   - `blocker_event_body/3` (was ~3441)
   - `blocker_event_summary/3` (ALL four clauses, was ~3454)
   - `dependency_event_dedupe_key/3` (was ~3465)
   - `dependency_causal_refs/2` (was ~3476)
   - `dependency_subscription/2` (was ~3481)
   - `routable_todo_issues/1` (was ~6920)
   - `emit_todo_capacity_alert/2` (both clauses, was ~6934)

6. **Create `src/lib/aiur/orchestrator/operator_messages.ex`** defining
   `defmodule Aiur.Orchestrator.OperatorMessages`. Move VERBATIM:

   Public (`def` + `@spec`):
   - `enqueue_event_digest_item/4` (was ~5602)
   - `enqueue_operator_message/4` (was ~5629)
   - `notify_running_queue_update/2` (both clauses, was ~5915; called from
     `IssueSync` this wave)
   - `issue_control_capabilities/2` (was ~6501)
   - `queue_depth_for_issue/2` (was ~6474)
   - `pending_operator_messages_for_issue/2` (was ~6481)
   - `send_running_control_message/3` (was ~5896)
   - `maybe_emit_agent_control_alert/3` (all three clauses, was ~5860)

   Private (`defp`):
   - `enqueue_validated_operator_message/4` (was ~5650)
   - `enqueue_for_running_entry/5` (was ~5681)
   - `enqueue_after_reactivate/4` (was ~5729)
   - `enqueue_after_resume/4` (was ~5757)
   - `do_enqueue_running_operator_message/4` (was ~5785)
   - `normalize_delivery_request/3` (ALL nine clauses, was ~5824-5858)
   - `validate_operator_message/1` (was ~5886)
   - `deliver_now?/2` (was ~5928)
   - `event_digest_delivery_opts/2` (was ~5934)
   - `trusted_comment_wake_required?/2` (was ~5943)
   - `trusted_comment_event_digest?/1` (all clauses, was ~5947)
   - `comment_event_topic?/1` (was ~5958)
   - `queue_wake_required?/1` (was ~5972)
   - `no_active_turn?/1` (both clauses, was ~5977)
   - `operator_item_text/1` (both clauses, was ~6498)
   - `accepted_delivery_policies/2` (all three clauses, was ~6523)

   Move the module attribute `@max_operator_message_chars 8_000` (was line 87)
   from `orchestrator.ex` into `operator_messages.ex` (delete it from the
   facade; its only consumer is `validate_operator_message/1`).

7. **Module heads.** Each new module gets: a `@moduledoc` (2-4 lines stating its
   one-sentence responsibility from the name map, plus "All functions execute
   inside the orchestrator GenServer process."), the aliases it needs copied
   from `orchestrator.ex`'s head (only the ones its moved code references —
   `mix compile --warnings-as-errors` will flag unused ones; e.g.
   `alias Aiur.Orchestrator.{State, DispatchPolicy, Slots}`, `Issue`, `Alerts`,
   `Config`, `AgentQueue`, `AgentQueueStore`, `AgentQueueItem`, `ActiveTurns`,
   `SubscriptionStore`, `GitHubConnectivity`, `require Logger`), and `@spec` on
   every public `def` (`mix credo --strict` runs `specs.check`, which enforces
   this).

8. **Rewrite intra-move references (no logic changes).** Inside the moved
   bodies, qualify calls whose targets now live elsewhere. Locate each target
   with `grep -rn "def <name>" src/lib/aiur/orchestrator/` and call it where the
   prior wave actually placed it:
   - Targets extracted by **T-022** →
     `DispatchPolicy.terminal_state_set/0`,
     `DispatchPolicy.terminal_issue_state?/2`,
     `DispatchPolicy.normalize_issue_state/1`,
     `DispatchPolicy.issue_routable_to_worker?/1`,
     `DispatchPolicy.todo_issue_blocked_by_non_terminal?/2`,
     `DispatchPolicy.sort_issues_for_dispatch/1` (all used by `IssueSync`'s
     `blocker_terminal?/1` and `routable_todo_issues/1`);
     `Slots.max_concurrent_agent_limit/1` (used by
     `IssueSync.sync_todo_capacity_alert/2`);
     `State.find_running_by_identifier/2` (used by
     `IssueSync.enqueue_dependency_event/4` and by `OperatorMessages`
     enqueue/control paths). If T-022 left `find_running_by_identifier/2` as a
     `defp` in the facade, call it as `Orchestrator.find_running_by_identifier/2`
     instead — check the grep.
   - **Cross-references between this wave's new modules** stay module-qualified:
     `IssueSync.emit_dependency_transition_events/3` calls
     `AutoSubscriptions.auto_subscribe_for_dependency/2` and
     `AutoSubscriptions.auto_unsubscribe_for_dependency/2`;
     `IssueSync.enqueue_dependency_event/4` calls
     `OperatorMessages.notify_running_queue_update/2`. `AutoSubscriptions.direct_blockers_for/2`
     reads the `%State{last_polled_issues: ...}` field directly (struct access,
     no call). Add `alias Aiur.Orchestrator.{AutoSubscriptions, OperatorMessages}`
     to `issue_sync.ex`.
   - Targets still living in `orchestrator.ex` (they belong to LATER waves or
     are multi-consumer facade residents) → call as `Orchestrator.<name>(...)`.
     For `running_worker_host/2` (used by `IssueSync.emit_todo_capacity_alert/2`):
     if it is currently a `defp`, flip it to `@doc false def` with a `@spec`
     (body untouched) and call `Orchestrator.running_worker_host/2`; if a prior
     wave already made it `@doc false def`, just call it. Add
     `alias Aiur.Orchestrator` to `issue_sync.ex`.
   - Do NOT change `self()`, `Process.send_after/3`, `Process.cancel_timer/1`,
     `make_ref()`, or `Process.monitor/1` sites in any moved body — the code
     runs inside the orchestrator process.
   - Do NOT alter any topic string, subscription reason string
     (`"blocker:auto"`, `"blockee:auto"`, `"manual:agent"`), alert topic,
     dedupe key, delay/limit, or log string.

9. **In `src/lib/aiur/orchestrator.ex`:** delete every moved definition, then
   add a one-line wrapper — identical head (same name, arity, guards, default
   args) — ONLY for the moved functions that code OUTSIDE the new module still
   calls. A caller is "outside" whether it remains in `orchestrator.ex` (its
   `handle_info`/`handle_call` clauses, `do_maybe_dispatch/1`, the `*_for_test`
   seams) or lives in an already-extracted sibling module that calls it as
   `Orchestrator.<name>` (a prior wave flipped such functions to
   `@doc false def`). **Wrapper visibility must match the function's current
   visibility:** if it is presently `defp` (only facade code calls it), the
   wrapper is `defp`; if it is presently `@doc false def` (a sibling module
   calls `Orchestrator.<name>`), the wrapper is `@doc false def` + `@spec`.
   Verify each with `grep -rn "Orchestrator\.<name>" src/lib/aiur/orchestrator/`.

   Exact wrapper list, each delegating to the new module:
   - → `DigestCoalescer`: `coalesce_events_digests/3` (called by the facade
     `{:claim_next_queue_item, ...}` `handle_call` and by the
     `coalesce_for_test/2` seam)
   - → `TrackerHealth`: `ensure_tracker_preflight/1`, `next_poll_delay_ms/1`,
     `note_github_connectivity_success/2`, `note_github_connectivity_failure/3`,
     `log_tracker_fetch_error/1`
   - → `AutoSubscriptions`: `subscribe_for_declared_blocker/2` (keep it a PUBLIC
     `def` + `@spec` — external API), `direct_blockers_for/2`,
     `blocker_critical_digest?/2`
   - → `IssueSync`: `sync_polled_issue_state/2`, `sync_todo_capacity_alert/2`
   - → `OperatorMessages`: `enqueue_event_digest_item/4`,
     `enqueue_operator_message/4`, `issue_control_capabilities/2`,
     `queue_depth_for_issue/2`, `pending_operator_messages_for_issue/2`,
     `send_running_control_message/3`, `maybe_emit_agent_control_alert/3`

   `auto_subscribe_for_dependency/2`, `auto_unsubscribe_for_dependency/2`, and
   `notify_running_queue_update/2` get NO facade wrapper — their only outside
   caller is `IssueSync` (this wave), which calls them module-qualified.

   Do NOT edit the bodies of `handle_info`/`handle_call`/`handle_cast` clauses,
   `do_maybe_dispatch/1`, `coalesce_for_test/2`, or any `*_for_test` function —
   the wrappers keep every existing call site compiling unchanged.

10. **Do not modify** `src/mix.exs` (the five new modules must NOT be added to
    `ignore_modules`), any existing test file, `src/lib/aiur/orchestrator/tracked_set.ex`,
    or the modules from prior waves (only the permitted `running_worker_host/2`
    visibility flip in the facade). After steps 2-9 the repo compiles
    warnings-free and the FULL suite passes (run the Agent gate below).

## Files

- Create: `src/lib/aiur/orchestrator/digest_coalescer.ex`,
  `src/lib/aiur/orchestrator/tracker_health.ex`,
  `src/lib/aiur/orchestrator/auto_subscriptions.ex`,
  `src/lib/aiur/orchestrator/issue_sync.ex`,
  `src/lib/aiur/orchestrator/operator_messages.ex`,
  `src/test/aiur/orchestrator/digest_coalescer_test.exs`,
  `src/test/aiur/orchestrator/tracker_health_test.exs`,
  `src/test/aiur/orchestrator/auto_subscriptions_test.exs`,
  `src/test/aiur/orchestrator/issue_sync_test.exs`,
  `src/test/aiur/orchestrator/operator_messages_test.exs`
- Modify: `src/lib/aiur/orchestrator.ex`
- Test: the five new test files above; the entire existing suite must pass
  unmodified.

## Out of scope

- The other planned orchestrator modules — `CommentWake`, `PrAnchored`,
  `PushRouting`, `CommentPolling`, `CommandScan` (T-024, already merged);
  `PauseResume`, `Interrupts`, `RemoteControlMode`, `TokenAccounting` (T-026);
  `StatusReport`, `WorkspaceCleanup`, `HumanReview`, `AgentTeardown`,
  `RuntimeWatchdog` (T-027). Their functions stay put; the only permitted facade
  touch outside the moved definitions is the `running_worker_host/2` visibility
  flip in step 8.
- The auto-**resume** half of the blocker chain (`maybe_resume_blockees_on_push/3`,
  `attempt_auto_resume/5`, `reconcile_pending_auto_resumes/1`) — those are
  `PushRouting`, extracted in T-024. This ticket only owns the auto-**subscribe**
  half. Do not move or edit the resume functions.
- The modules from prior waves (`state.ex`, `dispatch_policy.ex`, `slots.ex`,
  `dispatcher.ex`, `retry_engine.ex`, `reconciler.ex`, `comment_wake.ex`,
  `pr_anchored.ex`, `push_routing.ex`, `comment_polling.ex`, `command_scan.ex`)
  — call them, never edit them.
- `src/lib/aiur/orchestrator/tracked_set.ex`, `src/lib/aiur/agent_runner.ex`,
  `src/lib/aiur/tracker.ex`, `src/lib/aiur/events/subscription_store.ex`,
  `src/lib/aiur/events/publisher.ex`, `src/lib/aiur/github/connectivity.ex` —
  untouched (call them where the moved code already did).
- `src/mix.exs` — untouched (no new coverage exemptions, no dep changes).
- Every existing test file, including all `*_for_test` seam call sites — test
  moves/renames are a later cleanup wave (research doc W29), not this ticket.
- Any behavior change: no renamed functions, no reordered clauses, no changed
  topic strings/subscription reasons/delays/limits/log strings/alert topics,
  no "improvements" to moved code.
- `handle_info`/`handle_call`/`handle_cast` clause bodies, `init/1`,
  `terminate/2`, tick scheduling, tracked-set sync (`issue_tracked?/1` stays in
  the facade — Publisher closure contract).

## Inventory-IDs

From `docs/refactor/feature-inventory/orc.md` and
`docs/refactor/feature-inventory/evt.md` — this ticket's Files implement or
touch these entries; their behavior must be byte-for-byte preserved:

- **FI-ORC-041** — GitHub firehose connectivity escalation: the
  `note_github_connectivity_success/2` / `note_github_connectivity_failure/3`
  streaks, `normalize_github_backoff_ms/2` (incl. `:escalate` → max backoff),
  per-source poll-delay map, and the single `system.github.connectivity_lost`
  alert via `emit_github_connectivity_alert/1` (→ `TrackerHealth`).
- **FI-ORC-046** — tracker preflight on every dispatch cycle and retry poll
  (`ensure_tracker_preflight/1` + `ensure_github_auth_preflight/1` + the 13
  `log_tracker_preflight_error/1` clauses) (→ `TrackerHealth`).
- **FI-ORC-047** — label-flip transition alerts
  (`emit_task_state_transition_alert/3`; human-review carries
  `needs_attention: true`) (→ `IssueSync`).
- **FI-ORC-048** — dependency transition events + asymmetric auto-subscribe:
  `emit_dependency_transition_events/3` and its enqueue helpers (→ `IssueSync`),
  and `auto_subscribe_for_dependency/2` / `auto_unsubscribe_for_dependency/2`
  with the exact 9-vs-2 topic split and `blocker:auto`/`blockee:auto` reasons
  (→ `AutoSubscriptions`).
- **FI-ORC-049** — `subscribe_for_declared_blocker/2` public API (called by
  `AgentRunner` at `aiur_declare_blocker` time; accepts integer or string ids)
  (→ `AutoSubscriptions`, facade keeps a public delegating wrapper).
- **FI-ORC-050** — todo over-capacity alert edge-triggered latch
  (`sync_todo_capacity_alert/2` / `routable_todo_issues/1` /
  `emit_todo_capacity_alert/2`) (→ `IssueSync`).
- **FI-ORC-051** — operator-message enqueue: `enqueue_operator_message/4`
  validation (`validate_operator_message/1`: trimmed non-empty, ≤ 8000 chars)
  and the delivery-policy normalization table (`normalize_delivery_request/3`)
  (→ `OperatorMessages`).
- **FI-ORC-052** — queue claim / drain-time digest coalescing:
  `coalesce_events_digests/3` merges + dedupes-by-comment/event-id + sorts + one
  summary (→ `DigestCoalescer`); `blocker_critical_digest?/2` /
  `direct_blockers_for/2` scope the blocker-critical claim (→ `AutoSubscriptions`);
  `queue_depth_for_issue/2` (→ `OperatorMessages`).
- **FI-ORC-053** — event-digest enqueue + wake decision
  (`enqueue_event_digest_item/4`, `event_digest_delivery_opts/2`,
  `deliver_now?/2`, `notify_running_queue_update/2`) (→ `OperatorMessages`).
- **FI-ORC-055** — pause/unpause alerts on control transitions
  (`maybe_emit_agent_control_alert/3`, `send_running_control_message/3`)
  (→ `OperatorMessages`).

From `docs/refactor/feature-inventory/evt.md`:

- **FI-EVT-058** — `aiur_declare_blocker` auto-subscriptions + blockee
  auto-resume: `AutoSubscriptions` owns the declare-time subscribe half
  (`default_blockee_subscriptions/1` / `default_blocker_subscriptions/1` /
  `attach_and_subscribe/3`); the auto-resume half is `PushRouting` (T-024).
  Preserve the exact topic sets and reasons — drift breaks resume silently.
- **FI-EVT-057** — universal per-agent auto-subscriptions: the topic literals in
  `default_blockee_subscriptions/1` must match publisher literals exactly (the
  Exchange routes by literal segments).
- **FI-EVT-034** — `ticket.<id>.branch.force-push` is subscribe-only dead
  vocabulary with NO emitter; it MUST remain in `default_blockee_subscriptions/1`
  and `blocker_critical_topic?/2` verbatim (a "remove unused topics" cleanup
  would delete reserved semantics).
- **FI-EVT-048 / FI-EVT-049 / FI-EVT-050** — `agent.decision.*`,
  `agent.blocked`, `agent.unblocked` are members of the blocker/blockee default
  subscription sets and the blocker-critical filter; keep them in
  `default_*_subscriptions/1` and `blocker_critical_topic?/2` unchanged.
- **FI-EVT-059** — `events_digest` queue-item delivery: the coalescing preserved
  by `DigestCoalescer` is what makes a long turn see ONE `<aiur:events>` block;
  per-publish granularity (cursor/`[event:consumed]` markers) is upstream and
  must not be touched.

## Characterization-tests

All of `src/test/aiur/regression/` must pass UNMODIFIED. The orchestrator
characterization files landed by T-007 (orchestrator lifecycle & dispatch
gates) and T-008 (GitHub ingestion & wake/rework) pin this wave's semantics —
per `research-arch/giant-orchestrator.md` §4, specifically the connectivity
backoff `:escalate` normalization, dependency-event auto-subscribe, and
digest-coalescing paths that had no direct pins before Phase 1. List them at
execution time with `ls src/test/aiur/regression/ | grep -iE 'orch|ingest|event'`
(they merge in Phase 1, before this ticket opens) and run them explicitly
before opening the PR.

These existing (non-regression-dir) pins must also pass unmodified — they
exercise the moved code through the `*_for_test` seams and `handle_info`/`handle_call`
sends, which is why the seams and wrappers must keep identical signatures:
`src/test/aiur/orchestrator_events_digest_coalesce_test.exs`,
`src/test/aiur/orchestrator_auto_subscribe_test.exs`,
`src/test/aiur/orchestrator_firehose_test.exs`,
`src/test/aiur/orchestrator_status_test.exs`,
`src/test/aiur/orchestrator_deactivate_test.exs`,
`src/test/aiur/alerts_test.exs`,
`src/test/aiur/agent_queue_test.exs`,
`src/test/aiur/github_issue_dependencies_test.exs`,
`src/test/aiur/github_auth_preflight_test.exs`,
`src/test/aiur/agent_control_cli_test.exs`,
`src/test/aiur/core_test.exs`.

## Acceptance criteria

All greps run from the repo root; all must hold:

- Each new module is defined exactly once at its path:
  `grep -c "defmodule Aiur.Orchestrator.DigestCoalescer do" src/lib/aiur/orchestrator/digest_coalescer.ex` = 1;
  same for `TrackerHealth`/`tracker_health.ex`,
  `AutoSubscriptions`/`auto_subscriptions.ex`, `IssueSync`/`issue_sync.ex`,
  `OperatorMessages`/`operator_messages.ex`.
- `grep -c "@moduledoc" <file>` >= 1 for each of the five new modules.
- Facade shrank: `wc -l < src/lib/aiur/orchestrator.ex` < 4000 (orientation:
  7,617 on `main`, reduced by every prior wave; this wave removes ~1,150+ net
  lines).
- New-file size caps (these carry the research doc §2 documented exception to
  the 200-line norm — `OperatorMessages`/`IssueSync` are single cohesive state
  machines kept whole; do not split further, do not exceed):
  `wc -l < src/lib/aiur/orchestrator/operator_messages.ex` <= 460,
  `wc -l < src/lib/aiur/orchestrator/issue_sync.ex` <= 420,
  `wc -l < src/lib/aiur/orchestrator/tracker_health.ex` <= 360,
  `wc -l < src/lib/aiur/orchestrator/auto_subscriptions.ex` <= 280,
  `wc -l < src/lib/aiur/orchestrator/digest_coalescer.ex` <= 180.
- Moved functions are moved, not rewritten: no NEW function body exceeds 20
  logic lines (wrappers are 1 line); moved bodies are byte-identical (verified
  at-merge via `--color-moved`).
- The operator-message cap attribute left the facade:
  `grep -c "@max_operator_message_chars" src/lib/aiur/orchestrator.ex` = 0 and
  `grep -c "@max_operator_message_chars 8_000" src/lib/aiur/orchestrator/operator_messages.ex` = 1.
- No connectivity/preflight logic remains unwrapped in the facade (wrapped names
  keep a 1-line delegating def/defp; the private helpers must be gone entirely):
  `grep -cE "^  defp (ensure_github_auth_preflight|log_tracker_preflight_error|connectivity_classification|connectivity_streak_count|normalize_github_backoff_ms|note_github_poll_interval|github_next_poll_delay_ms|emit_github_connectivity_alert|tracker_log_label)\(" src/lib/aiur/orchestrator.ex` = 0.
- No coalescing internals remain in the facade:
  `grep -cE "^  defp (do_coalesce_events_digests|merge_events_digest_items|event_sort_key|event_dedupe_key|event_topic|event_comment_id)\(" src/lib/aiur/orchestrator.ex` = 0.
- No dependency-event / todo-capacity internals remain in the facade:
  `grep -cE "^  defp (issues_by_id|emit_dependency_transition_events|emit_task_state_transition_alert|blocker_map|blocker_terminal\?|maybe_enqueue_blocker_terminality_event|enqueue_dependency_event|blocker_event_body|blocker_event_summary|dependency_event_dedupe_key|dependency_causal_refs|dependency_subscription|routable_todo_issues|emit_todo_capacity_alert)\(" src/lib/aiur/orchestrator.ex` = 0.
- No auto-subscription internals remain in the facade:
  `grep -cE "^  defp (attach_and_subscribe|remove_auto_subscriptions|default_blockee_subscriptions|default_blocker_subscriptions|blockee_identifier_for|blocker_identifier_for|blocker_critical_event\?|blocker_critical_topic\?)\(" src/lib/aiur/orchestrator.ex` = 0.
- No operator-message internals remain in the facade:
  `grep -cE "^  defp (enqueue_validated_operator_message|enqueue_for_running_entry|enqueue_after_reactivate|enqueue_after_resume|do_enqueue_running_operator_message|normalize_delivery_request|validate_operator_message|deliver_now\?|event_digest_delivery_opts|trusted_comment_wake_required\?|trusted_comment_event_digest\?|comment_event_topic\?|queue_wake_required\?|no_active_turn\?|operator_item_text|accepted_delivery_policies)\(" src/lib/aiur/orchestrator.ex` = 0.
- The public API is still reachable on the facade:
  `grep -cE "^  def subscribe_for_declared_blocker\(" src/lib/aiur/orchestrator.ex` = 1
  (the delegating wrapper).
- The `FI-EVT-034` reserved literal survived the move:
  `grep -c "branch.force-push" src/lib/aiur/orchestrator/auto_subscriptions.ex` >= 1.
- New modules are NOT coverage-exempt:
  `grep -cE "Orchestrator\.(DigestCoalescer|TrackerHealth|AutoSubscriptions|IssueSync|OperatorMessages)" src/mix.exs` = 0.
- A test file exists per extracted module:
  `test -f src/test/aiur/orchestrator/digest_coalescer_test.exs && test -f src/test/aiur/orchestrator/tracker_health_test.exs && test -f src/test/aiur/orchestrator/auto_subscriptions_test.exs && test -f src/test/aiur/orchestrator/issue_sync_test.exs && test -f src/test/aiur/orchestrator/operator_messages_test.exs`.
- `git diff --name-only origin/v2...HEAD` lists exactly the 11 files in
  **Files** — in particular NOTHING under `src/test/aiur/regression/` and no
  `src/mix.exs`.
- The full Agent gate below passes.

### Test content (each new file — build `%Aiur.Orchestrator.State{}` structs
directly, all fields default; test only through public functions; no GenServer):

- `digest_coalescer_test.exs`: `merge_events_digest_items/2` produces a single
  item whose events are sorted by ascending id and deduped by
  `(topic, comment_id)`; `event_sort_key/1` returns the integer `id` for
  `%{id: n}` and `%{"id" => n}` and `0` otherwise; `event_dedupe_key/1` yields
  the topic+comment-id pair. If `coalesce_events_digests/3` needs a store, build
  it with `AgentQueueStore` and assert one coalesced delivery out of three
  enqueued digests.
- `tracker_health_test.exs`: `normalize_github_backoff_ms(:escalate, state)`
  returns `GitHubConnectivity.max_backoff_ms()`; a non-negative integer passes
  through; any other value returns `state.poll_interval_ms`.
  `connectivity_classification/1` maps `{:github_api_status, 429}` → `:rate_limited`,
  `{:github, c, _}` → `c`, anything else → `:transport`. `next_poll_delay_ms/1`
  falls back to `state.poll_interval_ms` when `github_poll_delays` is empty and
  returns the max stored delay otherwise.
- `auto_subscriptions_test.exs`: `default_blockee_subscriptions("42")` returns
  the exact 9-topic set including `"ticket.42.branch.push"`,
  `"ticket.42.branch.force-push"`, `"ticket.42.agent.decision.*"`,
  `"ticket.42.agent.blocked"`, `"ticket.42.agent.unblocked"` (the `FI-EVT-058`
  contract); `default_blocker_subscriptions("42")` returns only the
  blocked/unblocked pair; `blocker_critical_topic?/2` is true for a
  `branch.push` / `branch.force-push` / `agent.unblocked` / `agent.decision.*`
  topic from a direct blocker and false for an unrelated ticket;
  `direct_blockers_for/2` reads `state.last_polled_issues`.
- `issue_sync_test.exs`: `blocker_map/1` folds `%Issue{blocked_by: [...]}` keyed
  by `:id`, skips non-binary ids, and returns `%{}` for a non-`%Issue{}`;
  `dependency_event_dedupe_key/3` joins the non-nil parts with `":"`;
  `dependency_causal_refs/2` rejects nils; `sync_todo_capacity_alert/2` sets
  `todo_over_capacity_alert_active` true when routable-unblocked todo issues
  exceed the cap and clears it when they drop back under (the `FI-ORC-050`
  edge-triggered latch — build a `%State{}` with a known cap and two todo
  `%Issue{}`s).
- `operator_messages_test.exs`: `validate_operator_message/1` returns
  `{:error, :empty_message}` for `""`/whitespace, `{:error, :message_too_long}`
  for a >8000-char body, and `{:ok, trimmed}` otherwise;
  `normalize_delivery_request/3` covers the full table (`:auto` +
  `%{immediate_delivery: true}` → `:immediate`; `:auto` + no support →
  `:checkpoint`; `:immediate` + no support → `{:error, ...}`; `:interrupt` +
  `%{can_interrupt: true}` → `:interrupt`; `:interrupt` + `:queue_next` fallback
  + no support → `:checkpoint`; unknown → `{:error, ...}`);
  `accepted_delivery_policies/2` returns `[:immediate]`, `[:checkpoint, :interrupt]`,
  and `[:checkpoint]` for its three input shapes.

## Verification
### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```
### At-merge (reviewer)

- Check: `git diff --color-moved=dimmed-zebra origin/v2...HEAD -- src/lib/aiur/orchestrator.ex src/lib/aiur/orchestrator/digest_coalescer.ex src/lib/aiur/orchestrator/tracker_health.ex src/lib/aiur/orchestrator/auto_subscriptions.ex src/lib/aiur/orchestrator/issue_sync.ex src/lib/aiur/orchestrator/operator_messages.ex`
  shows the moved bodies as moved (dimmed), not rewritten; the only in-body
  edits are module-qualification of the calls listed in Scope step 8.
- Check (FI-EVT-058 / FI-EVT-034 subscription set intact): in
  `auto_subscriptions.ex`, `default_blockee_subscriptions/1` still builds all
  nine `ticket.#{blocker_identifier}.*` topics verbatim — including
  `branch.push`, `branch.force-push`, `pr.opened`, `pr.merged`,
  `agent.decision.*`, `agent.blocked`, `agent.unblocked`, `agent.attention.*`,
  `issue.commented` — with reason `"blocker:auto"`, and
  `default_blocker_subscriptions/1` uses reason `"blockee:auto"`.
- Check (FI-ORC-049 public API): `Orchestrator.subscribe_for_declared_blocker/2`
  still exists as a public `def` in the facade and delegates to
  `AutoSubscriptions.subscribe_for_declared_blocker/2`;
  `grep -n "subscribe_for_declared_blocker" src/lib/aiur/agent_runner.ex` still
  resolves against the facade.
- Check (FI-ORC-051 cap): `operator_messages.ex` contains
  `@max_operator_message_chars 8_000` and `validate_operator_message/1` compares
  `String.length(text) > @max_operator_message_chars`.
- Check (FI-ORC-050 latch): `issue_sync.ex` `sync_todo_capacity_alert/2` still
  gates on `not state.todo_over_capacity_alert_active` before emitting and clears
  the flag when back under capacity (single-fire latch).
- Check (FI-ORC-041 escalate): `tracker_health.ex`
  `normalize_github_backoff_ms(:escalate, _state)` returns
  `GitHubConnectivity.max_backoff_ms()` verbatim.
- Check (FI-ORC-052 coalesce): `digest_coalescer.ex` dedupes by
  `(topic, comment_id)` and rebuilds one summary; the facade
  `{:claim_next_queue_item, ...}` `handle_call` calls the wrapper unchanged.
- Run the named pins:
  `mix test test/aiur/orchestrator_events_digest_coalesce_test.exs test/aiur/orchestrator_auto_subscribe_test.exs test/aiur/orchestrator_firehose_test.exs test/aiur/orchestrator_status_test.exs test/aiur/orchestrator_deactivate_test.exs test/aiur/alerts_test.exs test/aiur/agent_queue_test.exs test/aiur/github_issue_dependencies_test.exs test/aiur/github_auth_preflight_test.exs test/aiur/agent_control_cli_test.exs test/aiur/core_test.exs test/aiur/regression`
  — all green with zero skips.
- Behavior spot-check on `v2` after merge: start `aiurdev` against the sandbox
  repo, have one agent declare a blocker on another ticket, push a commit to the
  blocker branch, and confirm the paused blockee auto-resumes (the
  subscribe-half wiring survived the move) with unchanged log strings.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
