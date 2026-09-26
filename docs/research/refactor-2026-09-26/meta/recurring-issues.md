# Recurring problems in the Executor's own records

Research lane: Executor records (meta checks, retrospectives, handoffs, findings).
Period covered: 2026-08-02 to 2026-09-26. Written 2026-09-26.
Companion file: [`timeline.md`](timeline.md).

## Scope and method

Sources, all under `~/.aiur/repo/`, read-only:

| Source | Count |
|---|---|
| `aiur-team/aiur/meta/*.md` hourly checks | 95 (one is a byte-identical duplicate) |
| `aiur-team/archon/meta/*.md` hourly checks | 22 |
| `*/meta/retros/*.md` retrospectives (+ 41 `verdict.md`) | aiur 8, archon 2, khala 3, architecture-docs 1 |
| `*/executor/handoffs/*.md` and `executor/handoff.md` | aiur 21 + 4, archon 6 + 1, khala 62 + 1, architecture-docs 2 + 1, kevinweaver-dev 1, one private repo 1 |
| Other Executor files (URGENT notes, inter-Executor mail, `e09-shared-decisions.md`, 107 evidence `.md`, 42 monitoring notes) | about 160 |
| `meta/findings.ndjson` | 73 records (aiur 43, khala 13, kevinweaver-dev 9, archon 8) |

Eight reading agents each read one disjoint slice of these documents in full, using one
shared class list. Their notes are in `../scratch/slice-S1.md` … `slice-S8.md`, with a
per-document log, per-class tables, fix tables and standing-item lifetimes. I read the
calibration retro (`khala/meta/retros/20260926T1500Z-e09-executor.md`) and checked the key
quotes against the sources myself. I also read the wake inboxes (`executor/*.wakes.ndjson`)
and the `aiur-run` skill history, to measure what the documents claim.

**Counting unit.** "Citations" is the number of distinct documents that record the problem,
summed over the eight slices. The long khala files are counted per section, and the
57-version khala handoff series is counted per change cluster, not per file. Citations
measure how often the Executor wrote about a problem. "Incidents" are the dated events with a
stated cost. Both numbers are approximate; the ranking does not depend on their exact values.

**Privacy.** One private repo is in the corpus. It is reported only as counts and categories.

## Summary: the ten most expensive recurring problems

Ranked by stated cost (hours stalled, tickets stranded) first, then by recurrence.
"Fix held?" asks whether the records show the problem again after a fix was claimed.

| # | Problem class | Citations | Span | Repos | Largest stated costs | Fix held? |
|---|---|---|---|---|---|---|
| 1 | Tickets strand silently in the daemon's state machine (dispatch, labels, size caps, ci-wait) | ~150 | 08-02 → 09-26 | all 5 + private | fleet 15→1 overnight; 13 agents stalled ~15 h; dispatch frozen 5 h and 9–12 h by silent size caps; ≥10 non-dispatch reproductions on 09-26 | **No.** ≥12 fixes, recurred after most |
| 2 | Human and authority gates hold agents for hours to weeks | ~110 | 08-03 → 09-26 | 5 | 4 workers × ~17 h (~68 worker-hours) on one permission question; green PRs waiting 15–16 days; rebuild request unanswered ≥23 h | **No.** Authority-floor fixes did not change the floor |
| 3 | The Executor is the only reviewer and merger, and review is serial | ~60 | 08-08 → 09-26 | aiur, archon, khala | 17 reworked PRs unreviewed up to a day; queue grew to 40 with 0 approved; 12.75 h with no merge; 4 approved PRs abandoned | **No.** Skill rules added twice; recurred |
| 4 | The Executor's discovery path is not running (durable wake inbox not consumed; monitors lapse) | ~60 | 08-18 → 09-25 | aiur, archon, khala, arch-docs + private | cursor stuck 5 days, then frozen 11 days, then idle 13.5 days; 1,529 wakes never consumed; 13.6 h stall when monitors expired | **No.** Skill rule (#2412) and code fix (#2481) both followed by recurrences |
| 5 | Rework is not re-dispatched after a request-changes review | ~48 | 08-05 → 09-26 | aiur, archon, khala | 12 of 12 green PRs in a rework loop; 19+ manual relabels in khala, 5 after the latest fix | **No.** ≥10 fix attempts, #1427 → #2817 |
| 6 | The Executor and the fleet stop together (provider quota, session death, host continuity) | ~58 | 08-10 → 09-26 | aiur, archon, khala, arch-docs | 2 h 33 m, 3.6 h, ~4 h 06 m, ~8.5 h, part of 13.6 h; 16 of 20 slots held after a limit | Partly: Codex limit auto-paused in 7 min on 09-25; Claude limits still needed hand-resumes 09-26 |
| 7 | Merged fixes do not run until someone rebuilds and restarts | ~100 (with restart friction) | 08-09 → 09-26 | aiur, archon, khala, arch-docs | "a day of merged work had never run"; fixes inert 6–7 h, 10 h 23 m, all day; peer re-reported 4 fixed bugs | **No.** No "running build is older than main" surface was built |
| 8 | CI instability, red main and a serial merge train | ~110 | 08-05 → 09-26 | aiur, archon, khala | red main froze the merge train (08-23); ~40 re-integrations of 12 PRs in 27 h; 17 red CI runs, 12 of them old flakes | **No.** Flake fixes chain from #1591 to #2740 |
| 9 | Status surfaces lie and alerts are mostly noise | ~115 | 08-02 → 09-26 | all 5 | 68–73 % of two wake inboxes was capacity noise; 275 wakes / 3 actions in one run; stalls hidden behind "healthy" | Partly: #2592/#2622 removed one noise source |
| 10 | The Executor's own loop omits required steps (hourly check as loop, self-poll prompt, retros lapse) | ~48 | 08-09 → 09-26 | all 5 | 9 days with no hourly retro; hourly check was the real loop for days; a CI waiter that never fired | **No.** Rule written 07-13, restated 08-23 and 09-26 |

Other recurring classes (11–21) are in the full taxonomy below: Executor misdiagnosis,
handoff and compaction context loss, capacity leaks, stale dependency holds, host saturation
and shared releases, GitHub budget, credentials and the authorship trap, verification gaps,
the Executor doing fleet work, agent stalls, and cross-Executor coordination.

### Verdict on the operator's hypothesis, in one paragraph

**Supported, but the mechanism is different from "loss of focus".** The records show long,
frequent gaps in which neither the Executor nor the agents progress: at least 50 dated gaps,
from 45 minutes to 13.5 days. But the most common causes are not an attentive Executor drifting
away. They are: (a) a discovery path that does not run by itself, so the Executor learns about
work only when it happens to look; (b) a single, serial review lane that treats review as one
pass, so rework pushes go unseen; (c) daemon states that strand tickets while every surface
reports health; (d) Executor sessions that stop entirely (quota, crash, host) with nothing to
notice; and (e) gates only a human can open, while the human is away. When a working event
loop and quota were present, the Executor answered events in seconds (archon: push → wake
18 s, review → label 35 s). The problem is structural: nothing in Aiur holds the Executor's
loop together when the Executor is absent, busy, or wrong. Details are in
[the hypothesis section](#the-operators-hypothesis-tested).

---

## Full taxonomy

Families: **A** Executor loop and attention, **B** daemon ticket state, **C** human and
authority gates, **D** deployment and truth, **E** environment. Rank is the overall rank.

### Rank 1 — B1. Tickets strand silently in the daemon's state machine

**Definition.** A ticket that should run does not run: it is undispatchable, mislabelled,
held by a stale latch or a silent response-size cap, or parked in a state (`agent:ci-wait`,
zero labels, contradictory labels, orphaned claim) that nothing polls, and no surface says so.

- **Citations:** ~150 (dispatch failure ~66, label corruption ~57, dispatch latch 11,
  before-run latch 5, prewarm 5, response caps 2, ci-wait strands 4). **First seen**
  2026-08-02 (findings: latch exhaustion, prewarm base failure). **Last seen** 2026-09-26
  (khala: `agent:todo` non-dispatch ≥10 reproductions).
- **Repos:** aiur, archon, khala, architecture-docs, kevinweaver-dev; also a private repo.
- **Key sources:** `aiur/meta/2026-08-09T1300Z-hourly.md`, `2026-08-09T2345Z-hourly.md`,
  `2026-08-10T0840Z…1500Z-hourly.md`, `aiur/executor/handoffs/20260817T154710Z…20260903T053500Z`,
  `aiur/meta/20260823T033000Z-seven-tickets-deadlocked-by-a-label-never-cleared.md`,
  `aiur/meta/20260823T122000Z-a-budget-hold-errored-ten-tickets.md`,
  `architecture-docs/executor/handoffs/20260903T154905Z-handoff.md`,
  `khala/executor/handoffs/20260920T073235Z-*.md`,
  `khala/executor/evidence/ci-wait-165-20260925T015708Z/`, `khala/executor/handoff.md`,
  `khala/meta/retros/20260926T1500Z-e09-executor.md`.
- **Stated cost:**
  - 08-08/09: 13 agents stalled about 15 h on a blocker that was never closed, while hourly
    checks ran.
  - 08-09: the fleet fell from 15 agents to 1 overnight (label cache, #1682).
  - 08-10: about 10 latch resets per hour by hand ("only works because I am here doing it").
  - 08-18: about 5 h with no dispatch, caused by a 64 KiB response cap. It was first
    misdiagnosed as a missing `ci-readiness.json` (#2139).
  - 08-23: 7 tickets deadlocked by a label; 10 tickets pushed into `agent:error` by a budget
    hold ("A 45-minute throttle became a permanent stop for ten tickets").
  - 09-03: architecture-docs dispatch frozen 9–12 h by a 1 MiB list cap (#2533/#2535).
  - 09-20 and 09-26: an issue-timeline cap made the daemon "defer dispatch silently every
    60 s forever — no alert" (#2749, then #2816).
  - 09-25: 36 tickets waiting for dispatch with no decline reason while 8 of 12 slots were
    free; #165 stranded in `agent:ci-wait` ≥64 min (`:no_agent_work_state`).
  - 09-26: ~15 logged dispatch nudges on ~40 tickets, plus 13 more in the retro only.
- **Fixes claimed and recurrence:** #1453 → #1759/#1760 (latch); #2075 (dual-state) recurred
  the same day on #2066; #2172 startup reconciler → 7 tickets still contradictory 40 min after
  boot; #2420/#2437/#2426 → 3 tickets stranded unlabelled on 09-03; #2366 → #2767 (ci-wait)
  → strands again 09-26 (#367 for 2 h, #350, #232); #1454 (64 KiB) → #2533 (1 MiB) →
  #2749 → #2816 (timeline) — the same silent-cap shape three times; #2076 (orphaned claims)
  → orphaned claim again 09-26 (#390); aiur 7dd56fc "both dispatch fixes" (09-24) → 36 idle
  tickets 09-25. Open at the end: #2817–#2819.
- **Quotes:**
  - "the daemon classified the emptied 200 as `:timeline_truncated` and **deferred dispatch
    silently every 60 s forever** — no alert." (`khala/executor/handoffs/20260920T073235Z-handoff.md`, repeated in `khala/executor/handoff.md`)
  - "The honest summary of this run: the agents performed well. Most elapsed time went to
    silent state changes, not to work." (`aiur/meta/2026-08-09T1300Z-hourly.md`)

### Rank 2 — C1. Human and authority gates hold agents for hours to weeks

**Definition.** Agents stop on a decision or permission that only a human may give, or that
the Executor has the answer to but is not allowed to record. The human is away, the policy is
not to re-prompt, and waiting agents send reminders that bury the one open question.

- **Citations:** ~110. **First seen** 2026-08-03 (kevinweaver-dev handoff: "229 minutes lost
  waiting on permission never required", the lesson of an earlier aiur run). **Last seen**
  2026-09-26 (khala #45).
- **Repos:** aiur, archon, khala, architecture-docs, kevinweaver-dev.
- **Key sources:** `aiur/meta/2026-08-09T2100Z-hourly.md`,
  `aiur/meta/20260821T220000Z-uncommitted-config-stalled-the-fleet.md`,
  `aiur/meta/20260822T*` (19 logs), `aiur/meta/20260823T*` (19 logs),
  `archon/meta/20260910T152251Z…162935Z`, `khala/meta/retros/khala-first-collaboration-20260916.md`,
  `khala/executor/handoffs/20260917T151838Z-previous.md`, `khala/executor/handoff.md`.
- **Stated cost:**
  - 08-09: 10 decisions answered as ticket comments, which nothing reads. 2 of 14 agents
    active "for hours".
  - 08-21: "asked ten times over hours"; the Executor was not allowed to answer.
  - 08-22/23: two blocking decisions (`dec_618300f599847cb2`, `dec_90176f24eca3e497`) aged
    19 h → 38 h. Their PRs (#2171 green since 08-18, #2306 green since 08-22) were still
    waiting on 09-03: 15–16 days.
  - 09-03: architecture-docs fleet at 0/15 behind 8 unanswered Commands.
  - 09-10: aiur Decisions 390+ h old; archon rebuild request unanswered ≥13.6 h, and never
    answered in the records (≥23 h).
  - 09-16/17: khala publishing bot had Read-only access; 4 workers paused ≥19 h 45 m
    (~68 worker-hours). The human dismissed and deferred the dashboard Commands without
    answering them.
  - 09-19 → 09-26: khala #41 waited ~6.9 days for credentials.
- **Fixes claimed and recurrence:** #2074 (answer diagnostics) → #2224 → PR #2275 ("does not
  change the authority floor") → #2301 → #2440 (still misclassifying all four decisions on
  09-03) → khala `human_required` refusals on 09-18. Decision delivery: #2662/#2666 → #2730 →
  #2738 → the same failure on #39 and #101 the same evening. #2262 (supervisor token empty)
  open throughout 08-22.
- **Quotes:**
  - "Agents diagnosed their own blocker correctly, asked ten times over hours, and every
    request expired because no human was at the keyboard and the Executor was forbidden to
    answer." (`aiur/meta/20260821T220000Z-uncommitted-config-stalled-the-fleet.md`)
  - "four workers spent most of the hour paused, approximately four worker-hours. Bot remains
    Read. New dashboard actions dismissed10/50 requests and deferred11, without granting
    access" (`khala/meta/retros/khala-first-collaboration-20260916.md`)

### Rank 3 — A1. The Executor is the only reviewer and merger, and review is serial

**Definition.** Finished PRs wait because one Executor reviews and merges everything, treats
review as a single pass, misses rework pushes, and re-integrates every open PR each time main
moves. Approved PRs are abandoned when the session ends.

- **Citations:** ~60 (review backlog ~52, plus re-integration waves and abandoned PRs).
  **First seen** 2026-08-08 (`aiur/meta/2026-08-08T2200Z-bottleneck.md`, 19 open PRs).
  **Last seen** 2026-09-25 (khala: 8 PRs in `human-review` for 13.6 h).
- **Repos:** aiur, archon, khala.
- **Key sources:** `aiur/meta/2026-08-09T0000Z-hourly.md`, `aiur/executor/handoffs/20260817T154710Z-handoff.md`,
  `20260818T001943Z-handoff.md`, `20260823T215617Z-handoff.md`,
  `aiur/meta/20260822T153000Z…223000Z`, `aiur/meta/20260823T083000Z…132000Z`,
  `archon/meta/20260910T142948Z-my-reviewer-went-quiet.md`,
  `aiur/meta/20260911T023131Z-quickfix-backlog-cleared-archon-code-complete.md`,
  `aiur/executor/evidence/` (re-integration bodies), `khala/executor/handoffs/20260918T105952Z-handoff.md`,
  `khala/executor/handoff.md`; `aiur-run` SKILL.md (cites 08-20).
- **Stated cost:**
  - 08-09: a research spike while the queue grew 22 → 30.
  - 08-17/18: 5 PRs "Unreviewed all run" (~22 h).
  - 08-20: 17 PRs reworked but unreviewed, 16 with no failing check, the oldest nearly a day,
    one of them the fix for a bug that was erroring tickets (recorded in the `aiur-run` skill).
  - 08-22: queue 10 → 40 non-draft PRs with 0 approved. At 15:30Z review "starved the fleet":
    `agent:todo` empty, 18 tickets in `human-review`, 1 agent working. 11 reworked PRs unseen
    for up to ~5 h.
  - 08-23: merges flat at 51 for ~3 h with 9 green PRs waiting; 14 green PRs "sitting because
    I have not looked at them"; 8 PRs left unreviewed at handoff.
  - 09-10: a delegated reviewer silent 85 min before anyone checked.
  - 09-11: 7 green PRs blocked on REVIEW_REQUIRED because the Executor's CI waiter filtered for
    a check named "ci", which does not exist; 15 more unreviewed an hour later.
  - 09-16/17: ~40 re-integrations of 12 PRs in 27 h (36 by the Executor, only 1 real
    conflict); 12.75 h with no merge to main; 4 approved PRs never merged (#2643, #2669, #2673
    still open on 09-26; #2644 closed), and 2 of those bugs were fixed a second time under new
    numbers (#2684/#2685, #2697/#2701).
  - 09-18: rework on #68, #70, #72 missed because the rework watcher covered only earlier PRs;
    #117–#119 ready ~19 h.
- **Fixes claimed and recurrence:** #2337 (re-review on rework push, filed 08-22); #2344 (skill:
  "re-review as a loop"); #2412 (skill: rework push means re-review now); #2601 → PR #2620
  (09-11). The pattern recurs on 09-11, 09-16/17, 09-18 and 09-25.
- **Quotes:**
  - "Correction: red `main` is not what froze the merges. I was."
    (`aiur/meta/20260823T112500Z-i-was-wrong-about-what-froze-the-merges.md`)
  - "I was treating review as a queue to drain once. It is a loop."
    (`aiur/meta/20260822T223000Z-i-am-the-uncontrolled-load.md`)

### Rank 4 — A2. The Executor's discovery path is not running

**Definition.** The durable, cursored wake inbox (`executor-wait`) is not consumed. The
Executor watches a notification-only tail or a session Monitor instead, which dies with the
session or after 30 minutes, so work is found late, by the hourly check, or by chance.

- **Citations:** ~60. **First seen** 2026-08-18 (aiur inbox starts; cursor stays at 1).
  **Last seen** 2026-09-25 (khala: monitors expired; 112 pending in the evidence capture).
- **Repos:** aiur, archon, khala, architecture-docs; also a private repo (55 of 117 wakes
  never consumed).
- **Measured wake-inbox state (from `executor/*.wakes.ndjson` and `*.wakes.cursor.json`):**

  | Repo | Episode | Unconsumed |
  |---|---|---|
  | aiur | cursor at `wake_id 1` for 5 days (~08-18 → 08-23) | 2,832 records drained on 08-23 |
  | aiur | cursor frozen at 2832 from 08-23 to ≥09-03 | 1,137 → ~1,476 |
  | aiur | cursor 4329 idle from 09-03 05:29Z to 09-16 17:52Z | 198 |
  | aiur | last ack 09-17 02:56Z; owner lease still renewed on 09-22 | 66 (to 09-20) |
  | architecture-docs | cursor frozen at 352 from 09-03 22:50Z | **1,529 of 1,881** (still) |
  | archon | "manual mode" from 09-10 17:35Z; PENDING 0 → 45 → 139 → 233 | 264 of 810 (still) |
  | khala | cursor stuck at 517 from 09-18 12:55Z to 09-24 22:15Z | 89 → 155 → 262 |
  | khala | 09-25 evidence capture | 112 |

  The operator's "2,832 unconsumed" is the first episode. The same failure then recurred four
  more times on aiur and once in each other repo.
- **Stated cost:** 17 reworked PRs unseen (08-20); 81 wakes piled up during the archon quota
  outage; 7 green PRs never noticed (09-11); a 13.6 h stall on 09-25 ("the monitors expired
  without being re-armed"); a 47-minute replay storm after the khala relay caught up (09-17).
- **Why it keeps happening (from the documents):** there are two consumers. The Executor acts
  on the tail, which "delivers events but does NOT advance the cursor". `status` then shows a
  growing PENDING number that nobody reads, and most of it is noise (68 % of archon's inbox and
  73 % of architecture-docs' inbox are `capacity_starved` events flagged `needs_attention`).
  The monitor "does not survive a restart of the Executor session". A lease keeps renewing
  after the consumer is dead, so the roster looks healthy.
- **Fixes claimed and recurrence:** `aiur-run` rule "Running the hourly meta-check as the
  primary loop while the wake inbox goes undrained is a failure mode" (#2412, 08-23) → cursor
  frozen again 08-23 → 09-03. #2472 → PR #2481 merged but not running on 09-03. #2600 → PR #2619
  and #2592 → PR #2622 (09-11). #2661 → PR #2664 (wrong journal path in the skill). #2606
  (`ready_for_review` never fires). Recurred on archon (09-10/11), khala (09-20, 09-24, 09-25)
  and aiur (09-17 → 09-20).
- **Quotes:**
  - "**Wake inbox: cursor frozen at 2832, 1137+ pending.** Filed #2472; PR #2481 open (draft).
    The `tail -F` monitor delivers events but does NOT advance the cursor — that is the design
    gap." (`aiur/executor/handoffs/20260902T035500Z-handoff.md`)
  - "STALL: the fleet sat idle about 13h (09:00Z–22:00Z). 8 PRs were waiting in human-review,
    and the monitors expired without being re-armed." (`khala/executor/handoff.md`, 09-25)

### Rank 5 — B2. Rework is not re-dispatched after a request-changes review

**Definition.** After a reviewer requests changes, the ticket stays in `agent:human-review`
(or bounces back to it), so no agent picks up the rework until someone relabels and resumes it
by hand.

- **Citations:** ~48. In khala alone, 12 logged events and 19+ ticket interventions from 09-18
  to 09-26. **First seen** 2026-08-05 (`aiur/meta/retros/20260805T000326Z-309948.md`, #1389).
  **Last seen** 2026-09-26 13:56Z (khala #420).
- **Repos:** aiur, archon, khala.
- **Key sources:** `aiur/meta/2026-08-10T1030Z-hourly.md`, `aiur/meta/retros/pr-completion-20260901.md`,
  `aiur/executor/handoffs/20260823T215617Z-handoff.md`, `20260902T035500Z-handoff.md`,
  `archon/meta/20260910T132941Z-last-proof-round-three.md`, `archon/executor/handoff.md`,
  `khala/executor/handoff.md`, `khala/meta/retros/20260926T1500Z-e09-executor.md`.
- **Stated cost:** a stale CHANGES_REQUESTED deadlock (08-10); "12 of 12" green PRs stuck in a
  rework loop (#2422, 08-23); 5 re-route instances on archon (#2601, 09-10); fleet idle ~45 min
  at 0/12 because rework did not trigger (09-25); ≥5 reproductions on the build that carried the
  latest fix (09-26).
- **Fixes claimed and recurrence — the longest chain in the corpus:** #1389 → PR #1427 → #1756
  → PR #1758 → #2065 → #2337 → #2422 → #2473 → #2477 → #2601 → PR #2620 → #2798 (closed
  unmerged) → #2801/#2804 → #2815 → #2817 (open). It recurred after each one that shipped.
- **Quotes:**
  - "Manual rework relabels should no longer be needed." (`khala/executor/handoff.md`,
    09-26 05:57Z), then 5 h 47 m later: "#392 rework strand again: human-review not reactivated
    by request-changes; relabel agent:rework + resume worked (3rd occurrence: #379, #385,
    #392)" (same file, 11:44Z).
  - "The agent makes exactly the right transition; the daemon re-derives from
    `reviewDecision`, still reads `CHANGES_REQUESTED`, and forces it back."
    (`aiur/executor/handoffs/20260823T215617Z-handoff.md`)

### Rank 6 — A3. The Executor and the fleet stop together

**Definition.** The Executor stops taking turns because of a provider usage limit it shares
with the fleet, an API failure, a host or terminal break, or a model rotation, and nothing
notices or replaces it.

- **Citations:** ~58 (provider quota ~43, Executor-absence gaps ~15). **First seen**
  2026-08-10 (Claude session limit sent 12 tickets to `agent:error`). **Last seen**
  2026-09-26 (two Claude limits, 1.8 h and 1.9 h).
- **Repos:** aiur, archon, khala, architecture-docs.
- **Stated cost:**
  - 09-03: the aiur Executor's "session died in API 529s"; no successor for about 8.5 h
    (estimate from architecture-docs handoffs). The architecture-docs Executor rotated
    Claude → DeepSeek → Codex → Claude the same day.
  - 09-10: a Claude account limit stopped the archon fleet and its Executor for 2 h 33 m; two
    hourly checks were missed.
  - 09-10: two archon Executors ran at once for ~20 min after a handoff (a split review).
  - 09-16 22:10Z → 09-17 02:19Z: **both** the aiur and the khala Executors stopped for about
    4 h at the same time and resumed within the same minute ("tool/clock continuity resumed
    at 2026-09-17 02:19 UTC"). A 47-minute replay storm followed.
  - 09-18: Claude limit 3.6 h; "My review agents also stopped"; ~1 h after the reset until the
    operator returned. Two more gaps of 8.7 h and 19.6 h have no stated cause.
  - 09-26 03:47Z: after a limit reset, provider-limited pauses held 16 of 20 slots.
- **Fixes claimed and recurrence:** #2607 → PR #2627 (filed 09-10, although the same failure
  happened on 08-10) → failed on 09-18 → #2727/#2729 → #2742 (Codex limit, worked in 7 min on
  09-25) → #2811/#2812 (slot hold, drain speed); #2764 (downtime alert, filed). Hand-resumes
  still logged on 09-26.
- **Quotes:**
  - "**Cost:** 2 h 33 m of a fully staffed fleet at 0/5; #182 and #184 sat green and mergeable
    from 04:55Z; 81 wakes unconsumed." (`archon/meta/20260910T073040Z-account-rate-limit-killed-fleet-and-executor-for-2h30.md`)
  - "Fresh census correction after tool/clock continuity resumed at 2026-09-17 02:19 UTC …
    No intervening hourly/capacity checks are fabricated." (`aiur/meta/retros/resume-20260916T175148Z.md`)

### Rank 7 — D1. Merged fixes do not run until someone rebuilds and restarts

**Definition.** A fix is merged but the daemon still runs an older build. Rebuilding is slow,
hazardous on a shared release, or needs permission, and every restart has side effects
(pauses survive, WIP is wiped, retry ladders reset, ports move).

- **Citations:** ~100 (merged-but-inert ~54, restart friction ~45). **First seen** 2026-08-09.
  **Last seen** 2026-09-26 (khala backup ritual before each of 12 restarts).
- **Repos:** aiur, archon, khala, architecture-docs.
- **Stated cost:** #1758 inert 6–7 h under the operator's "report rather than restart" rule
  (08-10); 4 PRs inert 1–3 h (08-22); "a day of merged work had never run", the "fourth time
  tonight" (08-23); #2481 and #2395 merged but a rebuild "owed and unscheduled" (09-03);
  #2553/#2604 inert on archon all of 09-10 while every wave needed a cache-drop by hand;
  #2677 inert on khala 10 h 23 m (09-17); the khala peer re-reported four already-fixed bugs
  from an old build (09-16/17); a restart wiped a 21 KB WIP (09-18); 12 khala restarts in 9 days
  each needed a manual workspace backup, and a restart resets the decision retry ladder (09-17).
- **Fixes claimed and recurrence:** standing restart authority (08-10); memory rules "merged
  code is inert until rebuilt". No "running build older than main" alert was filed or built
  (flagged as "worth a ticket if it recurs" on 08-22; it recurred the same day). #2656
  (`executor-wait` rebuilds the shared release) is still unfixed, which makes rebuilds risky.
- **Quotes:**
  - "The full chain is edit → commit → merge → pull → restart → **verify behaviour**, and I
    stopped at step one three separate times today." (`aiur/meta/20260821T232000Z-burn-scales-with-fleet-throttled-to-4.md`)
  - "**This will recur at every wave until the shared release is rebuilt from current main.**"
    (`archon/executor/handoffs/20260910T025114Z-handoff.md`)

### Rank 8 — D2. CI instability, red main and a serial merge train

**Definition.** Flaky tests, environment breaks and semantic conflicts turn main red or eject
PRs. Each merge forces every other open PR to re-integrate and re-run CI, so merging is serial.

- **Citations:** ~110. **First seen** 2026-08-05. **Last seen** 2026-09-26 (khala #399 × #406
  semantic conflict turned main red).
- **Repos:** aiur, archon, khala.
- **Stated cost:** "six merged, seven dirty" and "merges conflict each other" (08-22); red main
  froze the merge train (08-23); a mise release broke main and was misread as "rotating flakes"
  for days (09-02); on 09-16/17, 17 red CI runs of which 12 were old flake families (shared
  test singletons torn down, 100 ms timing probes, an `application_controller` wedge that hit
  the 20-minute partition limit); ≥17 hand merges, conflict resolutions and fix commits on
  khala agent PRs (09-18 → 09-26).
- **Fixes claimed and recurrence:** #1591/#1611/#1599/#1713/#1749 → #2247/#2285 → #2343/#2348
  ("did not fix it") → #2373/#2383 → #2397/#2405 → #2486/#2488/#2492 → #2555 → #2474/#2688 →
  #2691 → #2740 (merged 09-18). Each family was replaced by the next.
- **Quotes:**
  - "A deterministic environmental break that looks like a flake is expensive precisely because
    the existing narrative absorbs it." (`aiur/executor/handoffs/20260902T043000Z-handoff.md`)
  - "The necessary base integration triggers fresh required CI naturally; no manual retry was
    requested." (`aiur/executor/evidence/pr2645-independent-quality/aiur-2645-current-main-pr-body.md`)

### Rank 9 — D3. Status surfaces lie and alerts are mostly noise

**Definition.** Dashboards, CLI status and alerts report health, stale values or repeated
noise while work is stuck, so the Executor's checks pass while the fleet idles.

- **Citations:** ~115. **First seen** 2026-08-02. **Last seen** 2026-09-26 (stale `main-red`
  wakes after main was green, ≥4 reproductions).
- **Repos:** aiur, archon, khala, architecture-docs, kevinweaver-dev.
- **Stated cost:** stalls of 15 h and 8 h hidden behind healthy surfaces (08-09, 08-10); the
  archon Build Order page six hours stale (09-10); the same 5 alerts pasted 18 times over 17 h
  (khala 09-16/17); CLI `status` timeouts came back 4 times with 4 different causes (#1614,
  #1720, #1816, #1837); "working" zombie agents (#2235); one ticket produced 93 attention wakes
  in 13 h (khala 09-25).
- **Measured noise:** khala's first run logged 275 wakes and 3 actions (1.1 %). A paused worker
  sends a reminder every 15 minutes, which gives a steady 18 wakes per hour with no action.
  In the wake inboxes, `capacity_starved` is 68 % of archon's and 73 % of architecture-docs'
  records, all flagged `needs_attention`. The retro's own wake counter reported 2, 5 and 0
  wakes in three hours that had 17, 45 and 53.
- **Fixes claimed and recurrence:** #1614/#1720/#1816/#1837 (CLI); #2484/#2475 then
  #2592 → PR #2622 (capacity noise); #2605 → PR #2623 (sampler flood); #2674 → PR #2677 (Build
  Order progress); #2696, #2810. Noise sources keep changing.
- **Quotes:**
  - "An hourly check that misses what a human notices on sight is worse than no check, because
    it manufactures confidence." (`aiur/meta/20260822T042000Z-review-throughput-two-merged.md`)
  - "Hourly audit: 19 monitoring observations, zero actionable changes"
    (`khala/meta/retros/khala-first-collaboration-20260916.md`)

### Rank 10 — A4. The Executor's own loop omits required steps

**Definition.** The loop the Executor actually runs is not the loop the skill requires: the
hourly check becomes the main loop, a recurring prompt leaves out the retrospective, a waiter
filters on the wrong name, a watcher covers only some PRs, and retros and findings stop.

- **Citations:** ~48. **First seen** 2026-08-09 ("I wrote *'arm a one-hour timer before
  dispatching'* into the `aiur-run` skill and **never armed one myself**"). **Last seen**
  2026-09-26 (e09 retro).
- **Repos:** aiur, archon, khala, architecture-docs, kevinweaver-dev.
- **Stated cost and evidence:**
  - 08-18: "**I did not service the hourly meta-check** despite arming it, and consequently
    **the operator's dashboard was down for an unknown period and I did not notice.**"
  - 08-20: the hourly check was the Executor's real loop while the inbox held 2,832 records.
  - Record gaps: no aiur hourly logs 08-12 → 08-20 and 08-23 18:30Z → 09-10 19:33Z (18 days).
    `findings.ndjson` has records on only 8 days in 55 (aiur: none after 08-21). Retros after
    08-21 contain only failed visual checks, no bottleneck text.
  - 09-01: "I handled roughly 15 monitor events and called observe only twice."
  - 09-10: archon drain cadence "slipped to hourly during a quiet fleet"; poll design gave
    10–19 min discovery lag.
  - 09-11: the CI waiter filtered for a check named "ci" and never fired.
  - 09-24: a 45-second monitor burned the GraphQL budget.
  - 09-17 02:19Z → 09-26 15:00Z: no hourly retros for 9 days. Causes, per the Executor: the
    10-minute self-poll prompt had five steps and no retro; compaction truncated the
    `aiur-run` skill before the "Hourly monitoring retrospective — required" section; the
    action log was mistaken for a retrospective; `findings --unfiled` was never run.
- **Fixes claimed and recurrence:** the hourly retro rule (skill, 07-13); #2412 (08-23);
  #2264 (standing items need evidence, 08-22); #2594/#2596 (retrospective capture, 09-0x);
  the e09 corrective actions (09-26). The skill grew from 5 KB (06-23) to 73 KB (09-26), and
  the size is the reason given for the compaction cut. An aiur finding on 08-12 already said:
  "the step is buried mid-skill and the skill is too large to scan." It has no ticket and is
  still `open` in `aiur/meta/findings.ndjson`.
- **Quotes:**
  - "The recurring prompt I wrote had no retro step. … Every tick re-anchored me to that
    checklist, so the omission repeated about every 10 minutes for the whole run."
    (`khala/meta/retros/20260926T1500Z-e09-executor.md`)
  - "my CI waiter never fired because it filtered for a check named "ci" — aiur has no single
    "ci" check" (`aiur/meta/20260911T023131Z-quickfix-backlog-cleared-archon-code-complete.md`)

### Rank 11 — A5. The Executor misdiagnoses and carries stale claims

**Definition.** The Executor reaches a confident conclusion from the wrong vantage (wrong
credential, window, process or file), or inherits a claim and repeats it without re-checking,
and the stall lasts until someone disproves it.

- **Citations:** ~40 (23 self-retractions in the 08-21/22 logs alone). **Span:** 2026-08-10 →
  2026-09-26. **Repos:** aiur, archon, khala, architecture-docs.
- **Stated cost:** 08-21: about 19 h of near-zero fleet output, lengthened by 5–9 wrong
  hypotheses argued "from **outside that process**"; "webhook ingress was never enabled" was
  carried in about 22 logs over about 25 h, and it was false (the Executor's own count was
  "five"); #2139 blamed for a 5 h dispatch stop that a 64 KiB cap caused; 09-03: four root
  causes for one dispatch freeze in one day, and three false configuration alarms between
  Executors; 09-16: a Build Order topology error filed as Aiur defect #2659 (~7.5 h of peer
  effort); 09-20 and 09-26: the same wrong "stale cache" guess and restart, twice.
- **Fix and recurrence:** #2264 (standing items must carry evidence and a disproving command)
  caught two stale items the hour it merged (08-22 15:30Z). Stale standing items recur on
  09-02 ("largely stale after a week of dormancy") and 09-26.
- **Quotes:**
  - "One message asking the agent to report its own `env` settled it in a single round."
    (`aiur/meta/20260821T141500Z-token-present-identity-mismatch.md`)
  - "The previous handoff's ADDENDUM concluded the fleet could not dispatch because the
    `ci-readiness.json` was missing (#2139). **That was wrong.**" (`aiur/executor/handoffs/20260818T052353Z-handoff.md`)

### Rank 12 — A6. Context is lost across handoffs and compaction

**Definition.** The next Executor starts without the goal, the authority, the open items or
the rules, because handoffs are append-only logs with stale tops, invented timestamps and
dropped items, or because compaction cut the skill.

- **Citations:** ~56. **Span:** 2026-08-03 → 2026-09-26. **Repos:** all five, and a private
  repo whose handoff was never written.
- **Evidence:** the 0821 handoff (written by a different model) lost the standing goal and merge
  authority; the 0818-05Z handoff called a paraphrase "verbatim"; ~20 standing items dropped
  without resolution between 08-11 and 09-03 (docs audit #2108, npm promotion, #2110, #2138,
  #2131, #2200, the mise pin #2488, and others); archon's handoff header stayed 24 h stale while
  its top said a merged PR was "in active rework"; the khala 09-18 handoff changed 0 lines in 57
  versions and its session log used invented, evenly spaced times that hid a 19.6 h gap;
  handoffs grew to 74 KB (aiur), 85 KB and 55 KB (khala); `agent.priority` had 5 different
  "restore to" values across 8 handoffs; a local timeline-cap patch was lost at an upgrade and
  the same fault was diagnosed again 6 days later; compaction truncated the `aiur-run` skill.
- **Quotes:**
  - "That document's standing items were largely stale after a week of dormancy — re-verify
    anything you carry forward from it." (`aiur/executor/handoffs/20260902T035500Z-handoff.md`)
  - "A directive that lives only in a chat transcript dies when context rolls over"
    (`its-everdred/kevinweaver-dev/executor/handoff.md`)

### Rank 13 — B3. Paused or dead agents hold capacity; locks and build gates leak

**Definition.** Concurrency slots, workspace host locks or build-gate slots stay held after
the work that took them has stopped.

- **Citations:** ~46 (slot and lock leaks ~28, build-gate leaks ~18). **Span:** 2026-08-09 →
  2026-09-26. **Repos:** aiur, archon, khala.
- **Stated cost:** 17 paused agents held 17 of 22 slots (08-09); dead slots grew 4 → 8 of 12
  and forced a restart (08-22); "between hourly checks the fleet spends most of its time with
  no build capacity" (08-23); khala #12/#13 stranded ≥19 h 43 m by a same-daemon host lock
  (09-16/17); 16 of 20 slots held by provider-limited pauses (09-26).
- **Fixes and recurrence:** #1640/#1598 → #2227/PR #2269 → #2329 (mitigated with
  `max_agent_duration_minutes: 150`, not fixed) → #2793 → #2811/#2812. Build gate: #2349 →
  PR #2351 wedged within 3 h → #2381 → PR #2386 "became the bottleneck" → #2398/PR #2401.
  Host lock #2662 → PR #2666 is preventive only; old locks were not migrated, and worker 17
  hit it again before the merge.
- **Quote:** "**every agent that works past 60 minutes permanently removes a slot**, and the
  more productive the agent, the more certain it is to leak."
  (`aiur/meta/20260822T204500Z-slot-leak-doubled-and-forced-a-restart.md`)

### Rank 14 — B4. Stale dependency holds keep dependents blocked

**Definition.** A dependent ticket stays held after its blocker closes, because the
`blocked_by` data is cached.

- **Citations:** ~24. **Span:** 2026-08-09 → 2026-09-19. **Repos:** aiur, archon, khala,
  architecture-docs.
- **Stated cost:** 13 agents ~15 h on 08-08/09 (#1650/#1651); on archon, an RPC cache-drop by
  hand at every wave (about 9 min × 4 lanes per wave), with the recipe changed 3 times in 23 h;
  a cache clear on architecture-docs caused a double dispatch.
- **Fixes and recurrence:** #1650/#1651 → #2546 → #2550 (workaround) → #2551 → #2553/#2566 →
  #2710 → #104 and #105 held again on 09-19 ("Pattern persists despite aiur#2710").
- **Quote:** "Parking #199/#205 as `agent:in-progress` caused the daemon to DISPATCH duplicate
  workers (a label with no live worker reads as \"should be running\")."
  (`archon/executor/handoff.md`)

### Rank 15 — E1. Host saturation, several daemons on one host, and shared releases

**Definition.** Several daemons, the Executor's background agents and builds share one host
and one dev release, so load, memory, disk quota, name-matched kills and rebuilds of the shared
release interfere across runs; agents and git operations also damage operator files.

- **Citations:** ~107 (host resources ~60, config and checkout damage ~47). **Span:**
  2026-08-03 → 2026-09-26. **Repos:** all five, and a private repo (overlapping daemons).
- **Stated cost:** load 84 from four Executor background agents starved the fleet to 0/16
  (09-03); load 45 against a threshold of 24 halted dispatch (08-22); a `pkill` killed two
  daemons (09-03); OOM on archon (09-10); `/tmp` quota failures (09-17, 09-26); `executor-wait`
  rebuilt the shared release under a live foreign daemon (09-16, #2656, still unfixed);
  `.aiur/config` damaged by `reset --hard` (08-17) and destroyed by a review agent (08-23); the
  live checkout still has stray files and a modified config on 09-26.
- **Fixes and recurrence:** #2049 (destructive-git guard) bypassed on 08-23 (#2094: the guard
  only covers fleet workspaces); #2362 → PR #2377 (worktree collision; the skill mitigation
  caused the third occurrence); #2141/#2144 (git wrapper fork bomb, came back twice).
- **Quote:** "Four concurrent agents took this box to load 84 and starved the fleet to 0/16."
  (`aiur/executor/handoffs/20260903T053500Z-handoff.md`)

### Rank 16 — E2. GitHub API budget exhaustion

- **Definition:** polling, retries and caches that do not hit exhaust the REST or GraphQL
  budget and stall the fleet.
- **Citations:** ~76, concentrated 2026-08-02 → 2026-08-23; minor after (09-18, 09-24).
  **Repos:** aiur, kevinweaver-dev, khala, archon.
- **Stated cost:** 8 outages on 08-02; core 0/5000 on 08-11; the 08-21 GraphQL crisis (fixed
  60× by #2266/#2270); "A 3.5-minute outage cost roughly 11 agent-hours" (08-21); a guard that
  counted free 304 responses stalled the fleet (08-22); the read cache served 0 % for a day.
- **Fixes:** #1475, #1770, #2064, #2073/#2113, #2215, #2245/#2266/#2270, #2278/#2284,
  #2307/#2318, #2321, #2359 (the one verified token win), #2372/#2385, #2714/#2720. The class
  faded after 08-23 ("not a concern" on 09-02), except for the Executor's own monitor on 09-24.

### Rank 17 — E3. Credentials, identity and the authorship trap

- **Definition:** agents lack a working credential, or the Executor authors a PR it cannot
  merge because the reviewer and the author are the same identity.
- **Citations:** ~65. **Span:** 2026-08-02 → 2026-09-26. **Repos:** all five.
- **Stated cost:** "no agent can push" for most of 08-21; agent-token file deleted 88 times in
  30 min (#2478, 09-02); Executor-authored PRs stuck: #1849, #2046, #2144, #2180 (≥13 days);
  08-23 "I hit the authorship trap I warn about"; #2685/#2687 authored by the Executor
  identity again on 09-17; khala bot Read-only (09-16); a Codex 401 put 18 tickets in
  `agent:error` (09-25).
- **Fixes:** #2228/#2229/#2238/#2242 (08-21), #2478 (09-02), #2673 (open). The authorship trap
  is a standing warning in every aiur handoff from 08-11 to 09-03 and still recurs.

### Rank 18 — D4. Verification gaps: green checks that prove nothing

- **Definition:** tests, CI or the visual check pass while the behavior is not there.
- **Citations:** ~100. **Span:** 2026-08-02 → 2026-09-26. **Repos:** all five.
- **Evidence:** 21 of 31 visual-check verdicts could not inspect the pages; "Dashboard content
  UNVERIFIED" for 9 → 24 h (08-23); the same three visual-check failures again on 09-09/10;
  Chromium crashes for ≥10 h (09-17); 4 PRs whose tests pass with the production change
  reverted (09-16/17); khala's Claude and OpenCode delivery routes were never wired in
  production while CI was green (#418, #430, 09-26); three token-saving PRs measured zero.
- **Fixes and recurrence:** #2203 → #2304 → #2361/PR #2367 → #2594 → still failing 09-17.

### Rank 19 — A7. The Executor does fleet work, and its own load hurts the fleet

- **Definition:** the Executor implements, re-integrates or re-proves work itself, or runs
  background agents outside the load governor, while the fleet waits.
- **Citations:** ~77 (self-inflicted problems). **Span:** 2026-08-02 → 2026-09-26.
- **Evidence:** ~36 re-integrations and ~120 mutation re-runs by the Executor, with 7 Executor
  commits on agent PRs (09-16/17); the Executor implemented #2680–#2687 while no fleet worker
  ran for ~18.7 h (09-17) until the user said "many independent defects may use native Aiur
  agents"; khala switched to the Executor's own agents while the fleet was globally paused
  (09-17); a subagent lifetime ceiling (200/200) serialized review (08-23); ≥17 hand merges and
  fixes on khala agent PRs (09-18 → 09-26).
- **Quote:** "The bottleneck is me" (`aiur/meta/20260822T223000Z-i-am-the-uncontrolled-load.md`).

### Rank 20 — B5. Agents stall, time out, or stop before the work is done

- **Definition:** agents hit a duration limit, hang on a shell hazard, end their turn while
  waiting for CI, or become zombies.
- **Citations:** ~47. **Span:** 2026-08-02 → 2026-09-26.
- **Evidence:** 9 drafts hit `max_agent_duration` with finished code (08-18); `cd`/zoxide and
  `ls`/eza hangs in 9 wrappers and in a review agent (09-10), known since 08-03 (#1468); agents
  that "cannot wait for CI" and park in `agent:ci-wait` (09-25, 09-26); work with no PR for
  ~8 h (08-10); a validate run hung 2.5 h (09-26). The Executor usually found these late
  (64 min, 2 h, 85 min).

### Rank 21 — A8. Coordination between Executors

- **Definition:** two or more Executors on one host or one run coordinate by mail and
  disagree about shared state.
- **Citations:** ~17. **Span:** 2026-09-03 → 2026-09-26. **Repos:** aiur, architecture-docs,
  archon, khala.
- **Evidence:** three false configuration alarms between the architecture-docs and aiur
  Executors, "each one has cost an investigation" (09-03); a crash cause that flipped three
  times; ~8 h to the first peer reply (09-16/17); khala #12 recovery serialized behind a peer
  checkpoint for ≥12 h; a dual Executor on archon posted a review its successor withdrew.

---

## The operator's hypothesis, tested

> "The Executor frequently loses focus as agents put up pull requests or begin to time out,
> and there are frequent gaps in time where no progress is being made by either the Executor
> or the agents."

### Gap register

These are the dated stalls that the records state, with one primary mechanism each.
Mechanisms: **M1** serial review lane (Executor present, queue grows); **M2** discovery path
down (inbox not consumed, monitor lapsed, watcher or waiter scoped wrong); **M3** Executor not
running (quota, crash, host, pause nobody noticed); **M4** attention captured by other work
(spike, CI watching, doing agent work, own load); **M5** human or authority gate; **M6** silent
daemon strand behind healthy surfaces; **M7** misdiagnosis or stale claim; **M8** operator's
deliberate choice.

| # | When (UTC) | Length | What stalled | Mech. | Source |
|---|---|---|---|---|---|
| 1 | before 08-03 (an earlier aiur run) | 229 min | waiting on a permission that was never required | M5 | kevinweaver-dev handoff |
| 2 | 08-08 23:00 → 08-09 14:18 | ~15 h | 13 agents on an unclosed blocker; metas ran | M6 | aiur/meta 2026-08-09T1300Z |
| 3 | 08-09 | hours; meta gap 6 h 49 m | research spike; PR queue 22 → 30; timer not armed | M4 | aiur/meta 2026-08-09T0000Z |
| 4 | 08-09 | "for hours" | 2 of 14 active; decisions sent as comments | M5 | aiur/meta 2026-08-09T2100Z |
| 5 | 08-09 night | overnight | fleet 15 → 1 (label cache) | M6 | aiur/meta 2026-08-09T2345Z |
| 6 | 08-10 | 8 h | approved PR not queued; Executor thought it merged | M6 | aiur/meta 2026-08-10T0930Z |
| 7 | 08-10 | ~1 h (70.1 idle slot-hours shown) | wrong bottleneck named while fleet 93 % idle | M7 | aiur/meta 2026-08-10T1145Z |
| 8 | 08-10 | 6–7 h | merged fix inert awaiting restart permission | M5 | aiur/meta 2026-08-10T1345Z…1830Z |
| 9 | 08-17 → 08-18 | ~22 h | 5 PRs "unreviewed all run" | M1 | aiur handoffs 0817, 0818 |
| 10 | 08-18 | unknown | hourly check not serviced; dashboard down unnoticed | M4 | aiur handoff 20260818T001943Z |
| 11 | 08-18 | ~5 h | no dispatch (64 KiB cap), misdiagnosed | M6 | aiur handoff 20260818T052353Z |
| 12 | 08-18 → 08-23 | 5 days | wake cursor at 1; 2,832 records | M2 | aiur/meta 20260823T183000Z |
| 13 | 08-20 | up to ~1 day | 17 reworked PRs unreviewed | M1 | `aiur-run` SKILL.md |
| 14 | 08-21 | ~19 h | near-zero output; 5–9 wrong hypotheses | M7 | aiur/meta 20260821T* |
| 15 | 08-21 | 4 h 48 m | pause held for one alerting PR ("over-literal") | M7 | aiur/meta 20260821T091500Z |
| 16 | 08-21 10:15 | ~1 h × 11 agents | idle on a hold that had cleared | M6 | aiur/meta 20260821T101500Z |
| 17 | 08-22 15:30 | — | review starved fleet: todo empty, 1 agent working | M1 | aiur/meta 20260822T153000Z |
| 18 | 08-22 | ≤5 h | 11 reworked PRs unseen | M1 | aiur/meta 20260822T223000Z |
| 19 | 08-22 | — | Executor's 8 reviewers pushed load to 45; dispatch halted | M4 | aiur/meta 20260822T223000Z |
| 20 | 08-23 08:30 → 11:25 | ~3 h | merges flat; 9 green PRs waiting on the Executor | M1 | aiur/meta 20260823T112500Z |
| 21 | 08-23 | hours | 10 tickets in `agent:error`; pool not examined | M6 | aiur/meta 20260823T122000Z |
| 22 | 08-23 → 09-03 | 11 days | cursor frozen at 2832; ~1,476 unconsumed | M2 | aiur handoffs 0902, 0903 |
| 23 | 08-25 → 09-02 | ~8 days | global pause on; fleet 0/16; nobody noticed | M3 | aiur handoff 20260902T035500Z |
| 24 | 09-03 | ~8.5 h | aiur Executor died in API 529s; no successor | M3 | arch-docs handoff 20260903T154905Z |
| 25 | 09-03 | 9–12 h | arch-docs dispatch frozen (1 MiB cap) | M6 | arch-docs handoffs |
| 26 | 09-03 | — | Executor background agents: load 84, fleet 0/16 | M4 | aiur handoff 20260903T053500Z |
| 27 | 09-03 22:50 → run end (09-05) | ~1.1 days | arch-docs cursor frozen; 1,529 wakes never consumed | M2 | wake files; arch-docs handoff |
| 28 | 09-03 → 09-16 | 13.5 days | aiur cursor 4329 idle; 198 pending | M2 | aiur handoff 20260916T184046Z |
| 29 | 09-10 04:55 → 07:28 | 2 h 33 m | account limit; fleet and Executor down | M3 | archon/meta 20260910T073040Z |
| 30 | 09-10 | 85 min | delegated reviewer silent, unnoticed | M4 | archon/meta 20260910T142948Z |
| 31 | 09-10 → 09-11 | ≥23 h | rebuild request unanswered; fixes inert | M5 | archon handoffs |
| 32 | 09-10 17:35 → 09-11 03:33 | ~10 h | "manual mode"; PENDING 0 → 233 | M2 | archon/meta r15–r21 |
| 33 | 09-11 | hours | 7 green PRs unnoticed (waiter filtered "ci") | M2 | aiur/meta 20260911T023131Z |
| 34 | 09-16 19:47 → 09-17 15:18 | ≥19.5 h | khala 0 working; bot Write gate | M5 | khala retro, handoff previous |
| 35 | 09-16 22:10 → 09-17 02:19 | ~4 h 06 m | both Executors stopped at once | M3 | aiur resume retro; khala handoff |
| 36 | 09-17 02:27 → 15:12 | 12.75 h | no aiur merges; approved PRs abandoned; Executor implements | M4 | aiur evidence; handoff.md |
| 37 | 09-17 02:56 → 09-20 | ~3.7 days | aiur wakes never consumed (66); lease renewed | M2 | wake files |
| 38 | 09-17 → 09-26 | 9 days | no hourly retros | M2* | e09 retro |
| 39 | 09-18 04:47 → 08:22 | 3.6 h | Claude limit; 6 rework tickets to `agent:error` | M3 | khala handoff 09-18 |
| 40 | 09-18 04:04–04:16 | — | rework on 3 PRs missed (watcher scope) | M2 | khala handoff 09-18 |
| 41 | 09-18 12:15 → 20:58 | 8.7 h | no merges; cause unstated | M3? | S7 (git + wakes) |
| 42 | 09-18 22:22 → 09-19 17:56 | 19.6 h | no merges; #117–#119 ready; hidden by invented times | M3? | S7 (git + wakes) |
| 43 | 09-20 | 3.1 h | #42 silent timeline-cap starvation | M6 | khala handoff 09-20 |
| 44 | 09-18 → 09-24 | 6 days | cursor stuck at 517; 262 pending | M2 | khala handoff.md |
| 45 | 09-20 03:33 → 09-24 19:05 | 111.5 h | goal ended by the operator | M8 | khala handoff 09-20 |
| 46 | 09-25 00:23 | ~45 min | fleet 0/12; rework not triggered | M6 | khala handoff.md |
| 47 | 09-25 00:52 → 01:57 | ≥64 min | #165 stranded in ci-wait; 8 of 12 slots idle | M6 | khala evidence ci-wait-165 |
| 48 | 09-25 08:28 → 22:02 | 13.6 h | monitors expired; 8 PRs in human-review; Codex limit | M2 | khala handoff.md |
| 49 | 09-26 01:57 → 03:45; 07:06 → 08:57 | 1.8 h + 1.9 h | Claude limits (Executor and fleet) | M3 | khala handoff.md |
| 50 | 09-26 | 2 h; 2.5 h | #367 in ci-wait with green CI; hung validate run | M6 | khala handoff.md |

\* Row 38 is a record-keeping gap (the loop omitted the retro step), not a work stall.

**Tally of primary mechanisms (50 gaps):** M2 discovery path down 11 (one is the retro gap);
M6 silent strand 11; M3 Executor not running 8 (2 with no stated cause); M4 attention
captured 6; M1 serial review lane 5; M5 gate 5; M7 misdiagnosis 3; M8 operator choice 1. The length of the gap is not
related to the mechanism in any simple way. The longest gaps (days) are M2 and M3: nobody is
consuming events, or nobody is running.

### Where the evidence supports the hypothesis

1. **Gaps are frequent and long.** 50 dated gaps in 55 days of records; 23 of them (not
   counting the operator's choice and the retro gap) are longer than 5 hours. The records state no-progress windows of 12.75 h, 13.6 h, 19.6 h and several days.
2. **Pull requests are where the Executor's attention fails first.** The operator's picture is
   correct in one precise way: *re-review after rework* is the step that is lost. First reviews
   happen; the `ticket.branch.push` that means "rework is ready" does not wake anyone, and review
   is treated as one pass (rows 9, 13, 17, 18, 20, 40, 48). The Executor says so itself: "every
   rework waits on me noticing" (`aiur/meta/20260823T132000Z`).
3. **The Executor attends to one thing while others starve.** A research spike (row 3), CI
   watching instead of the hourly check (row 10), diagnosing Aiur defects, re-integrating and
   re-proving PRs by hand (row 36), implementing tickets itself (row 36), and mail with a peer
   Executor. On 08-23 it blamed red main and the build gate for a stall that was its own review
   queue: "This is the second time this run I have attributed my own bottleneck to an
   external cause."
4. **Timeouts are found late.** Agents that end their turn at `agent:ci-wait`, hit
   `max_agent_duration`, or hang on a shell hazard are found 64 min to 2 h later, usually by
   the hourly check or by chance (rows 46, 47, 50; archon's reviewer at 85 min).
5. **Every instance the operator named is confirmed and has repeats:** the 2,832-record inbox
   (08-18 → 08-23), then four more aiur episodes and one in each other repo; the truncated skill
   and 9 days with no retros (09-17 → 09-26); 17 reworked PRs unreviewed up to a day (08-20),
   repeated as 11 PRs up to 5 h (08-22) and 8 PRs for 13.6 h (09-25); the hourly check as the
   primary loop (08-20, and again as "manual mode" on archon 09-10/11); the self-poll prompt
   with no retro step (09-17 → 09-26), preceded by a timer written into the skill and never
   armed (08-09) and an hourly check armed and not serviced (08-18).

### Where the evidence contradicts or refines it

1. **When the event loop runs and quota lasts, the Executor is fast.** Archon on 09-10: push →
   wake 18 s, review → label 35 s, approve 68 s, ready → merge 4–20 min; 12 consolidation PRs in
   8.5 h. The 08-02 dual-builds run turned 35 of 37 wakes into actions and ran every hourly
   retro on time. On 08-23 the Executor fanned out 4–6 reviewers an hour and merged 66 PRs; on
   09-26 khala merged about 40. Focus is not the default failure; losing the trigger is.
2. **Many long gaps have no Executor at all (M3).** Shared provider quota stops the fleet and
   the Executor together; a session dies in API errors; both Executors on the host stopped at
   the same minute on 09-16. Nothing in Aiur notices a missing Executor, and nothing replaces
   it.
3. **Many stalls are daemon defects that the Executor could not see (M6).** Silent size caps,
   labels that nothing polls, stale caches and slot leaks all showed "healthy". The Executor
   was often present and checking hourly while these ran.
4. **Many are human gates (M5).** The Executor had the answer and was not allowed to record it
   (the authority floor), or the human was away. 15–16 days for two green PRs is the operator's
   latency, not the Executor's.
5. **Some idle time was chosen.** The operator ended the khala goal for 111 h, asked for a
   few-defects scope on 09-17, and set "report rather than restart" on 08-10.

### Mechanisms of loss of focus

| Mechanism | What happens | Evidence (count of gap rows) | What would remove it |
|---|---|---|---|
| Discovery depends on the session | Tail and Monitor die with the session or after 30 min; the durable cursor is not consumed; noise buries the backlog | 11 rows; 8 inbox episodes | a daemon-owned loop that wakes the Executor and escalates an unconsumed backlog |
| One serial reviewer with a one-pass habit | Rework pushes are not a wake; re-integration of every PR on every merge | 5 rows; queue peaks of 19–40 PRs (08-08, 08-09, 08-22) | re-review wakes from rework pushes; parallel scoped re-review; merge queue |
| Executor absence is invisible | Quota, crash, host, rotation, pause | 8 rows | a heartbeat on the Executor with a successor or an alert |
| Self-authored loops drift from the skill | Self-poll prompt omits the retro; waiter filters "ci"; watcher scoped to old PRs; compaction truncates a 73 KB skill | e09 retro; rows 33, 38, 40 | the loop steps in code (a checklist the daemon enforces), not in prose |
| Attention capture by deep work | Spikes, diagnosing Aiur defects, doing agent work, peer mail | 6 rows | move toil to the daemon; a work-in-progress limit for the Executor |
| Surfaces report health while stuck | Stalls invisible until a human looks | 11 rows | alerts on "no progress for N minutes" per ticket and per fleet |
| Gates without escalation | "do not re-prompt"; reminders every 15 min | 5 rows | one escalation per gate with an age, not per-worker reminders |

### Refined statement

A more accurate form of the hypothesis: *Aiur has no mechanism that keeps the Executor's loop
running. Discovery, re-review, recovery and escalation all depend on the Executor noticing, in a
session that can stop, with a prompt it wrote itself, reading surfaces that report health while
tickets are stranded. The largest idle windows happen when that loop is absent (no consumer, no
Executor, or no human for a gate), not when an attentive Executor drifts.*

---

## Fixes that did not hold

The corpus has a clear pattern: an incident leads to a prose rule in the `aiur-run` skill or a
narrow code fix, and the class recurs in a slightly different form. The `aiur-run` skill grew
from 5.3 KB (2026-06-23) to 73.4 KB (2026-09-26) over 50 commits, much of it incident lessons.

| Class | Fix chain (issue → PR) | Recurred after the last shipped fix? |
|---|---|---|
| Rework strand (Rank 5) | #1389/#1427 → #1756/#1758 → #2065 → #2337 → #2422 → #2473/#2477 → #2601/#2620 → #2798 → #2801/#2804 → #2815 → #2817 | Yes, ≥5 times on 09-26 |
| Discovery path (Rank 4) | skill 07-13 → #2412 → #2472/#2481 → #2600/#2619 → #2592/#2622 → #2661/#2664 → #2707 → #2606/#2715 | Yes: 09-17, 09-20, 09-24, 09-25 |
| Silent size caps (Rank 1) | #1454 (64 KiB) → #2533/#2535 (1 MiB) → #2749 → #2816 (timeline) | Same shape three times; not seen after #2816 |
| Labels and ci-wait (Rank 1) | #2075 → #2172 → #2420/#2437/#2426 → #2366 → #2767 → #2817–#2819 | Yes, 09-26 |
| Stale dependency hold (Rank 14) | #1650/#1651 → #2546 → #2550/#2551 → #2553/#2566 → #2710 | Yes, 09-19 |
| Slot leaks (Rank 13) | #1640/#1598 → #2227/#2269 → #2329 → #2793 → #2811/#2812 | Yes, 09-26 (16 of 20 slots) |
| Build gate (Rank 13) | #2349/#2351 → #2381/#2386 → #2398/#2401 | Each fix "became the bottleneck" |
| Host lock (Rank 13) | #2662 → #2666 | Preventive only; worker 17 recurred |
| Authority floor (Rank 2) | #2224 → #2275 → #2301 → #2440 | Yes, 09-18 |
| Decision delivery (Rank 2) | #2074 → #2730 → #2738 | Yes, same evening |
| Provider limit (Rank 6) | #2607 → #2627 → #2727/#2729 → #2742 → #2811/#2812 | Partly; hand-resumes 09-26 |
| Visual check (Rank 18) | #2203 → #2304 → #2361/#2367 → #2594 | Yes, 09-17 |
| CLI status timeouts (Rank 9) | #1614 → #1720 → #1816 → #1837 | Yes, four causes |
| CI flakes (Rank 8) | #1591 … #2247/#2285 → #2343/#2348 → #2373/#2383 → #2397/#2405 → #2555 → #2474/#2688 → #2691 → #2740 | Yes, each family replaced |
| Destructive git (Rank 15) | #2049 → #2094; #2362 → #2377 | Yes, 08-23 |
| Hourly retros (Rank 10) | skill 07-13 → timer rule 08-09 → #2412 → #2594/#2596 → e09 actions 09-26 | Yes, 9 days (09-17 → 09-26) |

## Corrections recorded in the corpus (highest-value lines)

These are places where a later document says an earlier claim was wrong.

| Date | Correction | Source |
|---|---|---|
| 08-09 | wrote "arm a one-hour timer" into the skill and never armed one | aiur/meta 2026-08-09T0000Z |
| 08-10 | "I have been naming the wrong bottleneck for the last hour" | aiur/meta 2026-08-10T1145Z |
| 08-18 | the ci-readiness diagnosis of the dispatch stop "was wrong" (64 KiB cap) | aiur handoff 20260818T052353Z |
| 08-22 | "webhook ingress never enabled" was false after ~22 logs / ~25 h | aiur/meta 20260822T062000Z, 153000Z; `aiur-run` skill |
| 08-22 | "two standing items were stale" | aiur/meta 20260822T153000Z |
| 08-23 | "red `main` is not what froze the merges. I was." | aiur/meta 20260823T112500Z |
| 08-23 | "a corrected overcount" | aiur/meta 20260823T170000Z |
| 09-02 | section 4 was "twice wrong": a mise release, not flakes | aiur handoff 20260902T043000Z |
| 09-02 | previous standing items "largely stale after a week of dormancy" | aiur handoff 20260902T035500Z |
| 09-03 | four root causes for one dispatch freeze; crash cause flipped three times; three false config alarms | arch-docs handoffs; reply-from-aiur-executor.md |
| 09-10 | the unblock recipe changed three times in 23 h; "the rebuild retires it" was contradicted later | archon handoffs |
| 09-16 | Build Order topology was the Executor's error, not Aiur defect #2659 | khala handoff previous |
| 09-16 | the peer's "untouched release" claim was wrong: `executor-wait` rebuilt it (#2656) | khala handoff previous |
| 09-17 | "49 old reminders drained earlier are not 49 historical audits" | khala handoff previous |
| 09-18 | a "Codex limited until …" standing item was stale by 7–11 h | khala handoff 09-18 |
| 09-26 | "My hand-resume was unnecessary"; "Manual rework relabels should no longer be needed" falsified 3.8 h later | khala handoff.md |
| 09-26 | the whole "why the Executor missed the hourly retrospective" section | khala e09 retro |

## The records themselves are a recurring problem

- **Timestamps.** The 08-09/10 aiur meta file names run up to ~7 h ahead of the real write
  times. The khala 09-18 handoff's section times ran up to 2 h 14 m ahead, and its session log
  used invented, evenly spaced times. Use file mtimes, wake `first_seen_at` and git merge times
  for timing work, not handoff headings.
- **Coverage.** aiur hourly logs exist only for 08-08 → 08-11, 08-21 → 08-23, and one each on
  09-10 and 09-11. The findings ledgers have records on 8 days out of 55. Retros between 08-21
  and 09-16 contain only visual-check output.
- **Format.** Handoffs are append-only: 74 KB (aiur), 85 KB and 55 KB (khala), 33 KB (archon),
  with stale tops. Codex-written handoffs drop the spaces between words. One private repo's
  handoff was never written.

## Leads for the other research lanes

- **Gaps/timing lane:** the no-merge gaps on khala (09-18 12:15 → 20:58 and 22:22 → 09-19
  17:56) have no stated cause. The simultaneous stop of both Executors on 09-16 22:10 →
  09-17 02:19 has an inferred link to two SSH logins at 02:17:45Z and 02:17:54Z (khala
  `evidence/current-lock-proof-20260917T0244Z.md`); check the session logs.
- **Census lane:** unconsumed wakes now: architecture-docs 1,529, archon 264, aiur 66, khala 0,
  and one private repo 55. Owner leases kept renewing after the last ack (archon 36 h, aiur to
  09-22).
- **Fixes lane:** the chains above; verify #2817–#2819 and whether #2815 is in the running
  khala build; the two re-fixed bugs (#2641 → #2684/#2685, #2667 → #2697/#2701); the
  config mitigations marked "restore once fixed" (`daemon_core_limit_per_hour: 12000`,
  `agent_core_limit_per_hour: 3000`, `max_agent_duration_minutes: 150`, `prewarm.enabled: false`).
- **Codebase lane:** `waiting_for_human` reminders re-fire every 15 min per paused worker with no
  deduplication; `capacity_starved` is flagged `needs_attention`; `agent:ci-wait` has no route
  back to dispatch (`:no_agent_work_state`); lease renewal masks a dead wake consumer; the
  `reviewDecision` re-derivation that reverts `agent:human-review`; hard byte caps in fetch
  paths that fail silently; `scripts/aiurdev` rebuilding under `executor-wait` (#2656).
- **Hygiene note:** some other lanes' scratch files under `../scratch/` contain private-repo
  data (for example `scratch/gaps/gh/` has a private repo's issue comments). My lane's files do
  not. Check before committing the scratch directory.
