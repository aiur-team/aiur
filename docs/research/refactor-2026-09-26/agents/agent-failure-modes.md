# Agent failure and waste modes, from the agents' own session logs

Research input for the 2026-09 Aiur refactor. Scope: what **agents** (Claude Code and Codex
workers dispatched onto tickets) get stuck on, how often, what it costs, and which modes make
the **Executor** step in. Executor meta logs, idle-gap timing, merged fixes and the codebase are
covered by sibling reports.

Privacy rule applied: sessions from the two private repositories are **counted** in every
total below, but nothing from them is quoted or cited (no paths, ticket numbers or text).
All evidence quotes come from `aiur`, `archon`, `khala`, `architecture-docs` and
`kevinweaver-dev`. Secrets were redacted at extraction time; one quoted API-key error is shown
with the key replaced by `<REDACTED>`.

---

## 1. Headline

- **56.5% of all agent turns do nothing.** 12,768 of 22,613 turns are "continuation" turns
  in which the agent makes 0–1 tool calls and ends the turn. 94% of them take under 60 s.
  The agent is waiting — on a dependency (28%), CI (28%), human review (14%) or an Executor
  decision (6%) — and the daemon keeps re-prompting it. On Codex alone these turns
  consumed about **2.5 billion tokens** (about 204k per turn, almost all cached input).
  The pattern is not historical: it was 52% of turns in ISO week 38 and 29% in week 39.
- **One no-op loop can take the whole Claude fleet offline.** On khala#230 (2026-09-26),
  267 turns in 41 minutes, each saying *"Nothing has changed since last turn. I'm still
  blocked on the Executor's answer…"*, added **$33.71** of metered cost and then hit the
  account session limit. Every Claude agent shares that limit.
- **When a provider limit is hit, the dispatcher keeps relaunching.** 189 Claude sessions
  (14.8% of all Claude sessions) died in under 4 s with *"You've hit your session limit"*
  or *"out of usage credits"*. architecture-docs#41 was relaunched **27 times in 92 minutes**
  against a limit that reset hours later.
- **The guard command in the agent prompt does not exist on the agents' PATH.**
  `aiur guard-pr-deletions` returned `aiur: unknown command` in **579 sessions (24%) on
  384 tickets**, from 2026-08-11 through today (2026-09-26). 408 of those sessions then
  spent tool calls searching for it. Separately, at least 1,052 guard invocations pipe it
  through `tail` or `head`, which hides its exit status.
- **Restarts and interrupts churn context.** There were about 256 Aiur restart waves.
  They produced 2,621 Codex "session resumed after an aiur restart" turns across 576
  threads (one thread resumed 41 times). 1,145 Codex turns were aborted mid-flight; together
  they had been running for 513 hours.
- **Most modes that need the Executor are waits the agent cannot resolve itself:** an
  unanswered decision, a stale `CHANGES_REQUESTED`, a paused worker (duration cap,
  `before_run` hook failure, usage limit), a workspace collision, or state divergence.

## 2. Method and sampling

Most of this is a **census**, not a sample. Every Aiur agent session was parsed by
purpose-built streaming extractors (read-only; scratch in
`~/.aiur/research/refactor-2026-09-26/scratch/failmodes/`).

| Source | Scope processed | How |
|---|---|---|
| Claude sessions `~/.claude/projects/*aiur-workspaces*` | all 297 ticket dirs, **1,653 files** = 1,278 primary + 375 subagent | `extract.py` (per-session features and signatures), `turns.py` (per-turn prompt kind, tools, duration, final message), `cmds.py` (every shell command), `outscan.py` (tool outputs only) |
| Codex sessions `~/.codex/sessions/**` | 6,534 files indexed by `cwd`. **5,909** are Aiur agents (cwd under `…/workspaces/<owner>/<repo>/<n>`): 1,164 primary threads + 4,745 subagent or forked threads | same extractors. Subagent and fork files (which replay parent history) are excluded from all rates, using the **first** `session_meta` only |
| Workspace transcripts `logs/agent.ndjson` | all **418** files (7.6 GB) under `~/.aiur/workspaces` and `~/code/aiur-workspaces` | `rg` census of the structured top-level `event` names (`turn_failed`, `startup_failed`, `worker_paused`, `alert`…), and of Codex `method:"error"` notifications |
| Daemon per-ticket logs `~/.aiur/logs/*/log/github-*.log` | inspected, **not used** | they are token-by-token agent output streams with no extra signal |

Targeted signatures were counted with `rg -c` over the 2,442 primary session files. The
patterns were built to match **runtime output strings**, not documentation. For example,
`aiur: unknown command: guard-pr-deletions` and `aiur: GitHub quota backoff; waiting Ns`
match output; the bare words "timeout" or "rate limit" would match docs too. Broad
patterns first gave inflated counts because agents read skill files and source that contain
the same strings. Those counts were discarded and re-measured (see §7).

Manual verification: about 40 sessions were read at the turn level, including the 12
fastest no-op streaks, the top retry tickets, and random draws. A random draw of 20
near-empty continuation turns was 20/20 genuine waits (§5.1).

## 3. Corpus shape

**Primary sessions: 2,442** (Claude 1,278; Codex 1,164) across **735 tickets**.

| Repo (primary sessions) | Claude | Codex |
|---|---:|---:|
| aiur | 165 | 936 |
| khala | 722 | 117 |
| architecture-docs | 219 | 36 |
| archon | 113 | 0 |
| kevinweaver-dev | 0 | 52 |
| private repos (counted only) | 59 | 23 |

A Claude session is one agent *run*: each wake-up (CI result, rework, restart) starts a new
file. A Codex primary file is one *thread*: Aiur resumes it across runs and restarts. The
two are therefore not directly comparable per session.

**Session wall-clock length (minutes)**

| | p10 | p50 | p75 | p90 | p99 | max | total |
|---|---:|---:|---:|---:|---:|---:|---:|
| Claude (run) | 0.0 | 4.6 | 14.1 | 30.7 | 147.5 | 610 | 280 h |
| Codex (thread) | 1.6 | 31.6 | 80.2 | 186 | 905 | 10,157 | 1,694 h |

**Turns per session:** Claude p50 2, p90 4, p99 13, max 320. Codex p50 3, p90 26, p99 290,
max 1,069 (a private-repo thread). There are 138 Codex threads with ≥20 turns and 50 with
≥100.

**Sessions per ticket** (retry smell): Claude p50 4, p75 6, p90 8, p99 13, max 29
(architecture-docs#41, which is almost entirely the limit retry storm in §5.2). Codex p50 1,
p90 4, max 11. Across both providers: p50 3, p90 7, p99 12, max 31. 16 tickets had ≥10
Claude sessions.

**How sessions end** (precedence as listed; primary sessions)

| Outcome | Sessions | % | Claude | Codex |
|---|---:|---:|---:|---:|
| No terminal action (turn(s) ended without PR, label handoff or pause) | 681 | 27.9 | 315 | 366 |
| PR opened in this session (`gh pr create` + PR URL in output) | 587 | 24.0 | 240 | 347 |
| Handed to `agent:human-review` / PR marked ready | 481 | 19.7 | 359 | 122 |
| Parked in `agent:ci-wait` | 225 | 9.2 | 137 | 88 |
| Paused / `decision.requested` / `pause.request` | 214 | 8.8 | 22 | 192 |
| Dead on arrival (provider limit or API error, 0 tool calls) | 189 | 7.7 | 189 | 0 |
| Ended on an interrupted turn | 49 | 2.0 | 0 | 49 |
| Ended on a usage-limit message | 16 | 0.7 | 16 | 0 |

At ticket level, **582 of 735 tickets (79%)** had a PR opened in at least one session.
Sessions cut off mid-work (the last event is a tool call or result, an aborted turn, or a
started turn with no completion): Claude 333/1,278 (26%), Codex 468/1,164 (40%).

**Turn mix** (22,613 turns; prompt kind is classified from the injected prompt)

| Prompt kind | Codex turns | Claude turns | Tools/turn | Notes |
|---|---:|---:|---:|---|
| `Continuation guidance: previous turn completed normally` | 13,544 | 688 | 1.2 / 3.7 | 7,446 Codex turns have **zero** tools |
| `session resumed after an aiur restart` | 2,621 | — | 13.7 | 1,183 are ≤1 tool |
| initial dispatch | 826 | 471 | 69.5 / 48.2 | |
| `this agent run continues prior work` | 3 | 425 | 20.0 | Claude re-dispatch |
| rework continuation | 279 | 361 | 41 / 36 | |
| `<aiur:events>` with `operator.progress_request` | 667+ | 339+ | 2.3 / 4.8 | 1,744 turns carry a check-in in total |
| `<aiur:events>` ci.passed / ci.failed / ci.rewake | 524 | 385 | | 302 are `ci.rewake` (fallback timer) |
| `<aiur:events>` issue.commented / pr.review_comment | 297 | 220 | | |
| Executor free-text messages | ~320 across 122 tickets | | | review follow-ups 102, decisions 43, rebase 28, hold 25, restart 19 |

## 4. Ranked taxonomy

Ranking weighs frequency, cost (turns, tokens, wall-clock, lost work) and whether the
Executor must act.

| # | Failure / waste mode | Frequency | Cost | Repos | Forces Executor? |
|---|---|---|---|---|---|
| 1 | **No-op continuation loop:** the agent is waiting, but the daemon keeps issuing continuation turns | 12,768 turns (56.5% of all); 1,364 streaks ≥3 turns, 712 ≥10, 31 ≥20; 207 sessions / 157 tickets | 186 h of turn time; about 2.5 B Codex tokens; khala#230: $33.71 in 41 min, then an account-wide session limit | all public; heaviest aiur (Codex), khala (Claude) | Indirect. The agent is waiting *for* the Executor (review, decision) or CI. The burned quota then causes mode 2, which does force action |
| 2 | **Provider usage/session limits and dispatch retry storms** | Claude: 189 dead-on-arrival sessions, 220 sessions ending on a limit, 50 tickets. Codex: 380 turns ended by `usage limit` (155 threads, 101 tickets; 260 turns on 08-10). Daemon: 186 `claude exited with code 1` turn failures (429 session limit), 42 workspaces. Codex `401 Incorrect API key`: 70 turns, 19 khala threads on 09-25 | Fleet-wide stop until reset; relaunch churn (architecture-docs#41: 27 launches in 92 min) | all | **Yes.** 55 `paused-usage_limit_exhausted` attentions (17 workspaces); resume or reroute the model |
| 3 | **Restart / interrupt / process-death churn** | about 256 restart waves; 2,621 Codex resume turns in 576 threads (p90 11, max 41 per thread); 1,145 aborted turns; daemon: `port_exit` 109 (80 ws), `startup_failed: port_closed` 68 (47 ws), `turn_interrupt_failed` 116 (77 ws), SIGTERM exit 143 ×19, `spawn … EAGAIN` ×3 | 513 h of in-flight turn time interrupted; 1,116 resume turns re-read the operating manual although told not to; 299 threads end on an aborted turn | all | The Executor *causes* most of it (restarts to load merged fixes). Some failures still need a manual resume (see 8) |
| 4 | **Blocked on an Executor answer:** unanswered decision, stale `CHANGES_REQUESTED`, re-review | `decision.requested` in 99 sessions (81 tickets); 670 `operator-decision` attentions (45 ws); 715 no-op turns name the pending decision; 66 rework sessions concluded "nothing to rework" (stale review); alerts `stale-review-verdict` 38, `stale-changes-requested` 22, `rework-loop` 14, `blocked-human-reapproval` 15 | Tickets idle until answered, and they loop (mode 1) meanwhile | all | **Yes, by definition** |
| 5 | **CLI version skew:** `aiur guard-pr-deletions` missing; guard exit status masked | 579 sessions (24% of primary), 384 tickets, 08-11 → 09-26; 408 sessions searched for it; fallbacks: repo script 331, manual `git diff --diff-filter=D` 141, libexec path 48; ≥1,052 invocations piped to `tail`/`head` and ≥157 followed by a push in the same command | 1–8 extra tool calls per affected session; the deletion guard is effectively advisory | all | No — agents work around it silently. It is tracked in aiur#1778 and still open |
| 6 | **GitHub API friction through the `gh` guard** | quota backoff waits 227 sessions (180 tickets); secondary-rate-limit backoff 681 events in 165 sessions, **≥399 of them right after an ordinary 4xx** (329 × HTTP 404, 45 × 400, 14 × 422, 10 × 401); writes to a read-only `github-quota/*.tmp` 94 sessions, arithmetic errors 20; `GraphQL: API rate limit already exceeded` 140 sessions (aiur); budget broker unavailable 102 sessions | ≥6.6 h of forced 60 s sleeps after client errors; PR creation blocked | all (the read-only hold file shows up in Codex sandboxes) | Sometimes: 42 `github-rate-limit` and 28 `github-budget-unwritable` attentions; 89 `system.github.connectivity_lost` |
| 7 | **Executor check-in wakeups** (`operator.progress_request`) | 1,744 turns on 528 tickets (p50 3, max 41 per ticket); 707 `progress.checkin` emits (Claude) | 12,073 tool calls; 140 h of turn time (mixed-event turns included); parked agents woken to say "no work outstanding" | all | The Executor causes it (polling) |
| 8 | **Hard stalls and caps that park an agent until the Executor resumes it** | `agent.stalled` (no progress 61–127 min, then kill and retry) about 10 distinct events in 13 ws; `paused-max_agent_duration` 33 (26 ws) plus `state_divergence … operator resume is required` 29; `before_run hook failed; agent paused pending Executor resume` 137 pauses in 70 aiur workspaces; uncooperative pause needing descendant reaping 169 (118 ws) | about 12 h lost to stall detection alone; each pause is idle until resumed | aiur (hook), all (stall, cap) | **Yes** — the resume is manual |
| 9 | **Test and build thrash** | 790 sessions ran ≥5 test commands, 422 ≥10, 122 ≥20, 23 ≥40; 538 had ≥1 failing run, 184 ≥3, 71 ≥5; ExUnit failures 565 sessions (aiur), vitest failures 283 (khala); ExUnit timeouts 55; `Unchecked dependencies` 156; build-gate lines 326 sessions (aiur); `EADDRINUSE` 20 | The longest threads, e.g. aiur#1464: 89 test runs, 21 failing, 8.4 h | aiur, khala | Rarely |
| 10 | **Duplicate agents / workspace collisions** | 37 tickets had two sessions actively running tools at the same time (>60 s overlap; 63 pairs; 5.9 h); attentions `duplicate-agent` 4, `workspace-collision` 3, `workpad-tmp-collision` 15 | Conflicting writes, wasted runs | khala, architecture-docs | **Yes.** The Executor traced one to a second daemon that had lost its repo pin |
| 11 | Label / state divergence | 48 `state_divergence` attentions (36 ws); 35 sessions hit `gh: Label does not exist (HTTP 404)`; agents added `agent:paused` 32×, `agent:done` 7×, `agent:merging` 6×; `lifecycle-label` 15 | Mostly small; divergence blocks dispatch | all | **Yes** for divergence |
| 12 | Environment / shell friction | Claude snapshot `chpwd`/eza hook hangs on any `cd` (45 khala/archon sessions mention it); Claude Bash timeouts in 37 sessions; `manual --test runs are blocked` hit in 43 sessions | Stalled shells; the Executor sent workaround notes | archon, khala, aiur | Yes (operational notes) |

**Negative findings** (modes that were expected but are rare):

- **Free-text questions:** 3 sessions end with one. Agents route questions through
  `decision.requested` instead.
- **Self-polling CI:** 60 sessions ran `gh pr checks` ≥5 times; commanded sleeps total
  7.8 h. Agents park in `agent:ci-wait` correctly (1,158 label adds). The waste is in the
  daemon's re-prompts (mode 1), not in agent polling.
- **Re-running brainstorm or plan on a retry:** 0 of 425 Claude prior-run re-dispatches;
  10 of 2,621 Codex restart turns.
- **Destructive git:** force-push in 76 sessions and `reset --hard` / `clean -f` in 26 —
  mostly legitimate rebases.

## 5. Detail and evidence per class

Paths use `~` for `/home/everdred`. `L<n>` is the line in the JSONL file.

### 5.1 No-op continuation loop (rank 1)

**Mechanism.** When a turn ends while the ticket label is still "active", the daemon sends
`Continuation guidance: The previous turn completed normally, but the issue is still in an
active state… do not end the turn while the issue stays active unless you are truly
blocked.` The agent is truly blocked, so it ends the turn again — up to the per-run turn cap
(e.g. `continuation turn #2 of 12`), and then a new run starts.

**Why it waits** (12,768 turns, regex-classified on the final message; 20/20 random spot
checks were genuine waits):

| Reason | Turns | % |
|---|---:|---:|
| dependency / declared blocker | 3,623 | 28.4 |
| CI pending (`agent:ci-wait` or not) | 3,555 | 27.8 |
| empty final message | 2,002 | 15.7 |
| human review / approval | 1,817 | 14.2 |
| Executor decision | 715 | 5.6 |
| "unchanged" / other / paused / limit | 1,056 | 8.3 |

**By week** (share of all turns): W31 70%, W32 78%, W33 44%, W34 29%, W36 13%, W37 0%,
W38 52%, W39 29%.

**Cost.** 186 h of turn time. For Codex, the per-turn `token_count` deltas summed over these
turns come to 2,498,613,667 tokens (1.68 M output+reasoning), about 204k per no-op turn,
because every turn re-sends the whole context.

Evidence:

- aiur#1483 (Codex), `~/.codex/sessions/2026/08/01/rollout-2026-08-01T22-56-55-019fc10b-fbcb-7be2-9bf3-e32929a3d999.jsonl`
  L3714–L3824: **11 turns in 25 s**, zero tool calls each: L3719 `"Awaiting CI."`, L3729
  `"No new terminal result has been delivered."`, L3749 `"CI is the only blocker."`, L3789
  `"Still waiting on CI."`, L3819 `"No terminal CI event has arrived."`
- khala#230 (Claude), `~/.claude/projects/-home-everdred--aiur-workspaces-aiur-team-khala-230/5fba9417-ef98-46e8-9d1d-cc023de44231.jsonl`
  L1143–L1242: a turn every ~9 s, each `"Nothing has changed since last turn. I'm still
  blocked on the Executor's answer to decision dec_7ba13ea633c1b749."`. In the daemon
  transcript `~/.aiur/workspaces/aiur-team/khala/230/logs/agent.ndjson`, cumulative
  `cost_usd` goes from 3.08 (L551, 01:20Z) to 36.79 (L3248, 02:01Z) over 267 turns. Then
  L3252 shows `"You've hit your session limit · resets 8:40pm"` and L3254 `turn_failed`.
- khala#33 (Claude), `~/.claude/projects/-home-everdred--aiur-workspaces-aiur-team-khala-33/bfdfe7ad-a2ef-4e40-9d5c-031db1e9641f.jsonl`
  L287 `"Still no change (9 consecutive identical checks now)… nothing has moved on the
  reviewer/Executor side."`; L300 `"Repeating this identical check every turn produces no
  new information and isn't genuine progress — I'm fully dependent on an external
  re-review now."` The agent names the problem itself.

### 5.2 Provider limits and retry storms (rank 2)

- **Claude session and credit limits.** 189 sessions made zero tool calls: 165
  `You've hit your session limit`, 21 `You're out of usage credits`, 3 `API Error: … Overloaded`.
  By date: 09-04 (64), 09-15 (45), 09-16 (38), 09-10 (28), 09-18 (24), 09-03 (20).
- **Storm example.** architecture-docs#41 has 29 sessions; 27 of them are sub-second limit
  deaths between 2026-09-04 00:56Z and 02:28Z. Relaunch gaps were 17–50 s, then about
  25-minute cycles, all against `resets 9:50pm (America/Los_Angeles)`
  (`…architecture-docs-41/e28185d5-5e29-4181-bb83-72aa85c1c0da.jsonl` L11, `…/d3300ae9-b258-468b-a154-62c215c89249.jsonl` L11).
- **Codex usage limit.** 380 turns end with `task_complete.error = "You've hit your usage
  limit…"`. aiur#1474, `~/.codex/sessions/2026/08/01/rollout-2026-08-01T22-56-56-019fc10b-ffcb-7433-912f-cd799fa7c303.jsonl`
  L3710: `"last_agent_message":null,"error":{"message":"You've hit your usage limit… try
  again at Aug 7th, 2026 9:42 PM."`. The workspace transcripts carry 125 more of these as
  `method:"error"` notifications.
- **Codex auth misconfiguration.** 70 turns in 19 khala threads on 2026-09-25 end with
  `unexpected status 401 Unauthorized: Incorrect API key provided: <REDACTED>`
  (khala#41, `~/.codex/sessions/2026/09/18/rollout-2026-09-18T15-14-19-01a0b695-b36e-7cc3-ba7b-de88bcdd1fa4.jsonl` L4215).
- **Daemon view.** `turn_failed "Error: claude exited with code 1"` 186× in 42 workspaces;
  where `provider_error` is present it reads `{"api_error_status":429,"error":"rate_limit"}`
  (e.g. `~/.aiur/workspaces/aiur-team/archon/18/logs/agent.ndjson` L302).

### 5.3 Restart, interrupt and process-death churn (rank 3)

- **Resume prompt** (aiur#1483 file above, L91): `Continuation guidance (session resumed
  after an aiur restart): … Do not restart from scratch and do not re-read the issue,
  labels, or workpad…` Yet 1,116 of 2,621 resume turns re-read the aiur-agent / using-aiur
  skill in their first 12 commands. The median resume turn uses 2 tools and 36 s, and 1,183
  (45%) are ≤1-tool no-ops. There are 256 restart waves (10-minute clustering; median 3
  agents per wave, max 216) on 26 distinct days.
- **Aborted turns.** 1,145 Codex turns end `turn_aborted: interrupted`. The next prompt is
  END (299), a restart resume (155), an `issue.commented` event (234), or an Executor message
  (185).
- **Process death** (`agent.ndjson` structured events):
  - `turn_ended_with_error ["port_exit",0]` — `~/.aiur/workspaces/1571/logs/agent.ndjson` L1729
  - `startup_failed "port_closed"` — `~/.aiur/workspaces/aiur-team/khala/132/logs/agent.ndjson` L3276
  - `turn_interrupt_failed … "expected active turn id … but found …"` — `~/code/aiur-workspaces/aiur-team/aiur/1337/logs/agent.ndjson` L3443 (an interrupt race)
  - `claude exited with code 143` — `~/.aiur/workspaces/aiur-team/archon/10/logs/agent.ndjson` L189
  - `Failed to spawn claude: spawn /usr/bin/claude EAGAIN` — `~/code/aiur-workspaces/aiur-team/aiur/1358/logs/agent.ndjson` L616
- **Claude re-dispatch cost is modest.** In the 425 prior-run continuations, the median is
  7 tool calls and 0.8 min before the first write (p90: 21 calls, 5.1 min). Rework
  continuations: median 13 calls, 2.2 min.

### 5.4 Blocked on the Executor (rank 4)

- **Decision waits.** See the khala#230 loop in §5.1. `ticket.N.agent.attention.operator-decision`
  appears 670 times in 45 workspace transcripts. `pause.request` reasons emitted by agents
  (Claude-parsable subset): dependency 45, operator_decision 33, github_auth_missing 18,
  infrastructure 4, credentials 3.
- **Stale `CHANGES_REQUESTED` rework loop.** GitHub keeps the old verdict, so the ticket
  bounces back to `agent:rework` with nothing to do. 66 rework sessions said so explicitly.
  khala#15, `~/.claude/projects/-home-everdred--aiur-workspaces-aiur-team-khala-15/de0e91c5-b56c-468d-b853-ba8990b5b707.jsonl`
  L530: `"agent:rework came back at 10:10:49Z, 22 s after ci-wait, with no new review or
  comment. GitHub keeps the old CHANGES_REQUESTED decision until the Executor re-reviews.
  Every finding is already addressed… so nothing was pushed."`
- **Rework without reading the review.** 98 of 361 Claude and 88 of 279 Codex rework
  sessions never ran a review-fetch command (`gh pr view … reviews/comments`,
  `pulls/N/comments`, `reviewThreads`). The rework prompt does not inline the feedback.
  Some of these reworks were triggered by an issue comment or a CI failure instead, so this
  is an upper bound on "lost the review".

### 5.5 CLI version skew: the missing deletion guard (rank 5)

- **Runtime output.** aiur#2639, `~/.codex/sessions/2026/09/19/rollout-2026-09-19T15-25-25-01a0bbc6-3a63-7733-9b36-b1f3b246157c.jsonl`
  L86: `aiur: opencode was not found on PATH… aiur: unknown command: guard-pr-deletions`,
  then `Usage: aiur [--interactive] …`.
- **Agent handoff notes normalize it.** aiur#2531,
  `~/.claude/projects/-home-everdred-code-aiur-workspaces-aiur-team-aiur-2531/26201355-6d87-4db9-9cf7-2af6b9344348.jsonl`
  L17: `"aiur guard-pr-deletions is not a subcommand in this build (exit 64, usage printed),
  so the deletion property was verified directly instead"`.
- **Root cause was already diagnosed by an agent.** aiur#1778,
  `~/.codex/sessions/2026/08/16/rollout-2026-08-16T18-35-00-01a00d5b-9476-7771-a54b-f1d2f067a889.jsonl`
  L23: `$ aiur --version → aiur 0.0.3 (its-everdred/aiur d6f11be)`; the installed
  `aiur-engine.sh` "is 50,434 bytes dated 16 Jul with **0** occurrences of
  `guard-pr-deletions`". The prompt and skill assume the develop CLI; agents get the
  npm-installed one.
- **Rate over time** (sessions): 08-11..20: 181; 08-21..31: 75; 09-01..10: 125;
  09-11..20: 117; 09-21..26: 81. It has not decayed.
- **Exit masking**, on top of the skew. Of about 3,270 guard-related command strings, at
  least 1,052 pipe the guard into `tail`/`head`/`grep` without `pipefail`, at least 62 add
  `|| true`/`echo`, and at least 157 push later in the same compound command. The guard
  only protects a push when it is chained with `&&` (at least 234 invocations).

### 5.6 GitHub API friction in the `gh` guard (rank 6)

- **Client errors are treated as secondary rate limits.** archon#171,
  `~/.claude/projects/-home-everdred--aiur-workspaces-aiur-team-archon-171/26943c6b-54f1-4715-96ad-fb5305cad4a4.jsonl`
  L55: `gh: Not Found (HTTP 404)\naiur: GitHub secondary rate limit; backing off 60s before
  the next call`. Across the corpus, 399 of 681 backoff messages directly follow an HTTP
  400/401/404/422. **This is a probable guard bug; the codebase report should confirm it.**
- **Read-only hold file in the Codex sandbox.** aiur#2227,
  `~/.codex/sessions/2026/08/22/rollout-2026-08-22T01-21-14-01a0288f-4889-7e72-971d-ef97feb1be7f.jsonl`
  L247: `.aiur-runtime/bin/gh: line 2223: …/github-quota/graphql-hold.tmp.2: Read-only file
  system` and then `line 2591: 1.787389887e+09: arithmetic syntax error`.
- **GraphQL exhaustion blocked PR creation.** aiur#1485,
  `~/.codex/sessions/2026/08/08/rollout-2026-08-08T14-37-13-019fe34f-010f-75e0-8cb9-c2dccc758229.jsonl`
  L837: `GraphQL: API rate limit already exceeded for user ID …`. This affected 140 aiur
  sessions, mostly in August.

### 5.7 Executor check-ins (rank 7)

aiur#2531, `~/.claude/projects/-home-everdred-code-aiur-workspaces-aiur-team-aiur-2531/eb297173-e597-4822-8e8f-4743c030e492.jsonl`:

- L109: `ticket.2531.operator.progress_request: Executor check-in: emit progress.checkin…
  this is a silent status ping.`
- L117 (the agent's full answer): `"Check-in sent. The ticket remains in
  agent:human-review with PR #2532 green… No work is outstanding on my side."`

The information was already on the tracker. Each ping costs a full model turn with the
whole context.

### 5.8 Stalls, caps and hook failures (rank 8)

- **Stall.** `~/.aiur/workspaces/aiur-team/khala/266/logs/agent.ndjson` L432: `"Agent
  command made no progress for 3669388ms; terminating it and scheduling a retry"`. Observed
  stalls lasted 3,644,151–7,612,698 ms (61–127 min) before the kill.
- **Duration cap causing divergence.** `~/code/aiur-workspaces/aiur-team/aiur/1793/logs/agent.ndjson`
  L12393: `local=paused(max_agent_duration) tracker=agent:in-progress; operator resume is
  required.`
- **Hook failure.** `~/code/aiur-workspaces/aiur-team/aiur/1270/logs/agent.ndjson` L1149:
  `"before_run hook failed; agent paused pending Executor resume."` There were 137 such
  pauses, all in the aiur repo (130 aiur-team, 7 its-everdred), spread over 22 days.
- **Executor pauses.** 573 `"Agent paused by Executor."` events in 205 workspaces (e.g.
  `~/.aiur/workspaces/aiur-team/archon/29/logs/agent.ndjson` L56). 169 pauses needed
  `"Reaping uncooperative agent descendants"`.

### 5.9 Test and build thrash (rank 9)

aiur#1464, `~/.codex/sessions/2026/08/01/rollout-2026-08-01T21-36-30-019fc0c2-5b95-7382-ba1d-5f8f5e4e6b61.jsonl`:
89 test commands, 18 outputs with non-zero ExUnit failures (L512 `15 tests, 2 failures`,
L528 `50 tests, 14 failures`, L849 `1858 tests, 1 failure`), over 8.4 h. Codex threads with
≥20 test runs: 129; with ≥5 failing runs: 49. Claude equivalents: 36 and 22.

### 5.10 Duplicate agents and workspace collisions (rank 10)

architecture-docs#24: two *initial* Claude sessions started at 05:05Z and 05:06Z on
2026-09-04 and ran concurrently for about 30 min (`9c399df5…`, `7b86f9b2…`). The Executor
then wrote, in `~/.claude/projects/-home-everdred--aiur-workspaces-aiur-team-architecture-docs-24/f265d9ed-29f8-4ab8-8208-78cac4707d54.jsonl`
L292: `"Executor: the workspace collision is resolved and you are the sole owner of …/24.
Root cause was a second aiur daemon … that had lost its repo pin"`.

### 5.11–5.12 Labels and environment

- **Missing labels.** 35 sessions hit `gh: Label does not exist (HTTP 404)` while removing
  a label the ticket no longer had. Each also pays the 60 s false backoff from §5.6.
- **Shell hang.** archon#164, `~/.claude/projects/-home-everdred--aiur-workspaces-aiur-team-archon-164/b6e1a104-7d32-4b88-a45b-49ae0acbf9a5.jsonl`
  L183 (Executor to agent): `"The mutation shell stalled twice because any cd … triggers
  the replayed chpwd/eza hook before the command runs. Do not use cd anywhere."`

## 6. Which modes force Executor intervention

| Needs the Executor to act | Executor causes it | Agent absorbs it silently (hidden cost) |
|---|---|---|
| 2 provider limits (resume, reroute, fix API key) | 3 restarts (resume churn, aborted turns) | 1 no-op loops (quota and tokens) |
| 4 decisions, stale `CHANGES_REQUESTED`, re-review | 7 progress check-ins | 5 missing guard and masked exit codes |
| 8 stalls, duration caps, `before_run` failures, pause reaping | | 6 false 60 s backoffs and read-only hold files |
| 10 duplicate daemon / workspace collision | | 9 test thrash |
| 11 state divergence | | |
| 12 environment workarounds (shell notes) | | |

The largest item in both the "needs the Executor" and "hidden cost" columns has the same
root: **the daemon re-prompts agents that are correctly parked.** CI-wait, human-review,
blocked-on-dependency and awaiting-decision all generate continuation turns. That wastes
tokens, and via the shared provider limit it becomes a fleet-wide outage that the Executor
must then clear.

## 7. Caveats

- **Regex classification.** Prompt kinds are reliable because they come from fixed daemon
  templates. Wait reasons (§5.1) and outcomes (§3) are regex-classified on free text. The
  spot checks were clean, but treat the percentages as ±5 pts.
- **Source text contamination.** Broad signatures such as `index.lock`, `mix deps.get`,
  `timeout` and `rate limit` first matched in about 40% of sessions, because agents read
  skill files and source containing those strings. They were discarded. Only
  output-specific strings are counted in §4–5. The `aiur: agents cannot approve or merge`
  refusal (66 sessions) was dropped for the same reason: its hits were agents reading
  `github_quota_guard.sh`.
- **Codex totals.** Sessions are threads that span resumes, so "session length" for Codex
  is thread lifetime, not active time. Token totals use per-event `last_token_usage`
  deltas and count cached input.
- **Transcript coverage.** Only 418 workspaces still have `agent.ndjson`, so the
  attention/alert counts are lower bounds. Many older workspaces were cleaned.
- **Duplicated alerts.** Attention alerts are sometimes emitted twice (alert plus raw) or
  re-emitted each turn. "Workspaces affected" is the safer count.
- **Private repositories** are included in every number and excluded from every quote. The
  1,069-turn thread and parts of the limit-storm and no-op-loop counts come from them.

## 8. Reproduce

The scratch directory `~/.aiur/research/refactor-2026-09-26/scratch/failmodes/` holds:

- **Extractors:** `extract.py`, `turns.py`, `cmds.py`, `outscan.py`, `pats2.py`,
  `pats2.tsv`, `noop_tokens.py`
- **Per-session features:** `prim.json`, `claude_feat.jsonl`, `codex_feat.jsonl`
- **Per-turn records:** `turns.jsonl`
- **Every shell command:** `cmds.jsonl`
- **Signature hits:** `pats2_hits.json`
- **Daemon events:** `ws_err_events.txt`, `ws_alerts.txt`
- **Codex cwd index:** `codex_index.tsv`
