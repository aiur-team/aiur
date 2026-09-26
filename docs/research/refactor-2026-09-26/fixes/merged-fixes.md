# Merged operational fixes: what held and what came back

Research for the 2026-09-26 refactor. Repo `aiur-team/aiur`, `origin/main` at `3339b88` (#2816).

## Scope and method

- **Population.** All 1,208 merged PRs, 1,272 issues and 339 closed-unmerged or open PRs, read through
  one paginated REST call (`issues?state=all`, bodies cut at 3,000 characters). 1,131 PRs map to a
  commit on `origin/main` or `origin/develop`. For those, files come from `git show --numstat` (squash
  merges) or a diff against the first parent (merge commits). The other 77 PRs were merged into
  side branches, so their files come from `pulls/{n}/files`.
- **Classification.** I classified all 1,208 titles by hand, and read the bodies where a title was
  ambiguous. **602 merged PRs are operational fixes (50%).** I excluded features, docs, website,
  Stream Deck, Build Order and analytics UI, the July refactor "waves", and security hardening unless
  an incident drove it. Each PR has exactly one area. The raw map is in
  `../scratch/cats.py` and the analysis script is `../scratch/analyze.py`.
- **Files** means `src/lib/**` paths touched per PR, with renames normalized. Each PR counts once
  per file.
- **Recurrence evidence** is a later issue or PR that describes the same symptom and cites the
  earlier fix. Many cite it explicitly ("regression of #2550", "despite #2627", "with #2815 on the
  build", "4th LocalHold site", "#2422 on a second path"). I found these by scanning every body for
  back-references and recurrence wording (`../scratch/recur_candidates.txt`), then read each chain.

Operational fixes are an ever larger share of merged PRs:

| month | merged PRs | operational fixes | share |
|---|---|---|---|
| 2026-05 | 39 | 7 | 18% |
| 2026-06 | 209 | 115 | 55% |
| 2026-07 | 325 | 105 | 32% (the refactor waves inflate the total) |
| 2026-08 | 499 | 273 | 55% |
| 2026-09 | 136 | 102 | **75%** |

---

## 1. Classification (ranked by fix count)

| Problem area | Fix PRs | Date range | Peak month | Modules the fixes touch most (fix-PR count) |
|---|---|---|---|---|
| O. Test flakiness and CI infrastructure (red main) | 123 | 05-22 – 09-24 | 08 (46) | `aiur.ex` (6), `workflow_store.ex` (4), `workflow.ex` (3). Most of these touch only tests. |
| H. GitHub API budget, cache, polling, webhooks, credentials | 107 | 06-24 – 09-10 | 08 (85) | `github/resource_store.ex` (21), `aiur.ex` (16), `github/transport.ex` (15), `github/quota.ex` (15), `github/client.ex` (13), `github/budget.ex` (13), `orchestrator.ex` (11), `events/github_webhook/deposit.ex` (11) |
| K. Workspace provisioning, ownership, isolation, process reaping, prewarm | 56 | 05-22 – 09-18 | 06 (22) | `workspace.ex` (12), `agent_environment.ex` (8), `repo_base.ex` (5), `config/codex_sandbox_policy.ex` (5), `workspace/ownership/store.ex` (5) |
| N. Daemon stability, supervision, mailbox blocking, launcher and control plane | 51 | 05-18 – 09-18 | 08 (22) | `aiur.ex` (11), `agent_control_cli.ex` (6), `orchestrator.ex` (4), `run_telemetry/writer.ex` (4), `orchestrator/snapshot_store.ex` (4) |
| J. Alerts, status truthfulness, control-CLI error surfacing | 44 | 05-22 – 09-26 | 08 (25) | `agent_control_cli.ex` (18), `orchestrator/dispatcher.ex` (8), `orchestrator/state.ex` (7), `orchestrator/status_report.ex` (7), `orchestrator/pause_resume.ex` (6) |
| F. Comment, review and event wakes (agents and Executor) | 35 | 06-22 – 09-18 | 06 (21) | `orchestrator.ex` (16), `events/github_comments_poller.ex` (10), `github/client.ex` (8), `events/github_firehose.ex` (7) |
| B. Host-load admission and the build gate | 28 | 06-23 – 09-04 | 07 (11) | `config.ex` (13), `config/schema/agent.ex` (10), `build_gate.ex` (9), `orchestrator/dispatch_policy.ex` (8) |
| L. Agent runtime and turn lifecycle (transport, stalls, continuation, resume) | 24 | 05-22 – 09-25 | 06 (10) | `codex/coding_agent.ex` (6), `agent_runner/turn_loop.ex` (5), `agent_runner.ex` (4) |
| E. Label state machine, lifecycle fence, review-to-rework routing | 23 | 06-24 – 09-26 | 08 (14) | `orchestrator/comment_wake.ex` (12), `orchestrator/lifecycle_fence.ex` (4), `orchestrator/human_review.ex` (4), `orchestrator/rework_gate.ex` (4), `orchestrator/issue_sync.ex` (4) |
| A. Dispatch eligibility, claims and slots | 21 | 06-24 – 09-26 | 08 (9) | `orchestrator/dispatcher.ex` (7), `orchestrator.ex` (7), `agent_control_cli.ex` (6), `orchestrator/state.ex` (5), `orchestrator/retry_engine.ex` (4) |
| G. CI lifecycle (ci-wait, verdicts, readiness) and merge gate/queue | 20 | 07-11 – 09-25 | 08 (12) | `orchestrator/ci_lifecycle.ex` (7), `events/github_ci_poller.ex` (4), `github/ci_readiness.ex` (3) |
| P. Config loading, base branch, identity resolution | 18 | 06-16 – 09-18 | 07 (7) | `prompt_builder.ex` (4), `workflow_store.ex` (4), `repo_base.ex` (3), `config.ex` (3) |
| M. Decision and Command delivery, expiry, dedup | 17 | 07-11 – 09-18 | 08 (9) | `decision_store.ex` (12), `decision_projection.ex` (5), `decision.ex` / `decision_event.ex` / `decision_history.ex` (4 each) |
| D. Pause, resume, duration caps | 13 | 06-23 – 09-25 | 08 (5) | `orchestrator/pause_resume.ex` (5), `orchestrator.ex` (6), `agent_control_cli.ex` (6) |
| C. Dependency (`blocked_by`) gating and unblock | 11 | 07-12 – 09-18 | 09 (5) | `orchestrator/dispatcher.ex` (5), `orchestrator/push_routing.ex` (4), `github/dependencies_api.ex` (3), `github/issues.ex` (3) |
| I. Provider rate- and usage-limit detection, pause and recovery | 11 | 06-30 – 09-26 | 09 (5) | `claude/notification_policy.ex` (4), `model_availability.ex` (4), `orchestrator/rate_limit_fallback.ex` (3) |
| **Total** | **602** | | | |

### The cross-cutting family the area split hides: stranded tickets

The areas are split by mechanism. By symptom, the largest single family is **a ticket stuck in a
state that no poll, timer or wake will ever release, so a human must relabel or `resume` it.** 55
merged fixes are this symptom (A, C, D, E, G, H, I, M): 2 in June, 1 in July, **29 in August and 23 in
September**. The rate is rising, not falling. The files they touch most are
`orchestrator/dispatcher.ex` (18), `orchestrator/state.ex` (15), `agent_control_cli.ex` (11),
`orchestrator.ex` (10), `orchestrator/comment_wake.ex` (10), `orchestrator/issue_sync.ex` (9),
`orchestrator/pause_resume.ex` (8), `orchestrator/ci_lifecycle.ex` (7) and
`orchestrator/waiting_reason.ex` (7). Three of today's open issues are still in this family:
#2817, #2818 and #2811.

196 of the 602 fixes touch an `orchestrator` file. Without the test-only area O, that is **192 of 479
(40%)**. Area E touches the orchestrator in 23 of 23 fixes, and area D in 12 of 13.

---

## 2. Recurrence analysis

**Verdict: every problem area recurred except a few with a structural fix, listed at the end.** A
fix that recurs almost always added a clause for one case: one entry shape, one call site, one pause
reason, one endpoint or one cap. The next incident arrives through a sibling case. The chains below
are in order of operational cost.

### 2.1 Lifecycle fence latches on an entry with no live agent — RECURRED (5 fixes, still open)

| when | fix | the case it covered |
|---|---|---|
| 07-18 | #1243 introduces `LifecycleFence` (for #1237) | fence lifecycle handoffs until the provider acks the queued input |
| 08-03 | #1414 (#1329) | a **terminal** observation held indefinitely; added the terminal grace window (`terminal_fence_expired?/1`) |
| 08-16 | #1931 (#1754) | the fence armed `rework` from any pending trusted digest and reverted approved PRs: **42 dispatches in 20 min** ("a third path" after #1758) |
| 09-24 | #2793 | a **deactivated** entry in `reconcile_observed_state/3` never closes. 13 "active" units against 5 live processes. |
| 09-25 | #2801 (#2800) | the **same latch in `handoff_blocked?/2`**: a green-CI ticket stuck in `ci-wait` for hours. The body says "#2793 fixed the same latch … `handoff_blocked?/2` was left unguarded". |
| 09-26 | #2815 | a **`:completed`, `pid: nil`** entry in `CommentWake.protect_active_comment_delivery/5` discards the rework write |
| 09-26 | **#2817 (open)** | "still strands a human-review ticket, **with #2815 on the build**": a second path or an incomplete fix |
| 09-26 | **#2818 (open)** | a todo ticket is not dispatched until `resume` is looped. The issue calls it "the same class as the strands fixed tonight — an entry in a state nothing polls". |

**Underlying cause.** The fence closes only through
`acknowledge_provider_delivery/2`, which needs a live provider process. The running entry has an
implicit state machine: `control.status` ∈ {working, paused, deactivated, completed} × `pid` present
or nil × 13 pause reasons. At least five functions pattern-match on that shape independently:
`reconcile_observed_state`, `handoff_blocked?`, `protect_active_comment_delivery`,
`CiLifecycle.pause_issue_for_ci_wait`, and the terminal-observation path. Each fix added one
(shape × function) clause. Only the terminal path has a timeout, so every non-terminal latch is
permanent by default.

### 2.2 Review → rework routing — RECURRED in both directions (13 fixes, 2 open)

- **False positives, where approved or addressed PRs are sent back to rework:**
  #1318 (07-24, a CI replay reverts `human-review`) → #1709 (08-10, rework "without new feedback") →
  #1758 (08-10, an addressed `CHANGES_REQUESTED` deadlocks tickets, because `reviewDecision` never
  clears) → #1931 (08-16, a third writer, the fence) → #1979 (unlabelled tickets acquire rework) →
  #2065 / #2158 (08-17/18, todo tickets and tickets with no PR get stamped rework) → **#2400 "still
  routes … re-raising #1756"** → #2423 (08-24) → #2433 (08-24, completed rework loops forever) →
  **#2451 (08-24, "#2422 on a second path": `merged_ticket_reconciler`)**.
- **False negatives, where a real request-changes is missed:** #2477 (09-02, body-only
  `CHANGES_REQUESTED` never moves the ticket) → #2620 (09-11, a second body-only review on a later
  head) → #2815 (09-26) → **#2817 open**, plus **#2621 open** (a stale review on an older head
  re-routes) and **#2794 open** (no cold re-derivation path).

**Underlying cause.** At least five writers decide "should this ticket be in rework?": the comment
wake, the human-review gate, the lifecycle fence, the merged-ticket reconciler and CI lifecycle. They
decide from GitHub's sticky aggregate `reviewDecision` plus per-event heuristics. No single function
derives the state from reviews and CI keyed to the **current head SHA**. Each fix gated one writer.

### 2.3 Slot accounting counts entries, not live work — RECURRED (6 fixes to one idea)

`State.@non_reserving_pause_reasons` (`orchestrator/state.ex:734`) has grown one reason per incident:
`:ci_wait` (#1019, 07-12) → `:blocker_dependency` (#1938, 08-16, "keystone can never be dispatched")
→ `:max_agent_duration` (#2333, 08-23) → `:usage_limit_exhausted` (#2813, 09-26, "AGENTS 20/20 with
16 paused reservations"). Related fixes to the same idea are #557 (06-24, retries exhausted on slot
starvation), #1066 (07-13, completed runners hold slots) and #2793 (09-24: the fleet read 12 of 12
busy while 8 of the 13 "running" entries were dead). **#2814 (open)** says the unlabelled-ticket routing branch "is the remaining
branch with the same shape".
**Cause:** a slot is "an entry in `state.running`", not "a live lease with an owner".

### 2.4 Pauses that nothing clears — RECURRED (≥9 fixes)

#915 (07-10, auto-pause without auto-resume) → #1561 (08-03, transient pause/error) → #1702 (08-10,
`resume` does not clear `agent:paused`, so the reconciler re-pauses) → #2269 (08-23, budget-hold pauses
never resume) → #2333 (08-23, duration pauses hold slots and resume times out) → #2567 (09-05, an
answered decision leaves the agent paused) → #2738 (09-18, a self-paused worker's decision is answered
but the worker is not resumed) → #2742 (09-18, a **stale `paused_reason` wins** over the usage-limit
kind) → #2804 (09-25, a self-pause blocks the very wake it waits for; "twin of #2558").
**Cause:** the source uses about 13 pause-reason atoms (`input_required`, `ci_wait`, `label_override`,
`global_pause`, `usage_limit_exhausted`, `blocker_dependency`, `operator_pause`, `github_budget_hold`,
`max_agent_duration`, `agent_pause_request`, `blocked_on_decision`, `before_run_failure`,
`pause_containment`). Each is set in one place and cleared by its own code elsewhere. No pause
records who owns it or what releases it.

### 2.5 Provider rate- and usage-limit recovery — RECURRED (9 fixes, 2 open)

#721 (06-30, Codex `usageLimitExceeded` abandoned as an opaque error) → #925 (07-11, Claude Remote
Control detection was a dead branch) → #1596 (08-09, fallback drops fenced work) → #2063 (08-17,
fallback replacement never cleared, so tickets park permanently) → #2627 (09-11, a Claude
session-limit exit counted as a turn failure) → **#2729 (09-18; #2727: "still counted as turn failure
… despite #2627", fleet stranded at `agent:error` for 3.5 h)** → #2742 (09-18, the Codex limit stalls
silently) → #2812 (09-26, 19 refusals re-armed a backoff past the provider's own reset) → #2813
(09-26, limited pauses held 16 of 20 slots) → **#2814 open, #2811 open** (each recovery burns one
refusal and one false alert per ticket).
**Cause:** each adapter detects a refusal from a different signal: stderr text, the stream-json
`provider_error` marker, `TurnError.codexErrorInfo`, or assistant text, which #2729 says to never
trust. No single typed "provider refused, resets at T" event exists. Recovery is split across
`ModelAvailability`, `RateLimitFallback`, pause reasons and slot reservations.

### 2.6 Dependency gating (`blocked_by`) — RECURRED, including a regression and an overcorrection

#1821 (08-11, a block is evaluated once and never re-checked) → #1932 (08-16, the tracker never
hydrated `blocked_by`) → #2546 (09-04, a closed blocker read as non-terminal) → #2553 (09-04,
`blocked_by` served from a never-revalidated store) → **#2710 (09-18; #2709 is titled "regression of
#2550": `hydrate_blocked_by/1` drops `revalidate`)** → **#2720 (the same day; #2714: the fix re-read
`blocked_by` unconditionally for every dependent every tick, "about two thirds of a daemon's core"
budget)**. An operator memory note says that every build before #2710 holds dependents after a
blocker closes.
**Cause:** freshness is a per-caller flag (`revalidate:`) on a shared store, not a property the store
owns (versioned deposits invalidated by `issue_dependencies` webhooks). One caller forgot the flag,
and the fix for that forgot the cost.

### 2.7 Bounded response collector returns a silent empty 200 — RECURRED (calibration case)

#1554 (08-03; #1454: the timeline cap of **64 KiB** is misreported as an HTTP failure and halts dispatch
fleet-wide) raised the cap to **512 KiB** → #2535 (09-03, the **same empty-200 shape** on the
open-issue list's 1 MiB cap, with an "impossible `{:github, :http, %{status: 200}}`") → **#2749 (09-20,
open)** and **#2816 (09-26)**: "This is **#1454 recurring at a higher ceiling** … Raising it a third
time guarantees a third occurrence." #2816 finally changed shape to a `per_page` ladder of 50 and 20,
but kept the cap. #2750, a competing fix, is still open. The firehose had the same kind of cap
problem: #530 bounded backfill → #2363 (08-23, "hits its 5-page cap every single tick").
**Cause:** `Transport.bounded_response_collector/1` signals truncation as a 200 with an empty body,
not as a typed `:truncated`. Each caller classifies it differently, and the size of real GitHub
payloads grows with how well a ticket is documented and how often it is referenced.

### 2.8 GitHub budget holds that turn into strands — RECURRED once per call site

#2010 (08-16, fleet idles at 0/16 on `github_quota` with full headroom) → #2239 (08-22, a
self-sustaining local 429 loop) → #2269 (08-23, budget-hold pauses never resume) → #2410 (08-23, a
transient hold **permanently errored ten tickets** with GitHub at 15/5000) → #2431 → #2445 (08-24,
auth preflight) → #2459 (08-25, preflight broker timeouts; "third") → **#2468 (09-02, "4th LocalHold
site", the merged-PR terminal write)**. #2427 states the cause directly: "the correct classifier
already exists and is used by one" of three paths.
**Cause:** the budget broker returns a hold to every call site, and each caller must know to wait or
defer. Every unaware caller is a strand waiting to happen.

### 2.9 GitHub spend — RECURRED as a moving target (107 fixes, 85 of them in August)

Early fixes: #678 (not planned) → #1388 (08-05) → #1705 (08-10, one token for the whole fleet) →
#1770 (08-10, catalog query) → #2064 (08-17, a 5 s poll) → #2084 ("did not fix": 5,000 points in
20 min). Then: #2229 (08-21, 96% of GraphQL spent by another consumer) → **#2245 open** (three
pollers bypass `ResourceStore`) → #2284 / #2296 (304s) → **#2372 (08-23, read cache regressed from
9.0% to 0.0% hit rate)** → #2385 → **#2413 open** ("three caches hold overlapping GitHub state and none
reads the others"). The dependency fix #2710 caused its own budget incident (#2714), which #2720 fixed. Three of the "savings"
were inert at merge (#2360, #2399, #2417; see #2439).
**Cause:** at least three caches (`ResourceStore`, `ReadCache` and the agent `gh` state cache) and
several poll paths, with no single read path.

### 2.10 Idle poll backoff (a cost fix) caused a dispatch-latency family — RECURRED 3×, 1 open

#2025 (08-16) added the idle backoff. Then: #2160 (08-23; #2138: resume or restart idles up to
20 min) → #2369 (08-24; #2365: a webhook cannot interrupt the backoff) → #2652 (09-16; #2640: newly
queued work cannot collapse it) → **#2818 open** (todo not dispatched until `resume` is looped).

### 2.11 CI-wait strands and merge-queue drift — RECURRED

- **ci-wait:** #1417 (08-05, deactivated recovery) → #1760 (08-10, `ci-wait` and `merging` tickets
  dispatched and burning the latch) → #2384 (08-24, `ci-wait` **never cleared** when CI finishes) →
  #2490 (09-02, wrong pause attribution) → #2721 (09-18, CI approvals lost at restart) → #2767
  (09-24) → #2801 (09-25, fence).
- **Draft and auto-merge:** #1649 → #1717 (approved PRs revert to draft) → #1895 (08-16, never
  auto-merge armed) → #2011 (08-16, finished PRs sit as drafts).

### 2.12 Label writers race — RECURRED; the first structural fix landed today

#2426 (08-24; #2420: remove-then-add leaves zero labels) → #2438 (08-24; #2437: contradictory labels
resolved alphabetically, so terminal states win) → #2384 (heal) → **#2808 (09-26; #2805: the agent's
`gh issue edit` raced the daemon's swap, and the heal kept the stale label)** → **#2610 / #2629 open**
(`agent:paused` is not a state label, which causes false alerts).
**Cause:** two actors write labels with no compare-and-swap, and "heal by precedence" treats the
symptom. #2808 adds an `aiur_set_ticket_state` tool, so agents stop hand-editing labels. That is the
first fix aimed at the cause.

### 2.13 Orphaned claims across restarts — RECURRED

#1833 (08-13; #1659: a turns=0 failure never releases its claim) → #2172 (08-23; #2076: a restart
orphans `in-progress` claims) → #2708 (09-18; #2705: runners orphaned by an Orchestrator restart hold
leases) → #2810 (09-26, a display mislabel of the reclaim window) → **#2818 open** (#390, an orphaned
claim).

### 2.14 Decision and Command answer delivery — RECURRED 5× on the delivery path

#1242 (07-17, answered decisions redispatched) → #1937 (08-16, a blocking decision expires while the
agent waits) → #2001 (08-16, an open blocking Command does not gate dispatch) → #2567 (09-05; #2558:
an answered decision fails delivery) → #2712, #2718, #2723 (all 09-18: withdraw or replace, deliver
to the next worker, timed-out send) → #2738 (09-18) → #2804 (09-25, "twin of #2558"). The
classification side recurred too: #2275 (08-22) → #2442 (08-24) → **#2301 open** (routine decisions
classified as `human_required`, which stalls tickets for 13+ h).

### 2.15 Alerts and status truthfulness — RECURRED at each surface

- **Re-raised or false alerts:** #1943 (08-16, resolution alerts re-emit every poll) → #2424 (08-24)
  → **#2460 (09-02; #2458: "#2424's fix, uncovered class", 148 alerts re-raised every boot)**.
  Capacity-starvation false alarms: #1598 → #2449 (08-24, fires on the ramp) → #2455 (09-03,
  silenced by a DecisionStore outage) → #2622 (09-11, fires on the dependency-declined backlog).
  **Still open:** #2811 (false alerts on recovery) and #2819 ("a main-red attention outlives the red
  it describes").
- **Silent control commands:** #541 (06-24) → #1720 (08-10) → **#1948 (08-16; #1736: "still fail
  silently … extend #1720's guarded seam")**. `aiur message`: #1800 (08-11) → #2155 (08-18,
  enqueued reported as delivered). `resume`: #1812 → #1874 → #2704 (09-18, a `function_clause`
  crash) → **#2536 open** (the same crash).
- **Silent dispatch declines:** #1723 (08-10) surfaced them. #2793 (09-24) then found that
  `:already_running` falls through `maybe_emit_dispatch_decline/3`'s catch-all, which **clears** the
  earlier decline.
- **Surfaces disagree:** #1801 (08-12) → #2700 (09-18, `status` and `agents` disagree about
  `waiting_for_human`) → **#2706 open**.

**Cause:** each site raises its own alerts, with no lifecycle keyed to the condition. Status is
projected separately by `status_report.ex`, `waiting_reason.ex`, the `agents` CLI and the dashboard.

### 2.16 Daemon supervision and Orchestrator mailbox — RECURRED

- **Mailbox:** #1501 (08-02; #1492: the dashboard blanks because snapshot reads queue behind
  dispatch) → **#1546 (08-03; #1543 is titled "recurrence of #1492")** → #1552 (the publisher is
  decoupled) → #1846 (08-12, blocking GitHub HTTP moved off the Orchestrator) → **#2537 open**
  ("orchestrator is unavailable" while it is idle).
- **Shared app children and `:application_controller`:** #2529 (09-03; **#2525 "recurred"**) →
  #2555 (09-04) → #2688 (09-17, "third") → #2691 → #2740 (09-18). Mostly triggered by test-induced
  restarts in a single shared application.
- **Control RPC latency:** #698 (06-30) → #888 → #2182 (08-19, `set max-agents` takes 10 s) → #2204
  (08-21, every command waited its full timeout) → #2694 (09-18) → **#2519 open** (`--todo --only`
  times out).

### 2.17 Workspace and processes — mixed

- **Git metadata writes: HELD after 4 attempts.** #542 → #565 (#561 "still lack") → #626 (#616
  "Regression") → #762 (07-07, #754 "still block"). No recurrence after 07-07.
- **Process reaping: RECURRED.** #426 / #458 / #501 (06-23/24) → #2080 (08-17, orphan shells halt
  dispatch) → #2179 (08-22, `aiurdev stop` orphans agents again) → #2391 (08-23, pause killed the
  operator's keyring) → **#2406 open** (PID reuse).
- **Sandbox writable roots: RECURRED.** #1314 (#1313, "came back") → #1413 → #2086 → #2283.
- **Prewarm: RECURRED, then turned off.** #441 → #571 → #1555 (#1404, the prewarm gate halts the
  fleet) → #2274 (#2237, an absorbing `:checking` state gates dispatch forever) → #2434. Prewarm was
  **disabled** in #2242 (08-21).
- **Agent credentials: RECURRED.** #2270 → #2378 → #2479 (09-02, the guard install deletes the shared
  credential, so no agent can push) → #2500 → #2701 (09-18, a rebuilt workspace has no GitHub
  support) → #2728 → **#2667 open**.

### 2.18 Load admission and the build gate — RECURRED

- **Build-slot leaks, 4 fixes in 6 days:** #1000 (07-12) → #1172 → #2153 (08-18) → #2351 (08-23) →
  #2386 (08-23; #2381: the backstop wedges in its own kill loop) → #2401 (08-23; #2398: the retain
  window saturates the gate).
- **Load gate not applied or latched:** #502 (06-24, default off) → #1804 (#1610: "load 100.95 while
  status reports binding: none") → #1840 (#1798, 8 builds against a cap of 2) → #2022 → #2098
  (#2089, dispatch drops tickets under load) → **#2530 (09-03; #2527: a latched stale sample keeps
  the fleet at 0/16 on an idle host)** → **#2564 open** (admission is per daemon).

### 2.19 Test flakiness — RECURRED by design (no mechanical guard)

- **Wall-clock waits:** #459 (06-23, a 500 ms `assert_receive`) → #1425 (07-31, a sweep of sub-second
  timeouts) → #1633 / #1688 / #1741 / #1752 (08-09/10, each one "uses the default 100ms
  assert_receive") → **#2087 (08-18; #2056: "one defect repeated 1,105 times")** → #2348 (08-23) →
  **#2757 (09-24) → #2796 open, "Bare assert_receive takes ExUnit's 100ms default"**. This is the
  calibration pair.
- **Global singletons:** #1015 (07-12) → #1007 recurred (closed not-planned) → #1815 (08-12; #1625:
  "71 GenServers default to `name: __MODULE__`") → #2165 (08-18) → #2524 de-quarantine (09-03) →
  **#2525 "recurred"** → **#2557 open**. TrackedSet: #685 → #785 → #1181 → #1647 ("still races").
- **Coverage shards:** #2285 → #2569 (09-05, shards are recut when a single file is added).

**Cause:** the fixes are sweeps. Nothing (Credo, a CI grep) stops new bare `assert_receive`,
`Process.sleep` or `name: __MODULE__` singletons from being added, so every sweep decays.

### 2.20 Config and base branch — HELD after consolidation

- **Base branch:** #912 (07-10) → #1174 (07-15) → #1693 (three PRs that "would delete 69,000 lines")
  → **#1714 (08-10)**. #1714 consolidated **nine hardcoded `"main"` fallbacks** (#1697 states this
  was the root cause of every earlier recurrence). #1972 retired `develop` (08-16). I found no
  wrong-base incident after that.
- **WorkflowStore reload:** #994 → #1219 → #1816 → #1918 → #2509 (09-03). This recurred mostly as
  test-isolation flakes (2.19).

### What held, and why

| Fix | Why it held |
|---|---|
| #1714 base-branch consolidation + #1972 retire `develop` | Removed nine duplicate authorities and the second branch. The merge-gate drift chain (#1466, #1544, #1658, #1672, #1925, #1954) also went quiet once `develop` was gone. |
| #762 workspace git-write validation (4th attempt) | It validates the capability rather than configuring one path |
| #966 / #964 FD and memory admission gates | Nothing later in the history recurred |
| #2379 retire the install tripwire (after #2371 raised it from 64 to 96 KiB) | The limit was removed, not raised |
| #714 / #1241 Codex transport EPIPE and queued-turn recovery | No recurrence after 07-18 |
| #2808 `aiur_set_ticket_state` (too new to judge) | The first fix that removes a writer instead of healing its output |

**Pattern:** the fixes that held **removed a duplicate authority, a second writer or a limit**. The
fixes that recurred **added a clause**.

---

## 3. Hot files

Columns: fix PRs touching the file; all merged PRs touching it (excluding develop→main promotion
squashes); lines ± in all of those PRs; areas that touched it; current length.

| # | File (`src/lib/aiur/…`) | Fix PRs | All PRs | Fix share | Lines ± | Areas | LOC now |
|---|---|---|---|---|---|---|---|
| 1 | `orchestrator.ex` | **75** | 110 | 68% | 15,236 | 13 of 16 | 996 (decomposed in July; fixes moved into `orchestrator/*`) |
| 2 | `agent_control_cli.ex` | **63** | 86 | 73% | 4,501 | 12 | **3,392** |
| 3 | `orchestrator/dispatcher.ex` | **54** | 65 | 83% | 3,522 | 13 | 2,654 |
| 4 | `aiur.ex` (the application: supervision tree and children) | 50 | 96 | 52% | 778 | 12 | 610 |
| 5 | `orchestrator/state.ex` | **49** | 61 | 80% | 1,109 | **all 16** | 1,027 |
| 6 | `config.ex` | 38 | 72 | 53% | 1,514 | 11 | 1,448 |
| 7 | `github/client.ex` | 32 | 45 | 71% | 5,590 | 8 | 388 (facade) |
| 8 | `agent_environment.ex` | 28 | 36 | 78% | 826 | 7 | 642 |
| 9 | `orchestrator/issue_sync.ex` | 23 | 25 | **92%** | 2,481 | 9 | 2,185 |
| 10 | `orchestrator/status_report.ex` | 23 | 38 | 61% | 2,110 | 10 | 1,426 |
| 11 | `orchestrator/pause_resume.ex` | 22 | 32 | 69% | 3,305 | 10 | 2,471 |
| 12 | `orchestrator/dispatch_policy.ex` | 22 | 26 | 85% | 1,547 | 8 | 1,205 |
| 13 | `github/resource_store.ex` | 22 | 23 | 96% | 4,420 | 2 | 2,191 |
| 14 | `agent_runner.ex` | 22 | 40 | 55% | 4,061 | 8 | 608 |
| 15 | `github/issues.ex` | 21 | 27 | 78% | 1,979 | 7 | 1,246 |
| 16 | `events/github_comments_poller.ex` | 21 | 24 | 88% | 1,621 | 4 | 854 |
| 17 | `orchestrator/comment_wake.ex` | 19 | 23 | 83% | 1,898 | 6 | 1,467 |
| 18 | `orchestrator/ci_lifecycle.ex` | 19 | 25 | 76% | 2,136 | 8 | 1,672 |
| 19 | `orchestrator/retry_engine.ex` | 19 | 27 | 70% | 2,026 | 10 | 1,540 |
| 20 | `decision_store.ex` | 18 | 32 | 56% | 5,867 | 5 | **4,826** |

By directory, fix PRs touch `orchestrator/*` 156 times, `github/*` 129, `events/*` 63 and
`config/*` 58.

**Churn cross-check.** Seven of the top ten by fix count are also in the top ten by total PR count:
`orchestrator.ex`, `aiur.ex`, `agent_control_cli.ex`, `config.ex`, `dispatcher.ex`, `state.ex` and
`github/client.ex`. The three files in the churn top ten but not the fix top ten carry feature
churn: `dashboard_live.ex` (52 PRs, 13 fixes), `config/schema.ex` (41) and `agent_runner.ex` (40). The
files with a **fix share of 80% or more** were changed almost only to repair them. They are the
clearest refactor targets: `issue_sync.ex` (92%), `resource_store.ex` (96%),
`github_comments_poller.ex` (88%), `dispatch_policy.ex` (85%), `dispatcher.ex` (83%),
`comment_wake.ex` (83%) and `state.ex` (80%). `state.ex` is the only file touched by all 16 areas. It
holds the running map, `@non_reserving_pause_reasons` and the entry shapes that 2.1, 2.3 and 2.4 turn
on.

---

## 4. Fix-quality patterns

1. **Missing regression tests are not the problem. Tests that do not constrain are.** Only 4 of 602
   fix PRs changed `src/lib` without touching `src/test` (#389, #582, #856, #1284). On 08-22, **#2338 found that 13 of 14 reviewed PRs shipped a test that passes with the
   change reverted** (`assert %{} = …`, self-comparisons, fixtures built to avoid the failure). The
   revert rule landed in #2350 (08-23). Recurrences still came after it: #2709 (a regression of
   #2550), #2727 ("despite #2627") and #2817 (with #2815 on the build). A unit test that fails
   without the change pins **one path**, and the recurrences arrive on a **second path**.
2. **A special case added to a growing list or `cond`.**
   - `@non_reserving_pause_reasons` grew to 4 entries in 4 incidents (2.3).
   - `LifecycleFence` gained a clause per entry shape: #1414, #2793, #2801, #2815 (2.1).
   - `DeliveryPolicy.deliver_now?/3` gained an exception for `:agent_pause_request` (#2804).
   - `@state_precedence` plus a `ci-wait` special case (#2438), then a "prefer the fresh handoff"
     rule that deliberately leaves the precedence list untouched (#2808).
   - The budget-hold wait was added once per call site: #2410, #2445, #2459 and #2468, the "4th
     LocalHold site".
   - The transient classifier was used in 1 of 3 paths (#2427).
   - Nine copies of `_ -> "main"` (#1697).
   - About 13 pause reasons, each with its own release code (2.4).
3. **A limit raised instead of removed.**
   - Timeline cap 64 KiB → 512 KiB (#1554), which recurred (#2749, #2816).
   - OpenAI-compatible tool rounds 32 → 256 (#1537).
   - Stall timeout 5 → 60 min (#787).
   - Codex startup reply 5 s → a 30 s floor (#703).
   - Install tripwire 64 → 96 KiB (#2371), then retired (#2379).
   - Test waits widened: #750, #1206, #1983, #2757.
   - ReadCache TTLs raised (#2321).

   Only the tripwire was later removed. The timeline cap is the case that demonstrably recurred.
4. **Fixes reverted or undone.** Formal reverts are rare: three commits in the whole history, none
   operational. The changes that were undone in effect are:
   - #2710's unconditional re-read was reversed the same day by #2720.
   - #1772 "widen polling on silence" was reversed by #2211 "degrade on evidence, not silence".
   - Prewarm was disabled (#2242) after five prewarm-hold fixes.
   - #2025's idle backoff needed three follow-up fixes (2.10).
5. **Inert fixes.** #2360, #2399 and #2417 claimed GitHub savings and measured zero at merge (#2439).
   The AGENTS.md "claimed saving must be measured" rule came out of this.
6. **Fast re-fix pairs** show a fix that treated the symptom:
   - #2793 → #2801: 1 day, the same latch in the next function.
   - #2815 → #2817: the same day.
   - #2710 → #2720: the same day.
   - #2627 → #2727: 7 days.
   - #2424 → #2458: 6 hours ("#2424's fix, uncovered class").
   - #1546 ← #1543: 1 day after #1501.

---

## 5. What the recurrences say to refactor

In order of the operational cost of the chains above:

1. **The running-entry state machine**, in `orchestrator/state.ex`, `lifecycle_fence.ex`,
   `comment_wake.ex`, `ci_lifecycle.ex`, `pause_resume.ex` and `dispatcher.ex`. Make
   `control.status` × liveness × pause reason an explicit type with one transition function. Give
   every latch (fence, pause, hold, reservation) an **owner and a release condition**: a liveness
   check or a deadline. Chains 2.1, 2.3, 2.4, 2.11, 2.13 and 2.14 are all "a latch whose release
   depended on a process that was gone".
2. **One ticket-state authority.** One pure function derives the desired `agent:*` state from labels,
   the PR head, reviews at the head, CI at the head and the running entry. One writer applies it
   (`IssueState.swap_labels/4`, which agents now reach through `aiur_set_ticket_state`). This
   replaces the five-plus rework writers (2.2) and the precedence heal (2.12).
3. **Slots from leases, not entries** (2.3). Any capacity decision reads live leases, so no pause
   reason needs an exemption list.
4. **One typed provider-refusal event** across the Codex, Claude, Remote Control and
   OpenAI-compatible adapters, with a reset time. It feeds one recovery owner (2.5).
5. **The GitHub access layer.** One read path whose freshness is owned by the store (2.6, 2.9). A
   typed `:truncated` from the bounded collector (2.7). One error classifier (#2427). Budget holds
   resolved at the broker boundary, not per caller (2.8).
6. **Alert lifecycle keyed to the condition, and one status projection** shared by `status`,
   `agents` and the dashboard (2.15).
7. **Test infrastructure guards, not sweeps.** A Credo or CI check that bans bare `assert_receive`,
   `Process.sleep` and `name: __MODULE__` in tests, and per-test application instances (2.16, 2.19).
