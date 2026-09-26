# Timeline of runs and major incidents (from the Executor's records)

Companion to [`recurring-issues.md`](recurring-issues.md). All times are UTC. Sources are under
`~/.aiur/repo/aiur-team/` unless marked. Rank numbers (R1–R21) refer to the taxonomy in
`recurring-issues.md`.

**Timestamp caution.** The records' own times are not always reliable. The aiur meta file
names on 08-09/10 run up to ~7 h ahead of the real write times, and the khala 09-18 handoff
used estimated section times (up to 2 h 14 m off) and an invented, evenly spaced session log.
Where the reading agents cross-checked against file mtimes, wake `first_seen_at` or git merge
times, those values are used here.

One private repo run is left out of this timeline by rule. It adds one abandoned wake cursor
(55 of 117 wakes never consumed), one empty handoff and one overlap of two daemons.

## Record coverage at a glance

| Period | aiur meta | retros | handoffs | findings | Note |
|---|---|---|---|---|---|
| 07-13 | — | — | — | — | hourly-retrospective rule added to the `aiur-run` skill |
| 08-02 → 08-05 | — | 1 | kevinweaver-dev (08-03) | 47 | dual-builds run; findings ledger busiest day |
| 08-08 → 08-11 | 34 | — | 08-11 | — | Stream Deck Parity run |
| 08-12 → 08-20 | **none** | — | 08-17, 08-18 ×2 | 1 | 9 days with no hourly logs |
| 08-21 → 08-23 | 57 | 3 | 08-21, 08-23 | 4 | label-repair / ghtoken runs |
| 08-24 → 09-09 | **none** | 2 (aiur 09-01, arch-docs 09-03) | 09-02 ×2, 09-03; arch-docs 09-03 ×2 | — | 17 days with no aiur hourly logs; aiur fleet paused 08-25 → 09-02 |
| 09-09 → 09-11 | 2 | 2 | archon ×6 | 8 | archon runs |
| 09-16 → 09-17 | — | 3 | aiur ×10; khala | 6 | aiur resume run; khala first run |
| 09-18 → 09-26 | — | **none until 09-26 15:00** | khala 58-version series, 09-20, handoff.md | 7 (09-26) | 9 days with no hourly retros |

## Timeline

### Before the corpus

| When | Event | Source |
|---|---|---|
| 2026-06-23 | `aiur-run` skill is 5.3 KB | git history of the skill |
| 2026-07-13 | "Hourly executor monitoring retrospective" section added (b24e0d724) | git history |
| before 08-03 | An aiur run loses 229 min "waiting on permission never required" (R2) | `its-everdred/kevinweaver-dev/executor/handoff.md` |

### 2026-08-02 → 08-05 — dual-builds run (aiur) and kevinweaver-dev

| When | Event | Class | Source |
|---|---|---|---|
| 08-02 | 35 findings in one day. 8 GitHub rate-limit outages. Dispatch latch exhaustion and prewarm base failures. The Executor ran a 30 s cadence: 35 of 37 wakes led to action; hourly retros on time. | R16, R1 | `aiur/meta/findings.ndjson`; `aiur/executor/monitoring/aiur-team-aiur-dual-builds-20260801/` |
| 08-03 | kevinweaver-dev run. Before-run latch needs restarts; `pkill` banned; the previous Executor's context lived only in a chat transcript. | R1, R12, R15 | `its-everdred/kevinweaver-dev/executor/handoff.md`, findings |
| 08-05 | Retro: rework feedback does not wake paused agents (#1389). First sighting of the rework strand. | R5 | `aiur/meta/retros/20260805T000326Z-309948.md` |

### 2026-08-08 → 08-11 — Stream Deck Parity run (#1567, aiur)

| When | Event | Class | Source |
|---|---|---|---|
| 08-08 22:00 | 19 open PRs; "A stale PR is worse than an unreviewed one." | R3 | `aiur/meta/2026-08-08T2200Z-bottleneck.md` |
| 08-08 23:00 → 08-09 14:18 | 13 agents stalled ~15 h on a blocker that was never closed (#1650/#1651), while surfaces looked healthy. | R14, R9 | `aiur/meta/2026-08-09T1300Z-hourly.md` |
| 08-09 | A research spike while the PR queue grew 22 → 30. The Executor wrote "arm a one-hour timer" into the skill and never armed one. Real meta gap 23:06 → 05:55 (6 h 49 m). | R3, R10 | `aiur/meta/2026-08-09T0000Z-hourly.md` |
| 08-09 | 17 paused agents held 17 of 22 slots. | R13 | `aiur/meta/2026-08-09T0700Z/0800Z-hourly.md` |
| 08-09 | 10 decisions answered as ticket comments; 2 of 14 agents active "for hours". | R2 | `aiur/meta/2026-08-09T2100Z-hourly.md` |
| 08-09 night | Fleet fell from 15 agents to 1 (label cache, #1682). | R1 | `aiur/meta/2026-08-09T2345Z-hourly.md` |
| 08-10 | Approved PR #1698 not queued for 8 h while the Executor believed it merged. Fleet 93 % idle, 70.1 idle slot-hours; wrong bottleneck named for an hour. Claude session limit sends 12 tickets to `agent:error`. | R9, R11, R6 | `aiur/meta/2026-08-10T0620Z…1145Z-hourly.md` |
| 08-10 ~11:20 → ~18:00 | Fix #1758 merged but inert under the "report rather than restart" rule; the operator then grants standing restart authority. | R7 | `aiur/meta/2026-08-10T1345Z…1830Z-hourly.md` |
| 08-11 06:32 → 12:30 | CLI status timeouts (orchestrator mailbox, #1731 → #1816, then #1837). GitHub core budget 0/5000. | R9, R16 | `aiur/meta/20260811T*` |
| 08-11 19:34 | Handoff: goal cleared, `aiur stop` issued. | — | `aiur/executor/handoffs/20260811T193429Z-handoff.md` |

### 2026-08-12 → 08-20 — thin records

| When | Event | Class | Source |
|---|---|---|---|
| 08-12 | Finding: the executor-listen arming step "is buried mid-skill and the skill is too large to scan". No ticket; still `open`. | R10 | `aiur/meta/findings.ndjson` |
| 08-16 | `aiur-run` skill reaches ~40 KB. | R10 | git history |
| 08-17 15:47 | Handoff: 5 unreviewed PRs (#2085–#2090); `.aiur/config` damaged by `reset --hard`; `agent:error` pool 13. | R3, R15 | `aiur/executor/handoffs/20260817T154710Z-handoff.md` |
| 08-18 00:19 | Handoff: "**I did not service the hourly meta-check** … the operator's dashboard was down for an unknown period and I did not notice." PRs "Unreviewed all run." | R10, R3 | `aiur/executor/handoffs/20260818T001943Z-handoff.md` |
| 08-18 05:23 | Handoff: the earlier ci-readiness diagnosis "was wrong"; a 64 KiB response cap stopped dispatch for ~5 h. 9 drafts hit `max_agent_duration` with finished code. | R11, R1, R20 | `aiur/executor/handoffs/20260818T052353Z-handoff.md` |
| 08-18 22:03 | First record in the aiur wake inbox. The cursor stays at `wake_id 1` for five days. | R4 | `aiur/executor/aiur.executor.wakes.ndjson`; `aiur/meta/20260823T183000Z-*.md` |
| 08-20 | Inbox holds 2,832 unconsumed records; the Executor polls hourly instead. 17 PRs reworked but unreviewed, 16 with no failing check, the oldest nearly a day. | R4, R3, R10 | `aiur-run` SKILL.md (incident text) |

### 2026-08-21 → 08-23 — label-repair and ghtoken runs (aiur)

| When | Event | Class | Source |
|---|---|---|---|
| 08-21 02:38 | Handoff written by a different model loses the standing goal and merge authority; config wrongly called "committed". | R12 | `aiur/executor/handoffs/20260821T023842Z-handoff.md` |
| 08-21 04:45 | GraphQL budget crisis. | R16 | `aiur/meta/20260821T044500Z-graphql-budget-crisis.md` |
| 08-21 04:13 → 09:01 | Operator-directed pause; the Executor later calls holding it 4.8 h "over-literal". | R11 | `aiur/meta/20260821T091500Z-*.md` |
| 08-21 10:15 | 11 agents idle ~1 h on a budget hold that had cleared ("A 3.5-minute outage cost roughly 11 agent-hours"). | R1, R16 | `aiur/meta/20260821T101500Z-*.md` |
| 08-21 11:15 → 23:20 | "No agent can push": token absent at agents, identity mismatch, sandbox root, uncommitted config. 5–9 wrong hypotheses from outside the agent process. The fleet "works for the first time today" at 23:20. About 19 h of near-zero output. | R17, R11 | `aiur/meta/20260821T111500Z…234000Z` |
| 08-21 22:00 | Agents "asked ten times over hours"; the Executor was forbidden to answer. | R2 | `aiur/meta/20260821T220000Z-*.md` |
| 08-21 23:40 | "The agents are no longer the constraint — I am." | R3 | `aiur/meta/20260821T234000Z-*.md` |
| 08-22 02:20 → 22:30 | Review queue grows to 40 non-draft PRs with 0 approved. 15:30: review starves the fleet (todo empty, 18 in human-review, 1 working). "webhook ingress never enabled" found false after ~22 logs. #2264 makes standing items carry evidence. | R3, R11 | `aiur/meta/20260822T*` |
| 08-22 20:45 | Slot leak doubles (4 → 8 of 12 dead slots) and forces a restart. | R13 | `aiur/meta/20260822T204500Z-*.md` |
| 08-22 22:30 | "I am the uncontrolled load": 8 background reviewers push load to 45 against 24. 11 reworked PRs unseen up to ~5 h. "I was treating review as a queue to drain once. It is a loop." | R19, R3 | `aiur/meta/20260822T223000Z-*.md` |
| 08-23 01:00 → 10:25 | Build-gate slots leak; the backstop wedges; the fix "became the bottleneck". Red main freezes the merge train. `.aiur/config` destroyed by a review agent. | R13, R8, R15 | `aiur/meta/20260823T010000Z…102500Z` |
| 08-23 02:35 | "A day of merged work had never run" — the "fourth time tonight". | R7 | `aiur/meta/20260823T023500Z-*.md` |
| 08-23 03:30 | Seven tickets deadlocked by a label never cleared. | R1 | `aiur/meta/20260823T033000Z-*.md` |
| 08-23 08:30 → 11:25 | Merges flat at 51 while 9–14 green PRs wait. "Correction: red `main` is not what froze the merges. I was." | R3 | `aiur/meta/20260823T083000Z`, `112500Z` |
| 08-23 12:20 | A 45-minute budget hold becomes a permanent stop for 10 tickets. | R1 | `aiur/meta/20260823T122000Z-*.md` |
| 08-23 13:20 | "I hit the authorship trap I warn about." | R17 | `aiur/meta/20260823T132000Z-*.md` |
| 08-23 18:30 | Wake inbox drained: cursor 1 → 2832 after five days; 66 PRs merged that day. | R4 | `aiur/meta/20260823T183000Z-*.md` |
| 08-23 | Skill change #2412: the hourly check must not be the primary loop. The cursor then freezes at 2832. | R10, R4 | git history; handoffs |
| 08-23 21:56 | Handoff: 8 PRs unreviewed ("I did not review these"). Wake monitor must be re-armed each session. | R3, R4 | `aiur/executor/handoffs/20260823T215617Z-handoff.md` |

### 2026-08-24 → 09-03 — dormancy, then architecture-docs

| When | Event | Class | Source |
|---|---|---|---|
| 08-25 → 09-02 | aiur global pause on; fleet 0/16; "nothing had moved on this repo since Aug 25". Nobody noticed for ~8 days. | R6 | `aiur/executor/handoffs/20260902T035500Z-handoff.md` |
| 09-01 | Retro: "I handled roughly 15 monitor events and called observe only twice." | R10 | `aiur/meta/retros/pr-completion-20260901.md` |
| 09-02 03:55 / 04:30 | Handoffs: wake cursor frozen at 2832, 1,137+ pending (#2472, PR #2481). Red main was a mise release, not flakes ("twice wrong"). Previous standing items "largely stale after a week of dormancy". | R4, R8, R12 | `aiur/executor/handoffs/20260902T*` |
| 09-03 03:44 → 04:04 | 03:44 the architecture-docs daemon stops; 04:04 a name-matched `pkill` kills two daemons. The cause of the first crash flips three times. | R15, R21 | `architecture-docs/executor/URGENT-pkill-incident.md`, `reply-from-aiur-executor.md` |
| 09-03 05:35 | aiur handoff: cursor still 2832 with ~1,476 unconsumed although #2481 merged; "Four concurrent agents took this box to load 84 and starved the fleet to 0/16." | R4, R7, R19 | `aiur/executor/handoffs/20260903T053500Z-handoff.md` |
| 09-03 ~07:15 | The aiur Executor's session dies in API 529s; no successor for ~8.5 h. | R6 | `architecture-docs/executor/handoffs/20260903T154905Z-handoff.md` |
| 09-03 | Architecture-docs dispatch frozen 9–12 h; four root causes proposed in one day; the real one is a 1 MiB list cap (#2533 → #2535). Executors rotate Claude → DeepSeek → Codex → Claude. Two usage-limit absences; fleet 0/15 behind 8 unanswered Commands. | R1, R11, R6, R2 | architecture-docs handoffs, retro |
| 09-03 05:29 | aiur wake cursor 4329 stops advancing; it stays idle until 09-16 (198 pending). | R4 | `aiur/executor/handoffs/20260916T184046Z-handoff.md` |
| 09-03 19:23 → 22:50 | Architecture-docs cursor 107 with 59 pending, roster owner "stalled"; the cursor freezes at 352 at 22:50. | R4 | `architecture-docs/executor/handoff.md`; wake files |
| 09-04 | ~25 PRs merged on architecture-docs. Stale `blocked_by` cleared by hand; a double dispatch follows (#2546, #2550, #2551). | R14, R1 | `architecture-docs/executor/handoff.md` |
| 09-05 02:16 | Last architecture-docs wake. 1,529 of 1,881 wakes were never consumed. | R4 | `architecture-docs.executor.wakes.ndjson` |

### 2026-09-09 → 09-11 — archon runs (AHU hosted-upload, then ACN consolidation)

| When | Event | Class | Source |
|---|---|---|---|
| 09-09 22:24 | AHU run starts; handoff says to use `executor-wait` as the primary loop. Global pause from 21:53; retro logs 0 of 6 wakes actionable without mentioning it. | R4, R10 | `archon/executor/handoffs/20260909T222445Z-handoff.md`, `archon/meta/retros/` |
| 09-10 01:34 → 02:07 | Executor takeover Codex → Claude; the Codex Executor is still alive and posts a blocking review; killed at 02:07. | R21, R12 | `archon/executor/handoffs/20260910T025114Z-handoff.md` |
| 09-10 02:51 → 03:29 | The tail monitor delivers events but nothing advances the durable cursor. | R4 | `archon/meta/20260910T032946Z-*.md` |
| 09-10 04:55 → 07:28 | Claude account limit stops the fleet and the Executor for 2 h 33 m; 81 wakes pile up; two green PRs wait. | R6 | `archon/meta/20260910T073040Z-*.md` |
| 09-10 04:22 → | Rebuild request to retire the stale dependency hold (#2553/#2566) and deploy #2604; never answered in the records (≥23 h). Cache-drop by hand at every wave; recipe changes three times. | R2, R7, R14 | archon handoffs, metas |
| 09-10 10:30 | Build Order page six hours stale. | R9 | `archon/meta/20260910T103038Z-*.md` |
| 09-10 14:29 | A delegated reviewer silent 85 min before anyone checked. | R3, R20 | `archon/meta/20260910T142948Z-my-reviewer-went-quiet.md` |
| 09-10 15:22 → 16:29 | 12 merged; the last PR waits at the operator gate (#176). | R2 | `archon/meta/20260910T152251Z`, `162935Z` |
| 09-10 17:35 | ACN consolidation run starts. The Executor works in "manual mode": PENDING grows 0 → 45 → 139 → 233 by 09-11 01:29. | R4 | `archon/meta/20260910T173554Z…20260911T012935Z` |
| 09-10 18:56 | Parking tickets as `agent:in-progress` causes duplicate dispatch. | R1 | `archon/executor/handoff.md` |
| 09-10 19:33 | Two daemons saturate the host. | R15 | `aiur/meta/20260910T193340Z-two-daemon-host-saturation.md` |
| 09-10 22:33 | Recovered from OOM, 8 of 13 merged. | R15 | `archon/meta/20260910T223334Z-*.md` |
| 09-11 02:31 | 7 aiur quick-fix PRs had sat green and blocked on REVIEW_REQUIRED because the CI waiter filtered for a check named "ci". | R3, R10 | `aiur/meta/20260911T023131Z-*.md` |
| 09-11 03:33 | Code-complete hold; 15 aiur PRs unreviewed (parked). Last archon wake 09-11 16:56; 264 of 810 never consumed. | R3, R4 | `archon/meta/20260911T033302Z-*.md`; wake files |

### 2026-09-16 → 09-17 — aiur resume run (Codex Executor "Root") and khala first run

| When | Event | Class | Source |
|---|---|---|---|
| 09-16 17:41 → 17:52 | aiur resume: 198 wakes pending since 09-03; roster ack null. | R4 | `aiur/executor/handoffs/20260916T175204Z…184046Z` |
| 09-16 19:12 | `executor-wait` through the dev shim rebuilds the shared release under a foreign daemon; restored from backup; #2656 filed (still unfixed). | R15 | `aiur/executor/handoffs/20260916T191440Z-handoff.md` |
| 09-16 19:22 | khala run starts: 44 leaves materialized, 6 workers. Skill example config and wake path wrong (#2660, #2661). | R10 | `khala/executor/handoffs/20260917T151838Z-previous.md` |
| 09-16 19:33 → 19:47 | khala publishing bot is Read-only; all workers pause on a human decision. #12/#13 stranded by a same-daemon host lock (#2662). | R2, R13 | same; `khala/executor/evidence/paused-workspace-lock.md` |
| 09-16 ~20:05 | The khala Executor corrects its own Build Order topology, filed earlier as Aiur defect #2659. | R11 | khala handoff previous |
| 09-16 18:30 → 22:08 | aiur Executor busy: ~40 evidence packets, 6 main merges. Five main-move waves re-integrate every open PR (~40 re-integrations in 27 h). | R3, R8, R19 | `aiur/executor/evidence/` |
| 09-16 22:10 → 09-17 02:19 | **Both Executors stop taking turns** for ~4 h. On resume: "tool/clock continuity resumed"; khala's relay replays 49 reminders and then ~80 stale turns over 47 min. | R6, R4 | `aiur/meta/retros/resume-20260916T175148Z.md`; khala handoff previous |
| 09-17 02:27 | #2677 merges and invalidates 5 green PRs. No aiur merge for 12.75 h (to 15:12). | R3, R8 | aiur evidence; git log |
| 09-17 02:19 / 02:56 | Last aiur hourly retro (02:19) and last aiur wake ack (02:56). 66 later wakes are never consumed; the owner lease keeps renewing to 09-22. | R10, R4 | resume retro; `aiur.executor.claims.json` |
| 09-17 03:00 → 21:23 | No aiur fleet worker runs while the Executor implements #2680–#2687 itself; the user then says "many independent defects may use native Aiur agents". | R19 | `aiur/executor/handoff.md` |
| 09-17 05:35 → 12:52 | khala handoff silent 7 h 17 m while hourly retros continue. #2677 deployed to khala 10 h 23 m after merge. 0 of 44 implementation tickets closed after ~17.5 h. | R12, R7 | khala handoff previous, retro |
| 09-17 15:18 | khala switches to the Executor's own agents under a global pause; the wake relay is stopped as "periodic no-action spam". | R19, R9 | `khala/executor/handoffs/20260917T151838Z-handoff.md` |
| 09-17 22:07 | Host-lock fix #2666 merges after 26 h (preventive only; worker 17 hit the same fault at 16:53). | R13 | aiur evidence; `aiur/executor/handoff.md` |

### 2026-09-18 → 09-20 — khala build run

| When | Event | Class | Source |
|---|---|---|---|
| 09-18 01:10 → 04:47 | Dense work: 35 merges between 01:28 and 12:15. 4 restarts in the day. | — | `khala/executor/handoffs/20260918T*`; khala git log |
| 09-18 04:04 → 04:16 | Rework on #68, #70, #72 missed: the rework watcher only covered earlier PRs. | R3, R10 | `khala/executor/handoffs/20260918T105952Z-handoff.md` |
| 09-18 04:47 → 08:22 | Shared Claude limit: fleet, Executor and review agents stop; 6 rework tickets go to `agent:error`; ~1 h after the reset until the operator returned. | R6 | same |
| 09-18 08:20 → 09:36 | Provider switches Claude → Codex → Claude after a Codex account limit; `model:*` labels re-pinned by hand. | R6 | same |
| 09-18 12:15 → 20:58 | 8.7 h with no merges; cause not stated. | R6? | S7 (git + wakes) |
| 09-18 12:55 | khala wake cursor stops at 517; it stays there until 09-24 22:15. | R4 | `khala/executor/handoff.md` |
| 09-18 22:22 → 09-19 17:56 | 19.6 h with no merges while #117–#119 were ready; hidden by invented session-log times. | R12, R3 | S7 (git + wakes) |
| 09-19 | #104 and #105 held by a stale dependency again ("Pattern persists despite aiur#2710"). | R14 | `khala/executor/handoffs/20260920T073235Z-previous-live-handoff-with-session-log.md` |
| 09-20 | #42 silently starved by the issue-timeline cap ("deferred dispatch silently every 60 s forever"); local patch; #2749 filed. "`WAKES PENDING` grew from 89 to 155 because I never ran `executor-wait`." | R1, R4 | `khala/executor/handoffs/20260920T073235Z-handoff.md` |
| 09-20 03:33 | The operator ends the goal. | — | same |

### 2026-09-24 → 09-26 — khala E09 run

| When | Event | Class | Source |
|---|---|---|---|
| 09-24 19:05 | Work restarts; the handoff header still says "goal ended, do not resume". | R12 | `khala/executor/handoff.md` |
| 09-24 22:15 | "My gaps: the wake inbox wasn't drained (262 pending, now drained); the wake monitor lapsed after the session resume". | R4 | same |
| 09-24 23:12 | Daemon restarted onto aiur 7dd56fc ("both dispatch fixes"). | R7 | `khala/executor/evidence/ci-wait-165-*` |
| 09-24 23:21 | The Executor's own 45 s PR monitor hits the GraphQL limit. | R10, R16 | `khala/executor/handoff.md` |
| 09-25 00:23 | Fleet idle ~45 min at 0/12 because rework did not trigger; rework strands relabelled by hand on 6 tickets. | R5 | `khala/executor/handoff.md` |
| 09-25 00:52 → 01:57 | #165 stranded in `agent:ci-wait` (`:no_agent_work_state`); 112 wakes pending; 8 of 12 slots idle; 36 tickets awaiting dispatch with no decline. | R1, R4 | `khala/executor/evidence/ci-wait-165-20260925T015708Z/` |
| 09-25 07:08 | Codex limit auto-pauses the fleet in 7 min (#2742 works). | R6 | `khala/executor/handoff.md` |
| 09-25 08:28 → 22:02 | 13.6 h stall: 8 PRs in human-review, monitors expired without re-arm, Codex limit from ~12:06; one ticket produced 93 attention wakes. | R4, R3, R9 | same |
| 09-25 23:35 | Codex 401 puts 18 tickets in `agent:error`; a 10-minute self-poll cron is set up with five steps and no retro step. | R17, R10 | same; e09 retro |
| 09-26 01:57 → 03:45; 07:06 → 08:57 | Two Claude limits. At 03:47 provider-limited pauses hold 16 of 20 slots; hand-resumes follow. | R6, R13 | `khala/executor/handoff.md` |
| 09-26 05:57 | Daemon upgraded to 3339b88 with #2815: "Manual rework relabels should no longer be needed." | R5 | same |
| 09-26 09:46 → 13:56 | Rework strand again on #379, #385, #392, #420. `agent:todo` non-dispatch ≥10 reproductions; ci-wait strands (#367 for 2 h); red main from a semantic merge (#399 × #406). About 40 PRs merged in the day. | R5, R1, R8 | same; e09 retro |
| 09-26 15:00 | E09 retro: no hourly retros since 09-17. Causes: the self-poll prompt had no retro step; compaction truncated the `aiur-run` skill (73.4 KB) before the retro section; the action log was mistaken for a retro. Hourly retro cron armed. | R10, R12 | `khala/meta/retros/20260926T1500Z-e09-executor.md` |
| 09-26 15:15 | Final wake state: khala 0 pending; aiur 66, archon 264 and architecture-docs 1,529 never consumed. | R4 | wake and cursor files |
