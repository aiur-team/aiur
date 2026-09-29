# Gap analysis: time with no progress from the Executor or the agents

Research for the refactor of 2026-09-26. Window: 2026-08-18 to 2026-09-26 15:40Z.
Data is read-only. The machine-readable companion is [`gaps.csv`](gaps.csv), with one row per gap of 15 minutes or more (202 rows).

> **Privacy rule.** `<private-owner>/private-repo-a (private)` is a private repository. For it, this report gives
> only counts, durations and attribution categories. It gives no ticket numbers, titles, log text or
> paths from inside it. In `gaps.csv` its rows use `repo = private-repo-a (private)`, blank run identifiers and timestamps,
> and `evidence = private — omitted`. Numerical measurements are retained.

---

## Verification checkpoint (2026-09-26)

The [gap measurement audit](../synthesis/gap-measurement-verification.md) corrects
attendance quantization and separates model buckets from established causes.
The exact retained >=30-minute gaps total **727.7334 h**; the historical
minute-bin category sum is **727.8 h**. Do not combine them as identical measures.
`gaps.csv` retains the original `attended_frac` for provenance (67 of 202 values
exceed one) and adds the valid `duration_weighted_attended_frac`. Use the latter.
Historical causal claims below remain under verification unless a verdict says
otherwise; in particular, a missing progress event does not prove no useful work.

The [largest-gap audit](../synthesis/largest-gap-attribution.json) reproduces
151.3621 h but rejects a proven infrastructure cause or an automatic reassignment
to human waiting. The three neighboring gaps total 173.2840 h, with 0.4704 h of
their enclosing span outside them. Historical attendance 0.004 rounds to 0.00;
it does not prove no activity or operator absence. Twelve human-review issues
and five rework issues are label states, while todo #2394 already had an open PR.
The classifier infers eligibility from missing refusal evidence and gives an
unresolved alert precedence over waiting work.


**Uptime caveat:** the historical event-ID generator preserves reservations
across restarts, so the analyzer's event-ID quotient is not a guaranteed daemon
boot identity. The pre-log spans and gap percentages are retained-model results,
not verified continuous uptime or measured wasted time. See
[the uptime contract audit](../synthesis/gap-uptime-contract.json).


## 0. Headline

| Measure | Value |
|---|---|
| Retained active-span union within each repo, summed across repos | **961.9397 h** (638.6 h cross-repo union at stored minute precision); historical run-span sum 963.0758 h includes 1.1361 h overlap |
| &nbsp;&nbsp;historical raw run-log spans, 09-15 to 09-26 (first/last telemetry model) | 490.7 h: aiur 143.9, khala 185.3, private-repo-a (private) 161.6 |
| &nbsp;&nbsp;historical raw pre-log spans, 08-18 to 09-11 (unverified wake-ID inference) | 472.4 h: aiur 395.2, archon (formerly architecture-docs) 77.2 |
| Gap time, gaps ≥ 30 min | **727.7334 h = 75.6527 % of retained per-repo active-span unions** (108 gaps); category bins sum to 727.8 h |
| Gap time, gaps ≥ 15 min | 760.3 h (202 gaps) |
| Daemon-down time between runs (reported separately, not in the totals above) | 51.1 h khala after a host crash, plus deliberate idle periods (§6) |

**Attribution of gap time (gaps ≥ 30 min, minute by minute):**

| Category | All eras | % | Run-log era (current system) | % | Run-log, aiur + khala only | % |
|---|---:|---:|---:|---:|---:|---:|
| (a) agents idle, paused or stranded while the Executor was absent | 15.6 h | 2.1 | 12.1 h | 2.9 | 12.1 h | 4.6 |
| (b) agents waiting on an absent Executor (review, decision, credentials) | **181.0 h** | **24.9** | **173.3 h** | **42.1** | **172.6 h** | **65.9** |
| (c) Executor or human active, but not on this fleet's waiting items | 74.0 h | 10.2 | 58.5 h | 14.2 | 58.4 h | 22.3 |
| (d) infrastructure (dispatch starvation, session limits, usage limits, CI) | **279.6 h** | **38.4** | 6.5 h | 1.6 | 6.5 h | 2.5 |
| (e) no work queued | 144.4 h | 19.8 | 144.4 h | 35.1 | — | — |
| (f) agents working, no output yet (not idle; long turns) | 33.2 h | 4.6 | 16.9 h | 4.1 | 12.1 h | 4.6 |
| **Total** | **727.8 h** | | **411.8 h** | | **261.7 h** | |

Read the two eras separately, and distinguish model attribution from verified
cause. In run-log aiur/khala, **78.18% of gap bins are classified as waiting on
an Executor**: 172.57 h in b and 32.00 h in the waiting subset of c. That
classification does not establish that a human, rather than the daemon or a
coding-agent Executor, caused the delay. The stranded bucket is 38.52 h
(14.72%), but the existing gaps-10 check found both misclassified permission
waits and a real parked-entry/lifecycle-fence dispatch problem. Neither the
78% nor the 2.5% infrastructure bucket is a causal share. August starvation
causation and current-era source completeness remain under review.

**The three largest historical attribution buckets (causal checks incomplete):**

1. **Pre-log aiur infrastructure bucket (d), 257.2 h, not a single-defect cost.** The daemon raised
   a `system.fleet.capacity.starved` record with no resolution in the selected ID group. At the same time
   `system.dispatch.prewarm_blocked` has 71 blocked and 70 resolved records in the cited event-ID group, forming
   70 ordered pairs and one unclosed block. Pair durations range from 5.15 seconds to
   40.22 minutes; the median is 10.11 minutes. The group is not proven to be one boot.
   A successful transcript tool result records this point diagnosis on 08-21T18:42Z: *"Ready tickets=31, live agents=0, effective cap=1,
   dispatch constraints=prewarm build (prewarm=checking)"*. It filed #2237, *"Prewarm :checking is an
   absorbing state: a lost ls-remote probe gates fleet dispatch forever"*. The largest single item is a
   151-hour stretch (08-25 to 09-01). In that stretch twelve issues carried `agent:human-review`;
   the claimed six-day operator absence remains unverified. The 257.2 h equals 90.91% of pre-log aiur gap bins;
   the 86.40% figure instead uses all-pre-log d (273.0667 of 316.0333 h). Neither
   percentage establishes one defect's causal share.
2. **Agents waiting on an absent Executor (b), 181 h; 66 % of current-era aiur/khala idle time.** Dependency
   graphs make one human-blocked ticket block the whole fleet. For 4.6 days, khala waited on one paused
   ticket (#41, *"live two-human proof credentials: this is an operator provis[ioning]…"*). All six
   remaining todo tickets were declined with *"Dispatch declined for 43: :dependency."*. aiur waited
   61.6 h on 9 human-review PRs and 3 rework tickets. Those 3 tickets were `:blocked_on_decision` on
   decisions pending since August.
3. **No work queued (e), 144 h.** One daemon ran for 6 days with nothing labeled for agents
   (private repository; category only).

After these: (c) the Executor was present but working elsewhere, 74 h. Examples: an Executor session
that spent 09-20 steering background agents on an unrelated side project while 9 aiur PRs waited, and a
khala Executor that held 38 tickets paused and spent 9.6 h on permissions while nothing moved. The host
crash on 09-22 then went unnoticed for 51 h (§6).

---

## 1. Definitions (applied the same way everywhere)

**Progress event in the retained model**: a selected GitHub event, wake, lifecycle
record or matching Executor control invocation. The invocation classifier does
not verify command success, so this is not uniformly durable output.
Sources:

| Source | What counts |
|---|---|
| GitHub REST `issues/events` (all repos, full history to 07-17) | every event except `mentioned`, `subscribed`, `unsubscribed`, `head_ref_deleted`, `base_ref_changed`, `comment_deleted`. Label changes count, except `agent:ci-wait` toggles made by `aiur-daemon[bot]`, which are automatic CI bookkeeping. `head_ref_force_pushed` and `review_dismissed` (fired by a push) count as agent pushes. |
| GitHub REST `pulls?state=all` | PR `created_at`, `merged_at` |
| GitHub REST `pulls/{n}/reviews` (PRs since 08-14) | every review `submitted_at` |
| GitHub REST `issues/comments` | every comment except `netlify[bot]` |
| Wake streams | `ticket.branch.push`, `ticket.pr.opened`, `ticket.pr.merged`, `ticket.pr.ready_for_review` |
| Run-log `telemetry.ndjson` | lifecycle `dispatch`, `pr_opened`, `pr_merged`, `rework_start`, `agent_resume` with cause `operator_resume` |
| Executor transcripts (Claude Code + Codex TUI sessions in the repo roots) | a Bash tool call that controls the fleet: `aiurdev/aiur message/resume/set/pause/stop/restart/--todo/answer/executor-*`, `gh pr merge/review/comment/edit/close/ready`, `gh issue edit/comment/create/close/reopen`, `gh api -X POST/PATCH/PUT/DELETE` |

CI results (`ticket.ci.passed/failed`) are not progress; they are used as an infrastructure signal.

**Activity** is not progress. It is used only for attribution:
* *Agent activity*: any record in an agent transcript: Claude workspace projects (`~/.claude/projects/-home-user-*aiur-workspaces-<repo>-<n>`), Codex `aiur-orchestrator` sessions, and run-log `*.agent_events.jsonl`. A minute counts as "agent working" for 10 min after an agent record.
* *Executor activity*: assistant or tool records in the Executor transcripts (per repo, by session home directory, or when a command names the repo), plus the Executor's background subagents. "Present" = within ±5 min of such a record, or within 30 min after a human-typed message (`origin.kind = human`) in any session.
* *Attended* minute: any Executor activity within ±60 min.

**Retained active span**: the analyzer's interval model, not independently
verified continuous daemon uptime. Overlapping spans are merged within each repo
before gap construction; the historical headline instead summed raw run spans.
* *Run-log era (09-15 to 09-26)*: `[daemon_started_at, last telemetry record]` for each `~/.aiur/logs/<run>/` directory. Telemetry is kept only in trailing segments (`segment_boundary`), but sequence numbers are continuous, and the retained segments show no daemon resource-sample gap longer than 2 min. 5 blip directories (< 2 min, CLI processes) are excluded.
* *Pre-log era (08-18 to 09-11)*: the analyzer groups wake IDs by integer division by one million and treats the quotient as a start timestamp. This is an inference, not a verified uptime lower bound: the historical generator preserves ID reservations across restarts, and cold recovery can seed above wall time. The reported lack of host suspension does not independently establish a daemon lifetime. The loader's two-hour observed-up docstring is not implemented.
* `architecture-docs` was renamed `archon` (same GitHub repo, created 2026-09-02). This report merges the two.

**Gap**: a maximal interval inside the retained active-span union with no selected progress event, where length ≥ threshold. It is bounded by run start or end. Time between retained spans is excluded from gaps; calling it daemon downtime requires separate lifecycle evidence (§6). The thresholds reported are 15, 30, 60, 120 and 240 min. Attribution uses gaps of 30 min or more.

**Queue state** is rebuilt by replaying every `agent:*` label event on open issues. Each issue gets one effective state, with this priority: parked > paused > error > human-review > merging > in-progress > rework > todo > ci-wait. `agent:paused` together with `agent:todo` counts as paused. A `todo`/`rework` ticket is *not dispatchable* in these cases:
* the daemon logged `Dispatch declined for N: :dependency` or `:blocked_on_decision` during the same label-state episode. The decline applies to the whole episode, so a ticket first declined on 09-17 and still in the same state since 08-18 counts as blocked since 08-18;
* the ticket has an open needs-human attention (below).

**Attribution** is per minute, with this precedence:
1. daemon heartbeat missing → **d** (never happened in the retained segments)
2. agent activity → **f** (not idle)
3. Executor Claude Code session limit active (`"You've hit your session limit · resets …"`, until the stated reset) → **d**
4. dispatchable todo/rework exists: if an infrastructure window is open (capacity starved/backoff, prewarm blocked, provider usage limit, GitHub budget/broker, tracker auth) → **d** "no capacity". If not: Executor present → **c**, absent → **a** "stranded"
5. items wait on a human (human-review, paused, error, decision-blocked, or an open needs-human attention): Executor present → **c**, absent → **b** (marked *fresh* when the youngest item has waited < 24 h, else *stale*)
6. claimed (in-progress/merging) with no agent running → **a** or **c**
7. only an infrastructure window, a CI-wait, or a daemon refusal because of label provenance → **d**
8. nothing queued (or all todo tickets dependency-held) → **e**

**Needs-human attention**: `ticket.agent.attention.*` wakes of the classes operator-decision, waiting_for_human, paused-agent_pause_request, permissions/credentials/identity, npm-publish-required, stale-review, rework-loop, retry_exhausted, state_divergence, before_run_failure, max_agent_duration, and similar. The window ends at the first of: the next agent activity on that ticket, the next Executor action on it, the end of its label-state episode, or 7 days.

---

## 2. Gap-size distribution

### Per repo and era

Each cell: number of gaps / gap hours / share of active-run time.

| Era · repo | Active h | ≥15 min | ≥30 min | ≥60 min | ≥120 min | ≥240 min |
|---|---:|---:|---:|---:|---:|---:|
| run-log · aiur | 143.9 | 19 / 123.4 h / 86 % | 12 / 121.5 h / 84 % | 10 / 120.0 h / 83 % | 7 / 116.0 h / 81 % | 4 / 106.6 h / 74 % |
| run-log · khala | 185.3 | 36 / 144.3 h / 78 % | 25 / 140.2 h / 76 % | 16 / 133.9 h / 72 % | 12 / 128.9 h / 70 % | 7 / 114.9 h / 62 % |
| run-log · private-repo-a (private) | 161.6 | 16 / 154.5 h / 96 % | 4 / 150.1 h / 93 % | 3 / 149.3 h / 92 % | 2 / 147.9 h / 92 % | 1 / 144.4 h / 89 % |
| pre-log · aiur | 395.2 | 87 / 297.8 h / 75 % | 44 / 282.9 h / 72 % | 26 / 270.8 h / 69 % | 18 / 259.4 h / 66 % | 11 / 239.3 h / 61 % |
| pre-log · archon | 77.2 | 44 / 40.2 h / 52 % | 23 / 33.1 h / 43 % | 10 / 24.9 h / 32 % | 5 / 18.2 h / 24 % | 2 / 11.6 h / 15 % |

### Histogram (all repos)

| Size | Count | Hours |
|---|---:|---:|
| 15–30 min | 94 | 32.5 |
| 30–60 min | 43 | 28.7 |
| 1–2 h | 21 | 28.6 |
| 2–4 h | 19 | 53.7 |
| 4–8 h | 11 | 60.8 |
| 8–24 h | 9 | 108.1 |
| > 24 h | 5 | **447.9** |

Most gaps are short, but most gap time is in a few long ones. The 5 gaps longer than 24 h hold
62 % of gap hours. The 108 gaps of 30 min or more differ by attendance:
* by count, **86 of 108 were attended**: an Executor session was active for at least half of the gap minutes;
* by hours, **439 h were unattended** and 289 h were attended.

So the *frequent* gaps happen while someone is at the controls. The *long* gaps happen when nobody is.

### Per run

Pre-log boots with no gap of 30 min or more are omitted. Private run identifiers
and chronology are withheld; their counts and numerical measurements remain.

| Repo | Run | Era | Start (UTC) | End (UTC) | Hours | Gaps ≥15m (n / h) | Gaps ≥30m (n / h) | Gaps ≥60m (n / h) |
|---|---|---|---|---|---:|---:|---:|---:|
| private-repo-a (private) | withheld | run-log | withheld | withheld | 1.06 | 1 / 0.44 | 0 / 0.0 | 0 / 0.0 |
| private-repo-a (private) | withheld | run-log | withheld | withheld | 16.04 | 14 / 9.63 | 3 / 5.67 | 2 / 4.9 |
| private-repo-a (private) | withheld | run-log | withheld | withheld | 144.43 | 1 / 144.43 | 1 / 144.43 | 1 / 144.43 |
| aiur | 20260916T153434Z-2651128 | run-log | 2026-09-16T15:34Z | 2026-09-16T17:41Z | 2.12 | 1 / 0.74 | 1 / 0.74 | 0 / 0.0 |
| aiur | 20260916T175148Z-3063564 | run-log | 2026-09-16T17:51Z | 2026-09-16T19:05Z | 1.23 | 0 / 0.0 | 0 / 0.0 | 0 / 0.0 |
| aiur | 20260916T190631Z-3754910 | run-log | 2026-09-16T19:06Z | 2026-09-16T21:24Z | 2.3 | 0 / 0.0 | 0 / 0.0 | 0 / 0.0 |
| aiur | 20260916T212437Z-877222 | run-log | 2026-09-16T21:24Z | 2026-09-17T02:28Z | 5.06 | 1 / 3.7 | 1 / 3.7 | 1 / 3.7 |
| aiur | 20260917T022859Z-1671510 | run-log | 2026-09-17T02:29Z | 2026-09-22T15:42Z | 133.22 | 17 / 119.01 | 10 / 117.01 | 9 / 116.34 |
| khala | 20260916T191350Z-3777005 | run-log | 2026-09-16T19:13Z | 2026-09-17T12:48Z | 17.57 | 4 / 17.08 | 3 / 16.63 | 3 / 16.63 |
| khala | 20260917T124842Z-2737066 | run-log | 2026-09-17T12:48Z | 2026-09-17T15:15Z | 2.44 | 1 / 2.44 | 1 / 2.44 | 1 / 2.44 |
| khala | 20260917T152728Z-2974897 | run-log | 2026-09-17T15:27Z | 2026-09-17T15:57Z | 0.49 | 0 / 0.0 | 0 / 0.0 | 0 / 0.0 |
| khala | 20260917T160044Z-3066478 | run-log | 2026-09-17T16:00Z | 2026-09-17T22:26Z | 6.43 | 2 / 6.2 | 2 / 6.2 | 1 / 5.53 |
| khala | 20260917T222625Z-3755197 | run-log | 2026-09-17T22:26Z | 2026-09-18T01:01Z | 2.59 | 1 / 2.59 | 1 / 2.59 | 1 / 2.59 |
| khala | 20260918T011606Z-4144135 | run-log | 2026-09-18T01:16Z | 2026-09-18T02:50Z | 1.57 | 0 / 0.0 | 0 / 0.0 | 0 / 0.0 |
| khala | 20260918T025027Z-923016 | run-log | 2026-09-18T02:50Z | 2026-09-18T04:30Z | 1.67 | 1 / 0.31 | 0 / 0.0 | 0 / 0.0 |
| khala | 20260918T043033Z-2015550 | run-log | 2026-09-18T04:30Z | 2026-09-18T10:48Z | 6.3 | 3 / 4.09 | 1 / 3.42 | 1 / 3.42 |
| khala | 20260918T104829Z-161240 | run-log | 2026-09-18T10:48Z | 2026-09-20T00:56Z | 38.13 | 10 / 31.3 | 7 / 30.11 | 4 / 28.25 |
| khala | 20260920T010817Z-304273 | run-log | 2026-09-20T01:08Z | 2026-09-22T15:42Z | 62.56 | 3 / 61.25 | 2 / 60.95 | 1 / 60.13 |
| khala | 20260924T184803Z-23735 | run-log | 2026-09-24T18:48Z | 2026-09-24T23:07Z | 4.32 | 1 / 0.27 | 0 / 0.0 | 0 / 0.0 |
| khala | 20260924T231144Z-2563251 | run-log | 2026-09-24T23:11Z | 2026-09-25T04:25Z | 5.22 | 1 / 0.77 | 1 / 0.77 | 0 / 0.0 |
| khala | 20260925T042508Z-193656 | run-log | 2026-09-25T04:25Z | 2026-09-26T05:20Z | 24.92 | 8 / 16.48 | 6 / 15.61 | 3 / 13.48 |
| khala | 20260926T052025Z-954217 | run-log | 2026-09-26T05:20Z | 2026-09-26T05:56Z | 0.6 | 0 / 0.0 | 0 / 0.0 | 0 / 0.0 |
| khala | 20260926T055641Z-1318024 | run-log | 2026-09-26T05:56Z | 2026-09-26T15:37Z (live) | 9.67 | 1 / 1.47 | 1 / 1.47 | 1 / 1.47 |
| aiur | wakeboot-2026-08-18T22:32Z | pre-log | 2026-08-18T22:32Z | 2026-08-19T03:06Z | 4.57 | 1 / 3.24 | 1 / 3.24 | 1 / 3.24 |
| aiur | wakeboot-2026-08-19T03:09Z | pre-log | 2026-08-19T03:09Z | 2026-08-19T05:40Z | 2.51 | 1 / 2.51 | 1 / 2.51 | 1 / 2.51 |
| aiur | wakeboot-2026-08-19T05:43Z | pre-log | 2026-08-19T05:43Z | 2026-08-19T13:11Z | 7.46 | 2 / 7.11 | 1 / 6.62 | 1 / 6.62 |
| aiur | wakeboot-2026-08-19T13:21Z | pre-log | 2026-08-19T13:21Z | 2026-08-20T02:51Z | 13.5 | 3 / 12.99 | 3 / 12.99 | 3 / 12.99 |
| aiur | wakeboot-2026-08-20T02:53Z | pre-log | 2026-08-20T02:53Z | 2026-08-20T03:33Z | 0.68 | 1 / 0.68 | 1 / 0.68 | 0 / 0.0 |
| aiur | wakeboot-2026-08-20T04:35Z | pre-log | 2026-08-20T04:35Z | 2026-08-20T05:29Z | 0.91 | 1 / 0.67 | 1 / 0.67 | 0 / 0.0 |
| aiur | wakeboot-2026-08-20T05:57Z | pre-log | 2026-08-20T05:57Z | 2026-08-21T03:06Z | 21.15 | 2 / 21.0 | 1 / 20.68 | 1 / 20.68 |
| aiur | wakeboot-2026-08-21T03:13Z | pre-log | 2026-08-21T03:13Z | 2026-08-21T06:28Z | 3.25 | 4 / 2.29 | 3 / 1.89 | 0 / 0.0 |
| aiur | wakeboot-2026-08-21T08:41Z | pre-log | 2026-08-21T08:41Z | 2026-08-21T16:26Z | 7.75 | 9 / 6.8 | 5 / 5.37 | 3 / 3.65 |
| aiur | wakeboot-2026-08-21T16:30Z | pre-log | 2026-08-21T16:30Z | 2026-08-21T18:18Z | 1.8 | 3 / 1.36 | 1 / 0.65 | 0 / 0.0 |
| aiur | wakeboot-2026-08-21T19:38Z | pre-log | 2026-08-21T19:38Z | 2026-08-21T22:30Z | 2.87 | 3 / 1.53 | 1 / 0.89 | 0 / 0.0 |
| aiur | wakeboot-2026-08-21T22:32Z | pre-log | 2026-08-21T22:32Z | 2026-08-22T05:14Z | 6.7 | 4 / 1.91 | 2 / 1.27 | 0 / 0.0 |
| aiur | wakeboot-2026-08-22T07:16Z | pre-log | 2026-08-22T07:16Z | 2026-08-22T08:19Z | 1.05 | 1 / 0.68 | 1 / 0.68 | 0 / 0.0 |
| aiur | wakeboot-2026-08-24T04:32Z | pre-log | 2026-08-24T04:32Z | 2026-08-24T14:28Z | 9.93 | 1 / 8.16 | 1 / 8.16 | 1 / 8.16 |
| aiur | wakeboot-2026-08-24T16:24Z | pre-log | 2026-08-24T16:24Z | 2026-08-24T20:28Z | 4.05 | 1 / 0.75 | 1 / 0.75 | 0 / 0.0 |
| aiur | wakeboot-2026-08-24T20:29Z | pre-log | 2026-08-24T20:29Z | 2026-09-01T06:26Z | 177.95 | 4 / 173.75 | 3 / 173.28 | 3 / 173.28 |
| aiur | wakeboot-2026-09-02T07:05Z | pre-log | 2026-09-02T07:05Z | 2026-09-03T03:43Z | 20.63 | 8 / 11.11 | 1 / 8.37 | 1 / 8.37 |
| aiur | wakeboot-2026-09-03T04:06Z | pre-log | 2026-09-03T04:06Z | 2026-09-04T00:18Z | 20.19 | 8 / 14.67 | 6 / 14.11 | 4 / 12.87 |
| aiur | wakeboot-2026-09-09T21:53Z | pre-log | 2026-09-09T21:53Z | 2026-09-11T05:54Z | 32.02 | 20 / 23.39 | 10 / 20.07 | 7 / 18.38 |
| archon | wakeboot-2026-09-03T20:46Z | pre-log | 2026-09-03T20:46Z | 2026-09-04T00:48Z | 4.03 | 3 / 2.33 | 3 / 2.33 | 1 / 1.12 |
| archon | wakeboot-2026-09-04T00:28Z | pre-log | 2026-09-04T00:28Z | 2026-09-04T05:39Z | 5.18 | 6 / 2.64 | 1 / 0.54 | 0 / 0.0 |
| archon | wakeboot-2026-09-04T05:40Z | pre-log | 2026-09-04T05:40Z | 2026-09-05T02:16Z | 20.6 | 8 / 12.3 | 6 / 11.7 | 4 / 10.38 |
| archon | wakeboot-2026-09-09T22:34Z | pre-log | 2026-09-09T22:34Z | 2026-09-10T02:47Z | 4.21 | 1 / 0.55 | 1 / 0.55 | 0 / 0.0 |
| archon | wakeboot-2026-09-10T04:22Z | pre-log | 2026-09-10T04:22Z | 2026-09-10T15:53Z | 11.51 | 6 / 6.1 | 5 / 5.83 | 2 / 3.71 |
| archon | wakeboot-2026-09-10T20:58Z | pre-log | 2026-09-10T20:58Z | 2026-09-10T22:29Z | 1.52 | 3 / 1.12 | 1 / 0.52 | 0 / 0.0 |
| archon | wakeboot-2026-09-10T22:31Z | pre-log | 2026-09-10T22:31Z | 2026-09-10T23:57Z | 1.43 | 1 / 0.57 | 1 / 0.57 | 0 / 0.0 |
| archon | wakeboot-2026-09-10T23:58Z | pre-log | 2026-09-10T23:58Z | 2026-09-11T16:56Z | 16.96 | 10 / 12.69 | 5 / 11.05 | 3 / 9.69 |

The retained interval from 08-21T22:32Z to 08-24T02:51Z has three >=30-minute
gaps totaling 1.9503 h. It begins at PR #2242, which disabled prewarm and also
changed identity/sandbox configuration. The #2237 code repair, PR #2274, merged
on 08-23T20:06:53Z; all three gaps precede that merge. This is not a clean
post-repair experiment, and event-ID groups do not prove a count of daemon boots.
See [prewarm history](../synthesis/prewarm-starvation-history.json).
It records a period with fewer selected-event gaps; the causal explanation remains unresolved.

---

## 3. Top 20 longest gaps (≥ 30 min)

The historical model attribution and supporting observations are shown below; quoted log lines alone do not prove a whole interval’s cause. "labels" means the effective queue state
at the start of the gap. "att" is the historical minute-bin attendance estimate;
use the CSV duration-weighted column for a bounded fraction.

| # | Repo | Start → end (UTC) | h | Attr. | Cause and evidence |
|---|---|---|---:|---|---|
| 1 | aiur | 08-25 23:04 → 09-01 06:26 | 151.3621 | model d; historical attendance 0.004 | The classifier extends an unresolved starvation record across an event-ID group and gives it precedence over waiting work. Continuous daemon uptime and operator absence are unproved. Label replay: 12 human-review issues, 5 rework, 1 paused, 3 ci-wait, 1 todo (#2394, already linked to open PR #2396). Positive dispatch eligibility and historical decision holds are not independently established. See the largest-gap attribution audit; neither d nor a replacement b allocation is a measured cause. |
| 2 | private-repo-a (private) | withheld | 144.4 | e | private — omitted (daemon up, nothing queued; ended by the host crash) |
| 3 | aiur | 09-20 02:04 → 09-22 15:42 | 61.6 | b (50.9 h) + c (10.5 h) | Labels: human-review 9 (#2751 and #2749 fresh, #2668 at 71 h, others up to 17 days), paused 10, error 4. The rework tickets #1767, #2245 and #2413 were `Dispatch declined for 1767: :blocked_on_decision.` on decisions pending since 08-21/22 (`ticket.agent.attention.operator-decision` 08-22T02:17Z). Alert 09-21T02:01Z: *"PR #2752 … has been open 24 hours with no review — it is unseen, not blocked."* On 09-20 from 07:26Z to 22:27Z, the aiur Executor session was steering background agents on an unrelated side project (a browser game), so the result is c. The selected Executor transcript coverage ends at 22:27Z; this does not establish operator absence. The host interruption is discussed in §6; the exact crash time is unproved. |
| 4 | khala | 09-20 03:34 → 09-22 15:42 | 60.1 | model b/c; causal duration unverified | Six dependency declines are recorded at 01:08Z, when ticket 42 also starts. After 42 closes, the recorded graph and replayed closure state reduce to paused #41 as the open root outside tickets 43, 44, 45, 47, 48 and 49. The handoff requires provisioned live-proof inputs plus code/test changes and rebasing. Twenty-three credential attentions occur about 15 minutes apart. A later sample reports effective capacity 12 and occupied 0 but omits load fields. This supports a finite dependency bottleneck, not continuous whole-fleet causality or attribution of later host downtime. |
| 5 | aiur | 09-18 11:40 → 09-19 17:59 | 30.3 | b | Labels: human-review 5 (#2668 at 33 h, #2633/#2610/#2394 at about 175 h, #2519 at 363 h), paused 12, error 4, 3 decision-blocked. Executor 8 active minutes in 30 h. Alert: *"PR #2736 (Provision deletion guards in workspaces) has been open 24 hours with no review — it is unseen, not blocked."* It ended with an Executor control command at 09-19T17:59Z. |
| 6 | aiur | 08-20 05:57 → 08-21 02:38 | 20.7 | d | Model assigned d; a later point diagnosis supports a prewarm defect but not the whole interval. In event-ID group `1787205471` (not a verified boot): `system.fleet.capacity.starved` at 06:18Z was never resolved, and `system.dispatch.prewarm_blocked` has 71 blocked and 70 resolution records; 70 ordered pairs plus one unclosed block, with variable durations. This signal alone does not prove the absorbing-state defect caused the whole gap. No Executor session existed until 08-21T02:40Z (*"read recent handoff /aiur-handoff"*). A later successful tool result on 08-21T18:42Z reports: *"Ready tickets=31, live agents=0, effective cap=1, dispatch constraints=prewarm build (prewarm=checking)"*. |
| 7 | khala | 09-18 22:46 → 09-19 17:55 | 19.1 | b | 3 PRs entered human-review at the start of the gap (#36, #115, #101). 14 todo tickets were dependency- or decision-held behind them. Executor active 0 minutes in the gap (overnight). The first action was an Executor control command at 09-19T17:55Z. |
| 8 | aiur | 08-25 00:40 → 08-25 14:03 | 13.4 | d (unattended) | Same boot and starvation signal as #1. Labels: human-review 11, rework 6. It ended when the human wrote *"status?"* at 14:03Z. |
| 9 | aiur | 09-17 03:36 → 09-17 13:57 | 10.4 | c (att 1.00) | #2678: at 03:36:25Z the agent itself moved the ticket from human-review to rework (`labeled agent:rework` by its-applekid). It was never redispatched. The next event on it was a close by the Executor at 09-18T01:13Z. Stranded rework, and an Executor was active on khala the whole time. |
| 10 | khala | 09-25 12:08 → 09-25 21:59 | 9.8374 | model mostly b; overlapping constraints | Label replay finds eight human-review issues and 60 todo issues. All 60 have an open or unresolved dependency in the extracted graph. The external blocker frontier includes seven review issues, paused #41, in-progress #201, parked #236 and unresolved reference 2786; the other review issue is #207. The model’s 59 dependency/one unauthorized split backprojects decline reasons across label-state episodes, with no retained candidate-decline records inside this interval. Exact-boundary wake counts are 40 operator-decision, 39 usage-limit and one paused-agent request. See the dependency evidence artifact for scope limits. |
| 11 | khala | 09-17 03:09 → 09-17 12:48 | 9.6 | c (Executor active 212 min) | 38 tickets had been held `agent:paused` by the Executor since the run started (44 labeled 09-16T19:13–19:14Z). At 03:09Z it paused one more (#12). Agents lacked GitHub write access: `github-permissions`, `workflow-permissions` and `github-write-access` wakes, 39 of each. Four todo tickets remained. The Executor was busy on permissions. The next progress was PR #54 (*"feat: establish Khala plans, workspace and feasibility proofs"*), opened by the Executor at 15:31Z. |
| 12 | aiur | 08-25 14:03 → 08-25 22:36 | 8.5 | d | Same boot as #1. The human was present about 22:10Z but on the release (*"cut 0.0.5 release now and label as latest"*, *"npm is still 0.0.3"*). The 11 human-review PRs were not touched. |
| 13 | aiur | 09-02 09:40 → 09-02 18:03 | 8.4 | d (att 0.96) | `system.fleet.capacity.starved` 08:51Z → `.resolved` 17:27Z. Labels: human-review 14. The human was present, but the topics were rtk analytics, CODEOWNERS and an `aiur-claude` release, not the queue. |
| 14 | aiur | 08-24 05:38 → 08-24 13:47 | 8.2 | d | `system.fleet.capacity.starved` at 04:52Z, not resolved before the boot ended at 14:28Z. human-review 14. It ended at 13:47Z: *"restarted your instance. dashboard showss 2440, stream deck shows 2216, 2440, 2339, 2394 as unfinished"*. |
| 15 | archon | 09-11 06:39 → 09-11 13:51 | 7.2 | b | #227 entered human-review at 06:39Z, 2 tickets paused. The Executor session was in `away_summary` state twice. The human came back at 13:38Z on an unrelated site issue (*"did something happen to the logo?"*). |
| 16 | aiur | 08-19 16:49 → 08-19 23:51 | 7.0 | d (att 0.00) | #2237 pattern: `prewarm_blocked` fired 21 times, each followed by `.resolved`; starvation never resolved. Executor absent. |
| 17 | aiur | 08-19 06:33 → 08-19 13:11 | 6.6 | d (att 0.00) | Same #2237 pattern (20 prewarm flaps), Executor absent. |
| 18 | khala | 09-16 21:29 → 09-17 03:09 | 5.7 | a (3.9 h) + c | GitHub-permission blockers: `github-permissions` ×23, `workflow-permissions` ×22 and `github-write-access` ×22 on #10, #11 and #50. Todo #51 was blocked in the same way (`gh issue edit failed: its-applekid lacks AddLabelsToLabelable/…`), but the model counts it as stranded. It ended at 03:09Z, when the Executor paused #12 (gap 11). |
| 19 | khala | 09-17 16:54 → 09-17 22:26 | 5.5 | b + c | #17: *"Agent entered error after retry exhaustion; automatic retry is no longer scheduled"* and *"Released claim for ticket=17 … after 3 tracker failures … operator recovery is require[d]"*. 38 tickets still paused. |
| 20 | aiur | 09-10 10:31 → 09-10 15:55 | 5.4 | c | The Executor paused #2608 at 10:31Z. The session showed `away_summary` 15 times, and the aiur Executor was running the archon hosted-upload work that day. 5 todo and 5 rework tickets sat undispatched. |

Gaps 1, 8 and 12 are pieces of one idle stretch, split by two small progress events.

---

## 4. PRs waiting for Executor review

Method: *PR-ready* = the moment an agent or the daemon adds `agent:human-review` to a ticket.
*First Executor action* = the first `its-everdred` event after that moment on the ticket or its
linked PRs (linked by `Closes #n` or a `<n>-` branch name): a review, comment, label change, merge or
close. A merge of the linked PR also ends the wait. If the label went away with no Executor action
(the daemon or agent moved the ticket back to ci-wait or rework), the wait is "withdrawn".

| Set | n | Median | p75 | p90 | Max | > 1 h | > 4 h | > 12 h | Total wait |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **All, ended by an Executor action** | **500** | **0.33 h** | 2.6 h | **9.6 h** | 212.6 h | 191 (38 %) | 103 (21 %) | 40 (8 %) | 2,991 h |
| aiur, pre-log (August) | 202 | 2.8 h | 8.4 h | 15.8 h | 212.6 h | 158 | 88 | 29 | 2,732 h |
| aiur, run-log | 10 | 0.98 h | 3.7 h | 4.2 h | 4.2 h | 5 | 2 | 0 | 17.7 h |
| khala, run-log | 191 | **0.08 h** | 0.23 h | 1.1 h | 19.2 h | 20 | 13 | 11 | 210 h |
| archon, pre-log | 88 | 0.11 h | 0.33 h | 0.70 h | 2.9 h | 7 | 0 | 0 | 27 h |
| private-repo-a (private) | 9 | 0.12 h | 0.46 h | 2.1 h | 2.1 h | 1 | 0 | 0 | 3.6 h |
| Executor present when the PR became ready | 445 | 0.23 h | 1.9 h | 9.6 h | | 147 | 81 | 35 | |
| Executor absent when the PR became ready | 55 | **3.5 h** | 5.5 h | 9.3 h | | 44 | 22 | 5 | |
| Withdrawn (label churn, no Executor action) | 369 | 0.01 h | 0.03 h | 0.37 h | 257 h | 24 | 13 | 8 | |
| **Still waiting now** | **12** | | | | | | | | |

The 12 items still in human-review as of 2026-09-26T15:16Z are:
* aiur (9): #2519 (559 h), #2394, #2610, #2633 (369–373 h), #2668 (228 h), #2502, #2639, #2749, #2751 (157–161 h). The aiur daemon has not run since the 09-22 crash.
* khala (3): #203 (34 h), #231 (9 h), #49 (4 h).

Findings:
* A dedicated, present khala Executor reviews in minutes (median 5 min). In August, aiur's
  median was 2.8 h, and 29 waits were over 12 h.
* The long tail is overnight or away time. Nine aiur PRs that became ready on 08-24/25 each waited
  193–213 h: this is gap 1.
* 369 of 881 human-review entries (42 %) were withdrawn within minutes, mostly by
  `aiur-daemon[bot]` (251). This churn makes the review queue look busier than it is.
* In the run-log era, the telemetry `review_pause · human_review_ready` record repeats every 2 min
  per waiting ticket. The retained segments alone hold 1,982 of them, or about 66 ticket-hours of
  review wait.

---

## 5. Agents that paused, timed out or waited for a human

1,127 needs-human attention episodes: aiur 598, khala 425, archon 94, private 10. Median time to
resolution 0.95 h. **344 (31 %) waited more than 4 h**. The episodes sum to 11,096 ticket-hours,
because many run at the same time.

| Class | n | Median | p90 | Note |
|---|---:|---:|---:|---|
| operator-decision | 143 | 0.16 h | 6.5 h | |
| waiting_for_human | 105 | 0.55 h | 6.3 h | |
| paused-agent_pause_request | 98 | 0.60 h | 9.8 h | |
| github-permissions / workflow-permissions / github-write-access | 71 / 69 / 69 | 9.3–9.4 h | 16.4 h | khala 09-16/17: the agent identity lacked write access |
| paused-before_run_failure | 65 | 0.40 h | 1.3 h | |
| retry_exhausted / error-retry_exhausted | 64 / 45 | 0.04 / 0.82 h | 2.0 / 7.1 h | |
| state_divergence | 34 | 0.67 h | 5.2 h | |
| **paused-max_agent_duration (agent timeout)** | **25** | **0.99 h** | **5.3 h** | |
| auth-identity / push-identity | 25 / 25 | 6.5 / 3.5 h | 9.0 / 6.0 h | |
| npm-publish-required | 25 | 1.4 h | 2.7 h | |
| credentials | 26 | 168 h (cap) | 168 h | reached the 7-day window cap |
| live-proof-credentials | 23 | 117 h | 119 h | khala #41: gap 4 |

Other sources for the same question:
* Telemetry pause causes (retained segments only): `agent_pause` with cause ci_wait 30, agent_pause_request 10, operator_pause 9, before_run_failure 6, label_override 7, global_pause 2; `implement` with outcome paused 13.
* Decisions answered late: the aiur rework tickets #1767, #2245 and #2413 stayed `:blocked_on_decision` from 08-18/22/24 through the 09-22 crash, more than 4 weeks.

---

## 6. Daemon-down periods (not counted as gaps)

| Repo | Down from → to (UTC) | h | Cause |
|---|---|---:|---|
| khala; concurrent public Aiur telemetry interruption | 09-22 15:42 → khala 09-24 18:48 | **51.0999** | Last Khala telemetry to explicit next daemon start. Prior boot journal ends 15:41:37Z, while Aiur/Khala telemetry continues about 30 seconds later; an exact crash time is unproved. Missing clean shutdown is consistent with unclean termination. Next host journal begins 09-24T17:30:51Z; Khala daemon start is 18:48:04.293177Z, 77.2216 min later. The retained post-boot census identifies six Khala runs and three brief unidentified streams, with no identifiable Aiur restart before cutoff. |
| aiur | 09-04 00:18 → 09-09 21:53 | 141.6 | Not run; the Executor was on architecture-docs/archon |
| aiur | 09-11 05:54 → 09-16 15:34 | 129.7 | Not run |
| aiur | 09-01 06:26 → 09-02 01:55 | 19.5 | Not run (end of gap 1) |
| archon | 09-05 02:16 → 09-09 22:34 | 116.3 | Not run |
| archon | 09-03, 3 short periods | 1.6 / 5.6 / 2.2 | Restart churn on the first day |
| private-repo-a (private) | withheld | 20.9 | — |

**The reported "khala down 4.6 days"** is 09-20T03:34Z (last progress, PR #109 merged) to 09-24T18:59Z
(next progress, PR #131 *"Add a public splash page at khala.aiur.team"* by the Executor), which is 111.4 h.
The retained observations divide that elapsed time into:

* About 60.1 h before the telemetry interruption. The finite dependency graph
  points to paused #41, but one effective-capacity sample does not establish
  continuous health or the cause of every minute (gap 4).
* 51.0999 h from the last Khala telemetry to its next explicit daemon start.
  The old journal endpoint to the next boot's first entry is 49.8206 h; this
  bounds an observation gap, not a measured exact host-off duration.
* Roughly 11 min from the recorded restart to the selected next progress event.

The selected Executor transcript coverage has a long gap, but does not prove
that nobody noticed or that no other notification reached an operator.
The frozen launcher already records unexpected BEAM exits and reaps agents;
it does not restart the daemon or survive a host failure. Current named-unit
inspection is not a historical configuration audit. See
[supporting evidence](../synthesis/host-downtime-evidence.json) for the restart
record, directory census and unresolved notification/supervision questions.

---

## 7. Patterns

**Time of day (Pacific).** The operator is in America/Los_Angeles. Consider gaps shorter than 24 h,
so that the multi-day stretches do not hide the daily cycle:
* Pre-log era: the idle share peaks at **03:00–06:00 PDT (50–53 %)**, against 23–35 % from 11:00 to 22:00 PDT.
* Run-log era: the curve is flatter (15–34 %). The highest values are at 16:00, 13:00, 00:00 and 10:00 PDT (30–34 %), which fits Executor attention moving between repos rather than sleep.
* Gap starts are spread over all 24 hours. The busiest start hours are 09:00, 15:00 and 20:00 PDT (8–9 starts each).

**Executor session boundaries (verified sensitivity check).** The corrected
association test requires the boundary to precede the gap by at most 30 minutes.
The inherited test also accepted a boundary up to one minute after the gap
started, which increased the silence count from 19 to 22. Baselines below are
approximate, reconstructed from retained active intervals rounded to minutes.

| Boundary | Events | Gaps starting ≤30 min after | Approx. pooled base | Approx. pooled lift |
|---|---:|---:|---:|---:|
| Global Executor activity silence ≥30 min | 139 | 19/108 (17.6%) | 8.72% | 2.02× |
| Recorded session-limit window begins | 11 | 6/108 (5.6%) | 0.82% | 6.76× |
| Executor session ends | 144 | 8/108 (7.4%) | 3.70% | 2.00× |
| Compaction boundary | 17 | 1/108 (0.9%) | 1.30% | 0.71× |
| Handoff document timestamp | 87 | 4/108 (3.7%) | 4.02% | 0.92× |
| Session start | 144 | 3/108 (2.8%) | 2.73% | 1.02× |

The old count of 34 compactions combined 17 boundary records with their 17
summary records. Only three of the six limit-associated gap starts follow a
limit window recorded for the same repository. Shared-account limits might
cross repository boundaries, but the study does not establish that mapping.
These are pooled associations, not causal effects or evidence that continuity
failures are absent. Silence and progress also share activity inputs. See the
[boundary verdict](../synthesis/verdicts/claims-gaps-boundaries.json).

**Rate and usage limits.**
* *Executor session limits*: the retained model reports 25.5 h across 11 windows,
  with 13.6197 h overlapping gaps; the boundary check reproduces these durations.
  Architecture-docs has 63 assistant limit responses on September 3 from
  19:05:58Z to 22:07:45Z, and a user reset message at 23:52:34Z. Repeated errors
  until that reset are not established. Its observed cursor is 352, with
  **1,529 retained records above the shared cursor**, including 906
  `system.fleet.capacity.starved` records. Above-cursor does not mean unseen:
  a successful wake-file result returned wake 419 at September 4 00:04:08Z.
  Archon's cursor is 546 (264 records above it); aiur's is 4683 (66, including
  26 `ticket.pr.merged`). The frozen code already has owner acknowledgements,
  observer reads, bounded retention with overflow reporting and stalled-consumer
  status. See the [wake-consumption verdict](../synthesis/verdicts/claims-gaps-wake-consumption.json).
* *Provider (agent) usage limits*: `codex-usage-limit` / `usage_limit_exhausted` windows total 17.1 h (khala 11.1 h, aiur 6.0 h), and 11.0 h overlap gaps. This cause is small by itself. It matters when it also raises a blocking operator decision (gap 10).
* *GitHub budget or broker*: 1.5 h. *GitHub connectivity lost*: under 0.2 h. Neither is a material cause.
* *CI*: no gap minute was classified as "CI only". Every open CI-wait coincided with a stronger cause.

**Attended and unattended.**

| Era | Attended h (a/b/c/d/e/f) | Unattended h (a/b/c/d/e/f) |
|---|---|---|
| pre-log | 92.1 (3.1 / 6.9 / 15.5 / 50.3 / 0 / 16.3) | 223.9 (0.3 / 0.8 / 0 / 222.8 / 0 / 0) |
| run-log | 196.4 (7.7 / 34.0 / 58.5 / 4.5 / 75.7 / 15.9) | 215.4 (4.4 / 139.3 / 0 / 2.0 / 68.7 / 1.0) |

Current-era unattended time is almost all (b): the fleet waits on a human who is not there. Current-era
attended idle time is mostly (c) and (e): the human is there, working on another repo or project.

---

## 8. What this means for the refactor (evidence-based, short)

1. **Make blocking causes and their owners explicit.** The retained model assigns
   78% of aiur/khala gap bins to waiting on an Executor, but that is not a
   measured causal share. The stranded bucket contains both permission waits
   and a demonstrated dispatch defect (see the gaps-10 verdict).
   The verified dependency samples show concentrated blockers, but not a measured
   whole-fleet causal duration. September 25 blockers span review, paused,
   in-progress, parked and unresolved external work. Summaries should name these
   distinct causes and owners without weakening dependency admission. Existing
   circular-wait alerts cover a narrower case; assess remaining summary gaps
   before adding another alert. The interval contains 40 operator-decision and
   39 usage-limit wakes, which supports investigating repetition and resolution.
2. **Define recovery ownership across host failure.** The retained Khala interruption
   spans 51.0999 h. Existing BEAM-death reporting and cleanup do not restart a
   daemon after host failure. Establish intended reboot recovery and independent
   notification behavior, while preserving deliberate stops; historical absence
   of every supervisor or delivered notification has not been proved.
3. **Measure recovery from Executor inactivity and limits.** The strict pooled
   associations are about 2.0× for silence and 6.8× for recorded limit windows,
   with shared-input and cross-repository confounding. They do not establish
   causal shares or rule out continuity failures. The 1,529 architecture-docs
   records above its cursor are unacknowledged, not necessarily unseen; track
   observation, acknowledgement and action completion separately.
4. **Signal hygiene.** 906 unacknowledged `capacity.starved` wakes, 42 % human-review label churn, and a
   starvation alert with known false alarms (#2447) all make real stalls harder to see.
5. **Separate prewarm repair from recurrence evidence.** PR #2274 adds probe recovery
   and a watchdog for holds whose worker is no longer alive. Earlier mitigation
   disabled prewarm; later changes repair alert false alarms. A 1.6% model bucket
   does not prove the defect never recurred or justify treating dispatch as solved.
   Both compound claims are rejected in [the prewarm verdict](../synthesis/verdicts/claims-gaps-prewarm.json);
   the point diagnosis and merged repair remain supported.

---

## 9. Caveats

* The pre-log era depends on the wake stream and GitHub. Its daemon uptime is a verified lower bound (same boot id). Its infrastructure attribution depends on daemon-reported starvation, which had known false alarms before 08-24 (#2447).
* Telemetry is kept only in trailing segments. The heartbeat check covers only those segments; they show no gaps.
* Executor presence is taken from Claude Code and Codex TUI transcripts in the five repo roots. Work done in other directories, or away from the keyboard, is not visible.
* Linking a PR to a ticket uses `Closes #n` and the `<n>-` branch prefix. PRs from Executor background agents often have neither, so they count only as repo-level progress.
* Needs-human windows close at the next agent or Executor activity on the ticket, or after 7 days. Parallel windows overlap, so ticket-hours are larger than wall-clock hours.
* Only gaps of 30 min or more are attributed. Shorter idle time (94 gaps, 32.5 h) is in the CSV with the same per-minute split.

## 10. Reproduction

The scripts are in `~/.aiur/research/refactor-2026-09-26/scratch/gaps/`:
* `extract_activity.py`: agent and Executor minute buckets
* `fetch_gh.sh`, `fetch_pulls.sh`: GitHub REST, paginated
* `analyze.py`: runs, progress, queue replay, infrastructure and attention windows, per-minute classifier
* `report_data.py`: aggregates, PR waits, attention, boundaries, down periods
* `evidence_dump.py`: the evidence lines for the top gaps

Intermediate TSV and JSON files are in the same directory. The only data sources are the read-only logs,
the transcripts, the host journal (`journalctl --list-boots`, `last -x`) and GitHub REST.
