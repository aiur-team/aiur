# MP-E1 build queue: repository findings

All citations are against `origin/main` at `45a290e3`, read with
`git show 45a290e3:<path>`. Paths are under `src/lib/aiur/` unless they start
with another top-level directory. This file extends
[../../baseline/capability-baseline.md](../../baseline/capability-baseline.md)
§E1. It does not repeat it.

The plan is [plan.md](plan.md). The chunks are [chunks.md](chunks.md).

---

## F1. The readiness label and who may apply it

- The prefix is configurable: `tracker.github.label_prefix`, default `"agent"`
  (`config/schema/tracker.ex:27`). "The configured todo label" is
  `StatePolicy.state_label(prefix, "todo")` (`agent_control_cli.ex:1254`).
  This plan writes `agent:todo` for that label throughout.
- State suffixes: `todo in-progress ci-wait human-review rework merging done
  error cancelled canceled` (`github/labels.ex:25`). Marker suffixes:
  `watch paused parked rate-limit-fallback` (`github/labels.ex:31-35`).
  `label_set/2` seeds markers on `aiur init` (`github/labels.ex:46-53`).
- **Any unregistered `agent:<x>` label is parsed as a state label.**
  `state_label_suffix/2` returns every prefixed suffix that is not a marker
  (`github/issues.ex:1176-1187`). A new queue label must therefore be a
  registered marker. Otherwise `agent:<x>` plus `agent:todo` is two state labels,
  and `DispatchAuthorization.authorize/5` denies it as contradictory
  (`github/dispatch_authorization.ex:51-53`).
- Markers survive every state swap. `remove_state_labels/8` keeps any prefixed
  label whose suffix is a marker (`github/issue_state.ex:289-310, 411-424`).
- **Dispatch authorization** is decided by who applied the trigger label, read
  from the issue timeline (`dispatch_authorization.ex:55-73, 215-242`):
  - If the latest applier is in `allowed_users`, dispatch is authorized.
  - If the applier is Aiur's own login (`bot_account` or `daemon_account`,
    `:198-213`), dispatch is authorized only when some allowed user once
    applied **any** `<prefix>:*` label to the issue (`:127-148, 490-509`).
    Markers count toward this.
  - With `allowed_users` empty, the CODEOWNERS fallback includes the daemon and
    bot logins (`github/config.ex:485-490`; `github/code_owners.ex:27-29,
    380-392`). So by default a daemon-applied `agent:todo` is accepted.
  - Cost: one timeline read (paged 50/20, at most 400 events) for each
    `{id, label, updated_at}`, then cached (`:44-46, 578-616`).
- `aiur --todo` adds only `agent:todo`, with the daemon credential
  (`agent_control_cli.ex:854-893, 979-1024`). `--only` removes `agent:todo`
  from at most 50 other pending tickets (`:1082-1158`). It then calls
  `Orchestrator.note_queued_demand/1` (`:1195-1229`).

## F2. How labels are written

- The write path is `Aiur.Tracker.update_issue_state` → `GitHub.Tracker`
  (`github/tracker.ex:170-191`) → `GitHub.IssueState.update_issue_state`
  (`github/issue_state.ex:14-36`).
- **Add before remove** is already enforced (#2420). The new label is added,
  then the old ones are removed, and the just-added label is excluded from the
  removal (`issue_state.ex:199-219, 291-310`).
- `expected_state:` gives optimistic concurrency. A mismatch returns
  `{:error, {:stale_issue_state, ...}}` (`issue_state.ex:142-188`). A state
  write never relabels or reopens a closed issue.
- Endpoints (one call per label):
  - `POST /repos/:o/:r/issues/:n/labels` (`issue_state.ex:357-376`)
  - `DELETE .../labels/:name`, where 404 counts as success (`:336-355`)
- `WriteThrough.issue_labels` stores the response label array in
  `ResourceStore` (`github/write_through.ex:150-186, 254-291`). Label responses
  carry no version, so nothing is marked as handled
  (`website/docs-app/apis/github.md:694`).
- `Events.Publisher` drops events whose actor is `daemon_account`
  (`events/publisher.ex:405-423`). The queue therefore cannot use bus events to
  observe its own label writes, and must not rely on them.

## F3. The dispatch gate, ordering and capacity

- Eligibility order (`orchestrator/dispatch_policy.ex:718-886`):
  1. Identity: shape, routable, `dispatch_authorized?`, `paused`, `parked`.
  2. State: terminal, `merging`/`ci-wait`, not in `active_states`.
  3. `blocked_on_decision`, then `dependency`, `already_running`,
     `auto_resume_pending`, the claimed variants, `state_capacity`,
     `worker_capacity`.
  4. `Slots.available_slots/1 > 0` (`orchestrator/slots.ex:253-263`).
  5. The host admission gate (`dispatch_policy.ex:288-353`).
- `todo_issue_blocked_by_non_terminal?/2` applies only to `todo`
  (`dispatch_policy.ex:1000-1008`). A blocker releases its dependent when it is
  closed for any reason, or carries `done`/`cancelled`/`canceled`. A blocker in
  `agent:error`, or with no state label, keeps holding it (`:1043-1047,
  1113-1116`; `github/issues.ex:1091-1123`).
  - So a blocker closed as `not_planned` **releases** its dependents at
    dispatch. The Build Order view classifies the same edge as
    `:terminal_unsatisfied` (`build_order/edge_state.ex:9-22`).
- `blocked_by` is hydrated only at dispatch time, through
  `BoundedBlockedBy.fetch/2`. It has a 15-minute TTL, re-reads stale blocker
  state, and cross-checks closure against `OpenIssueSnapshot`
  (`github/bounded_blocked_by.ex:61-185`; `github/issues.ex:1043-1081`).
- Sort order: `sort_issues_for_dispatch/1` sorts by `{priority_rank,
  created_at, identifier}`, with `priority:N` labels giving ranks 1-4 and
  anything else 5 (`dispatch_policy.ex:609-622`; `github/issues.ex:1147-1161`).
  There are two callers: `dispatcher.ex:1004` and `issue_sync.ex:2123`.
- The edge-latched `system.dispatch.todo_capacity_exceeded` alert counts
  routable, unblocked `todo` issues (`orchestrator/issue_sync.ex:1473-1489`).

## F4. Claims: the window between dispatch and the agent's first relabel

- **The daemon does not write `in-progress` at dispatch.** It records the issue
  in `state.running` and `state.claimed` (`orchestrator/dispatcher.ex:2523-2566`).
  The agent moves `todo` to `in-progress` itself through
  `aiur_set_ticket_state` (`agent_runner/tool_executor.ex:76, 184-199`).
- So a ticket can be running while it still carries only `agent:todo`. A label
  check alone cannot prove "no agent has claimed it" (D8).
- `Orchestrator.list_running_active_identifiers/2` (`orchestrator.ex:653`) and
  `snapshot/2` (`:647, 675`) are GenServer calls. They return `[]` or
  `:unavailable` on exit (`orchestrator/status_report.ex:134-157, 373-420`), so
  an empty answer cannot be told apart from "orchestrator down". Neither exposes
  `claimed` directly.
- On a restart, `running` and `claimed` start empty. `StartupClaimReconciler`
  releases `in-progress` tickets that have no runtime back to `todo`
  (`orchestrator/startup_claim_reconciler.ex:112, 149-166`).

## F5. The zero-state-label heal will undo an un-promotion unless taught otherwise

- `IssueSync.heal_or_leave_missing_state_label/3` restores the last known state
  when a ticket shows zero state labels and an earlier poll saw one
  (`orchestrator/issue_sync.ex:392-429, 435-458`).
  - If the queue removed `agent:todo`, the previous poll's state was `todo`, so
    the heal writes `agent:todo` back.
  - Only `paused`, `parked`, `needs-triage`, `human:todo` and `epic:*` exempt a
    ticket (`:392-395, 479-494`).
- The strand sweep treats the same markers as legitimately unowned
  (`issue_sync.ex:195-207`).
- **Consequence:** the queue marker must be added to both exemptions in the
  same change that registers it.

## F6. Build Orders (an optional input)

- **Graph data.** `GraphProjection.selected/2` and `demand/2` return one root as
  `%Snapshot{data: %SelectedRoot{members}}` (`build_order/graph_projection.ex:46-59`).
  - Edges live in `Member.dependencies`, with `kind :native|:external|:unknown`
    and `direction :blocker_to_blocked` (`build_order/dependency.ex:6-24, 59-63`).
  - Per-root graphs are held for at most `graph_max_selected_roots` roots
    (default 32, `build_order/graph_projection_options.ex:26`).
  - `refresh/2` is an async forced re-read, coalesced with any in-flight read
    (`graph_projection.ex:61-78`).
- **Health.** `ProviderHealth.usable?/1` requires `:healthy`, `complete?` and a
  positive generation (`build_order/lifecycle.ex:47-51`). `EdgeState.classify/2`
  makes every edge `:unknown` when the snapshot is not usable, including when it
  is `:stale` (`edge_state.ex:9-22`). `Readiness.from_edges/1` ranks the results
  as cyclic > unknown > terminal_unsatisfied > blocking > ready
  (`edge_state.ex:31-41`).
- **Critical path.** `DependencyChain.closures/2` and `reachable/2` give the
  transitive downstream set of each node (`build_order/dependency_chain.ex:27-49`).
  Nothing calls them, and there is no count function.
  - `GraphAnalysis.analyze/2` provides SCC cycles and a topological order, with
    limits of 100 nodes and 10k edges (`build_order/graph_analysis.ex:10-11,
    120-187`).
- **Coupling.** Nothing in `orchestrator/` or `agent_runner/` references
  `Aiur.BuildOrder`.
  - GraphProjection is always started (`src/lib/aiur.ex:356-357`), and there is
    no config key to disable it.
  - The catalog is event-sourced from `ResourceStore` at zero GraphQL cost
    (`build_order/catalog_store.ex:32`).
- **Progress.** Progress is completed ÷ members with a valid lifecycle × 100
  (`build_order/github_graph/normalizer.ex:159-182`;
  `build_order/catalog_store.ex:125-150`). No progress event exists. Changes
  reach consumers only inside GraphProjection snapshot messages
  (`graph_projection.ex:1506-1515`).
- **Webhook gap.** The documented webhook event list does not include
  `sub_issues` or `issue_dependencies` (`website/docs-app/apis/github.md:712`),
  but the deposit handles both (`events/github_webhook/deposit.ex:327, 347-353`).
  Membership reconciliation reads GitHub every 15 minutes in every webhook mode
  (`apis/github.md:50-62`).

## F7. Merge-to-ticket association and failure signals

- **Merges.**
  - A `pull_request` delivery maps to a ticket only through the head branch
    `aiur/<id>-<slug>` (`events/github_webhook/normalizer.ex:768-787`).
  - Only `pr.opened`, `pr.ready_for_review` and `pr.merged` are published.
    **A PR closed without merging publishes nothing** (`normalizer.ex:645-652`).
  - On `pr.merged`, `CommentWake.mark_pr_merged_issue_done` writes `done` only
    when the PR body has a closing keyword for the ticket. Otherwise it writes
    `human-review` (`orchestrator/comment_wake.ex:30, 250-291`;
    `orchestrator/merged_ticket_reconciler.ex:175-215`).
  - The closing-keyword parser accepts same-repository references only
    (`recent_merge.ex:100-148, 428-448`).
- **Issue events.** There is no `issue.closed` topic. `issues` deliveries are
  reconcile hints only (`normalizer.ex:282-321`).
- **Topics that exist.**
  - Label flips: `ticket.<id>.issue.label.added.agent.<state>`
    (`orchestrator/issue_sync.ex:1087-1094`).
  - Entering error: `ticket.<id>.agent.attention.error-<cause>` (`:1078-1079`;
    `orchestrator/retry_engine.ex:868-878`).
  - Merge reconciliation: `ticket.<id>.dependency.merged_blocker_reconciled`
    (`merged_ticket_reconciler.ex:398`).

## F8. Observation cost: what the existing poll already sees

- The tracker poll reads every open issue with labels: an ETag-conditional
  `GET /issues?state=open&per_page=100` (`github/issues.ex:381-441`).
  - It keeps only issue numbers in `OpenIssueSnapshot.put/3` (`:437-438`;
    `github/open_issue_snapshot.ex:39`).
  - It then drops every issue that is not in `active_states` before dispatch
    (`:452-459`).
- So a waiting ticket (marker only, no state label) is fetched on every poll at
  no extra cost, but its labels are discarded. Keeping them for the queue needs
  a small seam (chunk MP-E1-C1).
- A closed prerequisite drops out of the open list. Its `state_reason` needs
  one read of the issue, once.

## F9. Alerts, durable state and the CLI

- **Raising an alert.** `Aiur.Alerts.emit_system(topic, opts)` (`alerts.ex:103-106`)
  takes `needs_attention: true`, `issue:` and `severity:`. It publishes to the
  exchange, appends to `AlertLedger`, and broadcasts (`:144-200`).
  - **Firing alerts are not deduplicated.** The caller must latch, for example
    with `AlertFeed.active_system_attention?/1` (`alert_feed.ex:64-69`).
  - The pattern to copy for one alert that names several tickets:
    `IssueSync.sync_contradictory_state_label_alert/3`
    (`orchestrator/issue_sync.ex:557-608`).
  - A new `system.*` topic reaches the Executor only if it is added to
    `ExecutorBindings` (`executor_bindings.ex:7-36`). `ticket.*.agent.attention.*`
    is already bound (`:26`).
- **Durable state.** `Config.Paths.decision_state_dir/0` is the per-instance,
  per-repository directory (`config/paths.ex:61-66, 322-358`).
  `JsonStore.write!` does an atomic rename with fsync (`json_store.ex:32-37`;
  `fs.ex:19-65`). Examples: `orchestrator/global_pause_store.ex`, and the
  GenServer `executor/claims.ex`.
- **CLI.** A subcommand is an arm in `aiur_engine_main`
  (`packaging/npm/aiur-cli/libexec/aiur-engine.sh` ~:4077-4150) that calls
  `run_control_rpc "Aiur.AgentControlCLI.<fn>(...)"` (`:2419-2470`).
  - The read-only JSON example to copy: `cmd_build_orders` (`:2958-2991`) →
    `AgentControlCLI.build_orders/1` (`agent_control_cli.ex:365-366`) →
    `BuildOrdersCLI.run/1`. Its sources carry `observed_at`, `age_ms` and
    `freshness` (`build_orders_cli.ex:21-27, 232-259`).
- **Naming collisions.**
  - `Aiur.AgentQueue`, `AgentQueueStore` and `AgentQueueItem` already exist and
    mean the agent message queue (`agent_queue.ex:1-53`). The new component uses
    `Aiur.BuildQueue`.
  - `aiur units --condition queued` already means "carries `agent:todo`"
    (`website/docs-app/reference/cli.md:99`).

## F10. Conventions that will change

- `aiur-build` and `aiur-run` require executable members to be created with
  `agent:todo` in the same request, blocked or not
  (`.claude/skills/aiur-build/SKILL.md:225-236`;
  `.claude/skills/aiur-run/SKILL.md:228-234`). Per-phase promotion is called
  "optional user complexity, never a hardcoded Aiur workflow" (`aiur-build/SKILL.md:222-223`).
  D4 now makes promotion Aiur machinery.
- The aiur-build reconciliation test rejects `agent:queued` as an unprojected
  label family (`.claude/skills/aiur-build/scripts/tests/test_github_reconciliation.py:48-55`).

## F11. External limits (authoritative sources)

| Claim | Source | Accessed |
| --- | --- | --- |
| Secondary limits: "no more than 80 content-generating requests per minute and no more than 500 content-generating requests per hour"; 900 REST points/min | https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api | 2026-10-06 (page lists no API version) |
| The "Add labels to an issue" page does not say whether a missing label is created | https://docs.github.com/en/rest/issues/labels#add-labels-to-an-issue (`X-GitHub-Api-Version: 2026-03-10`) | 2026-10-06 |

Whether adding a label that does not exist in the repository creates it is
therefore **unverified**. It is research question RQ-3 in [chunks.md](chunks.md).
The plan does not depend on that behaviour: chunk C1 seeds the label.
