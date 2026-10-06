# MP-E1 build queue: chunks, candidate tickets and research questions

This file decomposes [plan.md](plan.md). Evidence is in
[findings.md](findings.md) (F-numbers).

**Every implementation ticket below is blocked on
[DESIGN-E1](../../owner-design-tasks/DESIGN-E1.md).** Ticket IDs are
`MP-E1-C<n>-T<m>`.

Each ticket carries these cross-reference fields:
- `Prior-units: U2, U3, U5` (as relevant)
- `Prior-boundaries` (from BO #30, ORC #12, DSP #13, CLI #31, WEB #34, BUS #10)
- `Base-SHA: 45a290e3` until refreshed
- `Size-owner` for any file over 500 lines it touches

Test rule (AGENTS.md): every new test must fail with its production hunk
reverted. The PR body names the revert command and the result.

## Dependency overview

```text
DESIGN-E1 ──► C1 (core seams) ──► C3 (store + server) ──► C5 (attention) ──► C9 (conventions, e2e)
              C2 (pure core) ──┘        ▲    │                                  ▲
                                        │    ├──► C6 (CLI + config docs) ───────┤
              C4 (sources/observer) ────┘    ├──► C7 (progress + milestones) ───┤
                                             └──► C8 (dashboard view) ──────────┘
```

**Can run in parallel:**
- C1 and C2.
- C4 alongside C3, once the C2 types are fixed.
- C6, C7 and C8, after C3.

**Release ordering constraint:** the C1 marker registration ships in a release
**before** any build that writes the marker (plan §8, rollback).

---

## MP-E1-C1 — Core seams (marker, heal exemption, hints, claim probe)

**Outcome:** core Aiur tolerates and supports a queue, with no queue running.
Dispatch order and API calls are unchanged when the queue is absent.

**Depends on:** DESIGN-E1 (OQ-3 and OQ-4). Cross-feature: X-1 (an MP-R1 seam
amendment).

| Ticket | One line |
| --- | --- |
| C1-T01 | Register the `queued` marker suffix in `github/labels.ex` (`@marker_suffixes`, `label_set/2` seeding). Add `Issue.queued?` set at ingestion (`github/issues.ex:1011-1012` pattern) |
| C1-T02 | `IssueSync`: treat `queued?` as deliberate parking in `heal_or_leave_missing_state_label/3` and `legitimately_unowned?/1` (`issue_sync.ex:195-207, 392-395`) |
| C1-T03 | Keep `{number, label_names, updated_at}` for every open issue the poll already reads, in `OpenIssueSnapshot` or a sibling ETS table, so queue observation costs no new reads (F8; RQ-5) |
| C1-T04 | `Aiur.BuildQueue.Hints` ETS reader, plus a `DispatchPolicy` hook: `sort_issues_for_dispatch/1` prepends `Hints.rank/1`, and `dispatch_state_decision` gains `{:skip, :build_queue_hold}` |
| C1-T05 | `ClaimProbe` implementation in orchestration: `claimed?/1` from `running`, `claimed`, `retry_attempts` and `auto_resume` inside the orchestrator call; `notify_demand/1` delegates to `note_queued_demand/1` |
| C1-T06 | Source-scan test: no `Aiur.Orchestrator` or `Aiur.GitHub` reference under `build_queue/`; `Aiur.BuildOrder` only in `sources/build_order.ex` (R1 seam rules) |

**Tests:**
- `test/aiur/github/labels_test.exs`: `agent:queued` + `agent:todo` parses to
  one state label. The swap keeps `agent:queued`.
  - Mutation check: drop the suffix from `@marker_suffixes`, and the test must
    fail with `contradictory_state_labels`.
- `test/aiur/orchestrator/issue_sync_*`: a ticket last polled as `todo`, now
  marker-only, is not healed.
  - Mutation check: remove the exemption, and `update_state_fun` is called with
    `"todo"`.
- `dispatch_policy_test.exs`: with no Hints table, the sort equals today's sort
  on a fixture of 20 issues. With a table, a rank-1 item precedes a `priority:1`
  item that has rank 0. A held item is skipped with `:build_queue_hold`.
- A ClaimProbe test against a test orchestrator: `true` for a running entry that
  still carries only todo (F4); `:unavailable` when the orchestrator is down.

**Research:** RQ-3, RQ-5. **Size-owner:** `dispatch_policy.ex`, `issue_sync.ex`
(U8 ledger).

## MP-E1-C2 — Pure domain core

**Outcome:** deterministic, process-free functions for readiness, ranking and
action planning.

**Depends on:** DESIGN-E1 (OQ-1, OQ-2, OQ-3).

| Ticket | One line |
| --- | --- |
| C2-T01 | `model.ex`: Queue, Item, Edge, Observation, Intent structs; JSON encode and decode with `version: 1` |
| C2-T02 | `readiness.ex`: per-edge verdict and per-item readiness (contract §2.1–2.2), including cycle detection reusing the `GraphAnalysis.analyze/2` approach |
| C2-T03 | `ordering.ex`: `downstream_open` via transitive closure; the rank key (plan §5.6 with OQ-1 applied) |
| C2-T04 | `planner.ex`: `(queues, observations, intents, claim answers) → [action]`, where actions are `promote`, `begin_withdraw`, `withdraw`, `hold_release`, `attention_open`, `attention_resolve`, `mark_override`, `mark_external_hold`, `dequeue` |

**Tests:** table-driven unit tests, plus property tests.
- Every row of contract §2.1 and §2.3.
- Two prerequisites, one failed and one pending → `failed`.
- A cycle → `unknown`.
- A stale observation → no `promote` action.
- A todo label not matched by an intent → `mark_override`.
- The planner is idempotent: applying the same inputs twice gives an empty
  second action list.

## MP-E1-C3 — Store, server and write protocol

**Outcome:** a supervised, optional `Aiur.BuildQueue.Server` that reconciles,
writes labels safely, and survives restarts.

**Depends on:** C1, C2, DESIGN-E1.

| Ticket | One line |
| --- | --- |
| C3-T01 | `store.ex`: a `Config.Paths` key `build_queue_dir` under `decision_state_dir`; `JsonStore.write!` with atomic rename and fsync (F9); fail closed on corrupt data |
| C3-T02 | `server.ex` reconcile loop. Triggers: after each tracker poll (RQ-5), Exchange hints (`ticket.*.pr.merged`, `ticket.*.issue.label.added.agent.*`, `ticket.*.agent.attention.error-*`, `ticket.*.dependency.merged_blocker_reconciled`), ResourceStore `:issue`/`:issue_dependency` changes, and a fallback timer |
| C3-T03 | Write protocol: persist the intent → `Tracker.add_label`/`remove_label` → persist the outcome; pacing (`max_writes_per_minute`); backoff; pause on a GitHub budget hold |
| C3-T04 | Withdrawal protocol (contract §2.4), with Hints hold and ClaimProbe |
| C3-T05 | Competing-writer detection: override and external hold (plan §5.8) |
| C3-T06 | Restart recovery: resolve dangling intents by observation; `queue recover` rebuilds from markers |
| C3-T07 | Config section `build_queue.*`, `Aiur.Config.Schema.BuildQueue`: `enabled`, `reconcile_interval_seconds`, `max_writes_per_minute`, `observation_max_age_seconds`, `merged_open_grace_seconds`; supervision child gated on `enabled` |

**Tests (integration, with an in-memory tracker double that records calls):**
- AC1, AC4, AC5, AC6, AC7, AC10, AC11 from plan §7.
- Crash between intent and outcome: run the server, kill it after the
  `add_label` call returns, restart, and assert exactly one `add_label` call
  overall.
- Pacing: 30 ready items at 20 per minute take 2 windows.
- Fixture rule: the tracker double must expose the zero-label heal path (run a
  real `IssueSync` pass), so AC4 cannot pass vacuously.

## MP-E1-C4 — Sources and observation

**Outcome:** prerequisites and observations come from real data at bounded
cost, and Build Orders stay optional.

**Depends on:** C2 types, C1-T03. Cross-feature: MP-R2 E-A3 (closed-unmerged
topic).

| Ticket | One line |
| --- | --- |
| C4-T01 | `sources/executor_list.ex`: local ordered list with "after" edges; one-owner rule |
| C4-T02 | `sources/build_order.ex`: adopt a root through `GraphProjection.demand/2` and `selected/2`; map native edges; health not `usable?` → `unknown` (F6); refresh on member change |
| C4-T03 | Native `blocked_by` of queued items, from ResourceStore `:issue_blocked_by` within the `BoundedBlockedBy` TTL (RQ-2) |
| C4-T04 | Closed-prerequisite `state_reason`: one conditional read per newly closed prerequisite, cached as terminal (RQ-8); request origin `build_queue_observe` so `aiur github-cost` attributes it |
| C4-T05 | Failed-PR signal: a ticket PR closed unmerged with no open PR (RQ-1) |
| C4-T06 | Merged-but-open detection: `pr.merged` hint, then the issue is still open after `merged_open_grace_seconds` |

**Tests:**
- The Build Order source, with a stale snapshot fixture built from real
  `ProviderHealth` values, yields `unknown`. With the source module absent,
  ExecutorList still works.
- Cost test: 30 queued items over 10 reconciles with no change make zero tracker
  reads beyond the poll. Assert on the request recorder, not on a constant.

## MP-E1-C5 — Attention and events

**Outcome:** one deduplicated, restart-safe attention per cause. Events are
published inside the reserved namespaces.

**Depends on:** C3.

| Ticket | One line |
| --- | --- |
| C5-T01 | `attention.ex`: the only caller of `Aiur.Alerts.emit_system/2`; latches kept in the store; `.resolved` on clear (pattern: `issue_sync.ex:557-608`) |
| C5-T02 | Prerequisite-failed alert naming the prerequisite, its cause and every transitively blocked item |
| C5-T03 | `ExecutorBindings`: add `ticket.*.queue.attention.#` and `system.queue.attention.#` (`#` so the `.resolved` suffix also matches) |
| C5-T04 | Publish the `ticket.<id>.queue.*` live events (contract §4.3) |
| C5-T05 | `promoted_unauthorized` detection from the dispatcher's decline (RQ-7) |

**Tests:**
- AC3: one alert for two dependents; no re-fire after a restart; resolve when
  the prerequisite leaves `agent:error`.
- Mutation check: remove the latch, and the restart test must see two firings.

## MP-E1-C6 — CLI and documentation of controls

**Outcome:** D7 controls as `aiur queue …` in both `aiur` and `aiurdev`.

**Depends on:** C3; the DESIGN-E1 CLI output approval.

| Ticket | One line |
| --- | --- |
| C6-T01 | `aiur-engine.sh`: a `queue)` arm, a usage line and `cmd_queue` calling `run_control_rpc "Aiur.AgentControlCLI.queue(...)"` (F9); timeout sizing like `run_todo` |
| C6-T02 | `Aiur.BuildQueueCLI`: verbs per DESIGN-E1; `--json` read model (contract §3); exit codes 0, non-zero and 124 |
| C6-T03 | Refuse mutations in agent workspaces, reusing the `--test` guard (RQ-6) |
| C6-T04 | Docs: `website/docs-app/reference/cli.md` (queue verbs; `--todo --only` now holds queue items); `reference/configuration.md` (every `build_queue.*` key, so `scripts/check-config-docs.py` passes); `.aiur/examples/` and `src/examples/workflows/` templates |

**Tests:**
- CLI tests mirroring `build_orders_cli*_test.exs`.
- A shell test for argument parsing.
- `--json` schema snapshot.
- An unknown or stale source renders as `unknown`/`stale`, not `0`.
  - Mutation check: replace that branch with `0`, and the test must fail.

## MP-E1-C7 — Build progress facts and milestones

**Outcome:** contract §4: progress facts for every queue and Build Order root,
and milestone events with no bursts or repeats.

**Depends on:** nothing for C7-T01 and C7-T03 (Build Order milestones need no
queue); C3 for the queue producer C7-T02. RC-08 names MP-E1-C7 as the producer of
`system.build_order.<root>.progress` and `system.queue.<id>.progress`.

**Component owner (RC-40):** `Aiur.BuildProgress` (`src/lib/aiur/build_progress.ex`)
belongs to the `build-orders` component. MP-E1-C7 writes the code; the queue is one
producer (C7-T02) and the Build Order observer is the other (C7-T03). D18's default
progress notifications therefore work without the queue.

| Ticket | One line |
| --- | --- |
| C7-T01 | `Aiur.BuildProgress` (`build_progress.ex`, `build-orders` component): `put_fact/1`, `facts/1`, `subscribe/0`, durable milestone latch per scope generation, highest-milestone-only emission |
| C7-T02 | Queue progress producer `build_queue/progress.ex` → `BuildProgress.put_fact/1` |
| C7-T03 | Build Order observer `build_order/progress_observer.ex`: catalog `RootSummary.progress` → facts |

**Tests:**
- 20% → 80% in one step emits only 75.
- A restart at 80% emits nothing.
- A root reopened after 100% starts a new generation.

## MP-E1-C8 — Read-only dashboard view

**Outcome:** the DESIGN-E1 view, with every state in its §4.

**Depends on:** C3, C7; dashboard approval in DESIGN-E1.

| Ticket | One line |
| --- | --- |
| C8-T01 | LiveView (`/queue` or a panel on `/build-orders`, per DESIGN-E1) subscribing to a `build_queue:changed` PubSub topic from the Server |
| C8-T02 | Item rows, rank explanation, prerequisites, attentions, data age |
| C8-T03 | Sidebar and docs page (`website/docs-app/guide/`), if it is a new page |

**Tests:**
- LiveView tests for each state.
- A browser check at desktop and phone widths.

## MP-E1-C9 — Conventions, concept docs, end-to-end acceptance

**Outcome:** skills and docs describe the new model, and the feature is proven
in a real run.

**Depends on:** C3–C8; DESIGN-E1 OQ-7.

| Ticket | One line |
| --- | --- |
| C9-T01 | Update `.claude/skills/aiur-build` (creation labels; the reconciliation test currently rejects `agent:queued`, F10) and `aiur-run` (queue usage, override semantics) |
| C9-T02 | `website/docs-app/concepts/ticket-lifecycle.md` marker table; `concepts/build-orders.md` "Queueing a Build Order"; `skills.md` if a skill changes |
| C9-T03 | AC12, end to end through `scripts/aiurdev --test` in the wrapper tmux (AGENTS.md recipe), with `tmux capture-pane` evidence that the second agent starts |
| C9-T04 | Budget note in the PR: label writes and observation reads per hour from `aiur github-cost` during C9-T03, with population counts (AGENTS.md "A claimed saving must be measured": this is instrumentation only, and claims no saving) |

---

## Research questions (Phase C)

| ID | Question | How to settle |
| --- | --- | --- |
| RQ-1 | Where to observe "ticket PR closed unmerged" without a new read: the ResourceStore `pull_request` deposit (`apis/github.md:507`), the firehose `PullRequestEvent`, or the R2 topic E-A3? | Read `events/github_firehose.ex`, `github/delivered_pull_request.ex`, `github/resource_store.ex`; agree with the MP-R2 planner |
| RQ-2 | Can every queued item's native `blocked_by` be read from ResourceStore without a per-item fetch, and what does a miss cost? | Read `bounded_blocked_by.ex:81-185`; count the misses in a fixture run |
| RQ-3 | Does `POST /issues/:n/labels` create a missing label? How do existing repos get `agent:queued` (re-run `aiur init`, or an ensure-label step)? | A sandbox repo experiment through the `--test` harness; read `aiur init` label seeding |
| RQ-4 | Can promotion be a conditional write ("add todo only if there is no state label")? | Read `issue_state.ex:97-219` for a reusable expected-empty check |
| RQ-5 | Which signal tells the Server a tracker poll completed, and where does it get open-issue labels (extend `OpenIssueSnapshot` or add a table)? | Read `orchestrator/snapshot_publisher.ex`, `tracker_health.ex`, `open_issue_snapshot.ex` |
| RQ-6 | How is the `--test` agent-workspace guard detected, and can `aiur queue` reuse it? | Read `aiur-engine.sh` around the guard message |
| RQ-7 | How the queue learns that a promoted item was declined `unauthorized` without referencing the orchestrator | Extend `ClaimProbe` with `dispatch_decline/1`, or read `dispatch_declines` (`orchestrator/state.ex:88`) through it |
| RQ-8 | Does `Tracker.fetch_issue_states_by_ids/1` return `state_reason`, and what does it cost? | Read `github/tracker.ex` and `github/issues.ex` |
| RQ-9 | Population census: Build Order sizes and promotion counts per hour in recent runs, to size pacing defaults | Count members of recent roots (e.g. #2573) with `aiur build-orders --json` |

## Cross-feature items for the coordinator

- **X-1 (MP-R1).** The component map allows orchestration → build-queue only
  through labels. This plan adds two narrow edges: the `Hints` ETS read in
  `DispatchPolicy`, and the `ClaimProbe` implementation in orchestration. D3
  ordering and the D8 race-free withdrawal need them.
- **X-2 (MP-R2).** The events contract §9 says the producer of
  `system.build_order.<root>.*` progress is Build Orders. This contract defines
  the payload, and C7 places the producer in `build_order/`. Confirm.
- **X-3 (MP-R2).** E-A3 requests a `ticket.<id>.pr.closed_unmerged` topic.
  *Resolved (RC-08, RC-26): registered by MP-R2-C5-T03, produced by MP-E1-C4-T05.
  X-2 is resolved by RC-08: the build-order progress producer is MP-E1-C7.*
- **X-4 (MP-N5).** Milestone semantics (highest milestone only, a generation
  rule) feed N5's no-burst requirement. N5 owns the per-device suppression.

---

## Phase C resolution of research questions (2026-10-06)

Final tickets: [tickets/README.md](tickets/README.md) (41 tickets; Phase D added
MP-E1-C3-T08, the `build_queue` capability provider, for X-21). The
chunk-level ticket lines above are superseded by the ticket files.

| ID | Resolution | Ticket |
| --- | --- | --- |
| RQ-1 | Read the `:branch_pull_request` deposit (`events/github_webhook/deposit.ex:630-642`) through a tracker callback; webhook mode only; no new request | C4-T05 |
| RQ-2 | `BoundedBlockedBy.fetch/2` (`github/bounded_blocked_by.ex:80-94`), called lazily only for ExecutorList items whose local prerequisites are satisfied. Same bound as the dispatch gate: at most one read per item per 15 min. Build Order items take native edges from the projection | C4-T03 |
| RQ-3 | `queued` in `@marker_suffixes` is seeded by `aiur init` (`label_set/2`) and by global-config startup (`global_config_startup.ex:81-86`). Existing repo-local installs: the queue ensures the label once through a new optional tracker callback `ensure_labels/1`, whose GitHub implementation calls `Labels.ensure/5` (422 `already_exists` = success, `labels.ex:154-194`). Whether `POST .../labels` auto-creates stays unverified and nothing depends on it | C1-T01, C3-T04 |
| RQ-4 | `expected_state: :none` in `IssueState` | C1-T04 |
| RQ-5 | `record_open_issues/3` (`github/issues.ex:437-441`) also records labels per open issue in `OpenIssueSnapshot` and broadcasts a PubSub signal | C1-T03 |
| RQ-6 | See plan §11 item 8 | C6-T01, C6-T03 |
| RQ-7 | Batched `ClaimProbe.status/1` reading `dispatch_declines` | C1-T06, C5-T04 |
| RQ-8 | `Issues.fetch_issue_raw_conditional/2` body carries `state_reason`; one read per newly closed prerequisite, cached terminal | C4-T04 |
| RQ-9 | **Open, non-blocking.** Not measured: the census needs the live daemon, which Phase C may not touch. Default pacing (20 writes/min) is a quarter of GitHub's 80/min secondary limit (F11). C9-T04 measures it | C9-T04 |
