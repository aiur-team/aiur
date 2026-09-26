# Aiur quantitative census (2026-09-26)

Snapshot taken 2026-09-26 between about 15:00Z and 15:30Z. Some live files grew
while I measured (khala wakes went from 2,201 to 2,203 lines; Claude transcript
counts grew by one or two). Every number states its source. Numbers are counts
unless marked **estimate**.

Private repos are shown only as counts: **private-multisig (private)** and
**croptracker (private)**. This file has no titles, bodies, label breakdowns, branch
names, ticket numbers or paths from those repos.

Files in this folder:

| File | Content |
|---|---|
| `headline.csv` | The headline table below |
| `github.csv` | Issue and PR counts, authors, time to merge, per repo |
| `agent_sessions_per_ticket.csv` | Agent sessions per ticket (median, p90, max) |
| `executor_sessions.csv` | Executor-candidate sessions per repo-root directory |
| `meta_handoffs.csv` | /aiur-meta files, retros, findings, handoffs, with date ranges |
| `runs.csv` | One row per retained run log dir: start, end, span, repo, tickets |
| `wakes_by_topic_class.csv` | Wake events: 132 topic classes by repo |

The scripts that make these numbers are in `../scratch/*.py` (named in each section).

---

## 0. Read this first: coverage windows

Each source keeps a different window. Aiur started on 2026-05-18 (first issue in
aiur-team/aiur). No local source goes back that far.

| Source | Retained window | Why it is short | How measured |
|---|---|---|---|
| GitHub issues and PRs | full history | — | REST `repos/{o}/{r}/issues?state=all --paginate` |
| GitHub `agent:*` label events | aiur: **2026-07-17 → now only**; other repos: full | The repo `issues/events` endpoint stops at 300 pages (30,000 events). aiur reached this limit. | `gh api -i .../issues/events?per_page=100` Link header shows `page=300` for aiur |
| Codex sessions `~/.codex/sessions` | 2026-07-16 → now | No older rollouts on disk | `find ~/.codex/sessions -mindepth 2 -maxdepth 2 -type d` → only `2026/07 2026/08 2026/09` |
| Claude transcripts `~/.claude/projects` | about 2026-09-01 → now (30-day cleanup) | Claude Code cleanup (`~/.claude/.last-cleanup` = 2026-09-26T15:05Z); oldest `*.jsonl` mtime = 2026-09-01 | `find ~/.claude/projects -mindepth 2 -maxdepth 2 -name '*.jsonl' -printf '%TY-%Tm-%Td\n' \| sort \| head -1` |
| Claude prompt history `~/.claude/history.jsonl` | 2026-07-19 → now | Keeps interactive prompts only (1,201 lines) | `scratch/claude_hist.py` |
| Run logs `~/.aiur/logs/*/` | **2026-09-15 → now** (39 dirs) | Older run dirs were pruned | `find ~/.aiur/logs -mindepth 1 -maxdepth 1 -type d \| wc -l` → 39 (the brief said 40) |
| Run summaries `~/.aiur/repo/*/*/analytics/runs/*/run-summary.json` | 21 older runs, 2026-08-08 → 2026-09-17 | They name source run dirs that no longer exist | `scratch/final_runs.py` |
| Workspaces on disk | open tickets only | Aiur deletes a workspace when its ticket closes | `find` on the three workspace roots (section 3) |

So the agent and Executor session counts are **lower bounds for aiur**. aiur merged 573
PRs from May through July. No agent transcript for that period is on disk.

**Repo identity (surprise).** `aiur-team/architecture-docs` was **renamed** to
`aiur-team/archon`. `gh api repos/aiur-team/architecture-docs` returns
`full_name=aiur-team/archon`, and both have `id=1355265471`. They are one GitHub repo with
one issue numbering. But Aiur keeps two separate local state dirs
(`~/.aiur/repo/aiur-team/architecture-docs` and `.../archon`). Also, `its-everdred/aiur`
redirects to `aiur-team/aiur`, so 303 Codex sessions under the old path belong to aiur.
GitHub numbers below count the archon repo once. Local-state numbers show both eras.

Out of scope, and not counted in the totals: `aiur-team/aiur-claude` (6 PRs, 1 issue)
and `aiur-team/archon-docs` (4 PRs, 0 issues). Neither has an Aiur state dir.
Fixtures (`test-org/test-repo`, `owner/repo`, `acme/widgets`, `_unresolved`) are ignored.

---

## 1. Headline table

| Repo | Issues (open) | Issues that entered the pipeline¹ | PRs (merged) | Agent workspaces² | Agent sessions, top-level³ | Agent subagent threads³ | Executor sessions⁴ | Handoffs⁵ | Meta files⁶ | Retro docs⁶ | Findings lines⁶ | Runs retained / historical⁷ | Wake lines⁸ |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| aiur | 1,272 (111) | ≥921 | 1,547 (1,208) | 472 | 1,114 | 3,549 | 37 | 18 | 93 | 8 | 43 | 5 / 20 | 4,749 |
| archon (incl. architecture-docs era) | 152 (63) | 93 | 110 (109) | 80 | 368 | 333 | 11 | 7 | 22 | 3 | 8 | 0 / 1 | 2,691 |
| khala | 217 (29) | 214 | 222 (218) | 197 | 852 | 1,043 | 2 | 61 | 0 | 3 | 13 | 20 / 0 | 2,203 |
| kevinweaver-dev | 63 (8) | 51 | 119 (76) | 46 | 52 | 74 | 10 | 0 | 0 | 0 | 9 | 0 / 0 | 0 |
| private-multisig (private) | 49 (7) | 37 | 63 (61) | 25 | 79 | 171 | 1 | 0 | 0 | 0 | 0 | 5 / 0 | 117 |
| croptracker (private) | 8 (8) | 3 | 1 (0) | 3 | 3 | 17 | 1 | 0 | 0 | 0 | 0 | 0 / 0 | 0 |
| **Total** | **1,761 (226)** | **≥1,319** | **2,062 (1,672)** | **823** | **2,468** | **5,187** | **62** | **86** | **115** | **14** | **73** | **30 / 21** (+9 empty) | **9,760** |

1. Issues (not PRs) that had an `agent:*` label at any time in the event window, or have one now. For aiur the event window starts on 2026-07-17, so 921 is a lower bound. Script: `scratch/label_stats.py`.
2. Distinct ticket numbers that have a workspace. This is the union of Codex agent sessions, Claude agent project dirs, opencode sessions and workspace dirs on disk. Script: `scratch/headline.py`.
3. Top-level = Codex threads whose `source` is not a subagent spawn, plus Claude `<project>/*.jsonl` sessions, plus opencode. Subagent threads = Codex `source.subagent.thread_spawn` threads, plus Claude `<session>/subagents/**/*.jsonl` files.
4. Claude sessions (union of `history.jsonl` session IDs and retained transcripts), plus Codex TUI top-level sessions, plus opencode top-level sessions whose cwd is the repo root. Section 4 has the split.
5. `~/.aiur/repo/<o>/<r>/executor/handoffs/*handoff*.md`.
6. `meta/*.md` (top level), `meta/retros/*.md` (top level only), and lines in `meta/findings.ndjson`.
7. Retained = dirs in `~/.aiur/logs` that I can attribute to the repo. Historical = runs that exist only as `analytics/runs/*/run-summary.json`. Nine more retained dirs are empty or aborted boots that belong to no repo.
8. Lines in `executor/<repo>.executor.wakes.ndjson` (archon = archon 810 + architecture-docs 1,881).

---

## 2. Tickets (GitHub issues)

Measured with
`gh api 'repos/{o}/{r}/issues?state=all&per_page=100' --paginate --jq '.[]|{n:.number,state,reason:.state_reason,user:.user.login,created:.created_at,closed:.closed_at,labels:[.labels[].name],pr:(.pull_request!=null),merged:.pull_request.merged_at}'`,
then `scratch/gh_stats.py`. PRs are removed with `pr==false`.

| Repo | Issues | Open | Closed | Closed as not planned | Filed by its-everdred | Filed by its-applekid | First issue | Last issue |
|---|---|---|---|---|---|---|---|---|
| aiur | 1,272 | 111 | 1,161 | 56 | 996 | 276 | 2026-05-18 | 2026-09-26 |
| archon | 152 | 63 | 89 | 0 | 92 | 60 | 2026-09-02 | 2026-09-24 |
| khala | 217 | 29 | 188 | 1 | 202 | 15 | 2026-09-16 | 2026-09-26 |
| kevinweaver-dev | 63 | 8 | 55 | 9 | 55 | 8 | 2026-08-01 | 2026-08-03 |
| private-multisig (private) | 49 | 7 | 42 | 0 | 48 | 1 | 2026-09-15 | 2026-09-15 |
| croptracker (private) | 8 | 8 | 0 | 0 | 8 | 0 | 2026-07-28 | 2026-07-28 |
| **Total** | **1,761** | **226** | **1,535** | **66** | **1,401 (80%)** | **360 (20%)** | | |

**Who filed them.** Only two logins filed issues. `its-applekid` is the agent account.
`its-everdred` is the account of the human **and** of the Executor session that acts for
the human. The login cannot tell those two apart, and I found no body marker that does.
So "its-everdred" means "human or Executor", not "human". The prose and batch shape
(for example 20+ "AS-nn" Build Order tickets filed on 2026-09-24 in aiur) suggest that
most were written by an Executor session. That is an **inference**, not a count.

**Pipeline entry, from `agent:*` label events.** Measured with
`gh api 'repos/{o}/{r}/issues/events?per_page=100' --paginate --jq '.[]|select(.event=="labeled" and (.label.name|startswith("agent:")))'`,
then `scratch/label_stats.py`.

| Repo | Event window | `agent:*` labeled events | Issues ever labeled | Labeled now | Union | Applied by its-applekid | Applied by aiur-daemon[bot] | Applied by its-everdred |
|---|---|---|---|---|---|---|---|---|
| aiur | 2026-07-17 → 09-26 (truncated) | 10,822 | 683 | 859 | 921 | 7,068 | 2,099 | 1,643 |
| archon | 2026-09-02 → 09-24 | 972 | 93 | 93 | 93 | 417 | 359 | 196 |
| khala | 2026-09-16 → 09-26 | 2,267 | 214 | 49 | 214 | 1,798 | 6 | 463 |
| kevinweaver-dev | 2026-08-01 → 08-03 | 409 | 51 | 50 | 51 | 162 | 0 | 247 |
| private-multisig (private) | one day | 198 | 37 | 35 | 37 | 105 | 0 | 93 |
| croptracker (private) | one day | 10 | 3 | 3 | 3 | 7 | 0 | 3 |

- khala has 214 issues that were ever labeled, but only 49 carry an `agent:*` label now. In khala, closing an issue removes the label (only 6 `agent:done` events). In aiur, `agent:done` stays (564 issues). So "labeled now" is not a reliable pipeline measure across repos.
- Label churn is high. aiur has 2,873 `agent:rework` events and 2,708 `agent:ci-wait` events in the truncated window. That is about 15.8 `agent:*` events per issue labeled in the window (10,810 ÷ 683). archon has about 10.5, khala about 10.6.

---

## 3. Pull requests

Same fetch as section 2. PRs are the rows with `pr==true`. Time to merge = `merged_at − created_at`.

| Repo | PRs | Merged | Closed unmerged | Open | By its-applekid | By its-everdred | By other | Merged, by applekid | Time to merge, median (h) | Time to merge, p90 (h) |
|---|---|---|---|---|---|---|---|---|---|---|
| aiur | 1,547 | 1,208 | 311 | 28 | 1,246 | 301 | 0 | 947 | 1.73 | 24.44 |
| archon | 110 | 109 | 0 | 1 | 102 | 8 | 0 | 102 | 0.76 | 4.57 |
| khala | 222 | 218 | 3 | 1 | 194 | 28 | 0 | 192 | 0.64 | 4.93 |
| kevinweaver-dev | 119 | 76 | 41 | 2 | 23 | 48 | 48 (github-actions[bot]) | 22 | 0.34 | 8.22 |
| private-multisig (private) | 63 | 61 | 1 | 1 | 24 | 39 | 0 | 24 | 0.16 | 1.21 |
| croptracker (private) | 1 | 0 | 0 | 1 | 1 | 0 | 0 | 0 | — | — |
| **Total** | **2,062** | **1,672** | **356** | **34** | **1,590 (77%)** | **424** | **48** | **1,287** | | |

Split by author (from `scratch/pr_split.py`):

| Repo | Author | Merged | Closed unmerged | Time to merge, median (h) | Time to merge, p90 (h) |
|---|---|---|---|---|---|
| aiur | its-applekid | 947 | 277 | 2.28 | 27.7 |
| aiur | its-everdred | 261 | 34 | 0.38 | 9.87 |
| archon | its-applekid | 102 | 0 | 0.84 | 4.76 |
| khala | its-applekid | 192 | 1 | 0.79 | 5.12 |
| khala | its-everdred | 26 | 2 | 0.09 | 0.15 |

aiur merged PRs per month (by `merged_at`): 2026-05: 39, 06: 209, 07: 325, **08: 499**,
09: 136 (to 09-26). aiur issues per month: 86, 195, 345, 450, 196. In September, merge
throughput on aiur fell to about a quarter of its August rate, while khala (218) and
archon (109) took the fleet.

In aiur, 22% of agent PRs (277 of 1,246) closed without merge. For archon and khala
the figure is below 1%.

---

## 4. Agents: workspaces and sessions

### 4.1 Where agents run

The workspace roots come from each repo's `.aiur/config` (`workspace.root`).

| Root | Repos | Ticket dirs on disk now | Command |
|---|---|---|---|
| `~/code/aiur-workspaces/<owner>/<repo>/<n>` | aiur (321 under `aiur-team/aiur`, 28 under the old `its-everdred/aiur`) | 337 distinct aiur tickets (346 once the old flat dirs below are added) | `find ~/code/aiur-workspaces -mindepth 1 -maxdepth 3 -type d -name '[0-9]*' -prune` |
| `~/.aiur/workspaces/<owner>/<repo>/<n>` | archon, khala, private-multisig (private), croptracker (private) | archon 17, khala 28 (live; 25 earlier in the census), private-multisig (private) 10, croptracker (private) 3 | `find ~/.aiur/workspaces/<o>/<r> -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+$'` |
| `~/.aiur/workspaces/<n>` (old flat layout) | architecture-docs, aiur, khala | 24 dirs: 8 architecture-docs, 15 aiur (#1471–#1793), 1 khala | `git config -f <dir>/.git/config remote.origin.url` for each dir |
| `~/.aiur/workspaces/khala/aiur-team/khala` | khala (misrooted: repo path doubled) | 1 dir, with 26 Codex sessions | |
| `~/code/kwdev-workspaces/its-everdred/kevinweaver-dev/<n>` | kevinweaver-dev | 38 (+3 `-manual`) | |

### 4.2 Sessions per backend

- **Codex**: `scratch/codex_scan.py` reads line 1 (`session_meta`) of all 6,534 `~/.codex/sessions/**/*.jsonl` files. It records `cwd`, `originator` and `source`. Then `scratch/codex_classify.py` sorts each session by `cwd`.
- **Claude**: `scratch/claude_scan.py` reads each `~/.claude/projects/<dir>`. Agent dirs match `-home-everdred-(-aiur-workspaces|code-aiur-workspaces)-<owner>-<repo>-<n>`.
- **opencode**: `sqlite3 -readonly ~/.local/share/opencode/opencode.db "select directory, parent_id is not null from session"` returns 98 sessions. Only 2 are agent sessions (khala).

| Repo | Tickets with transcripts | Codex top-level | Codex subagent | Claude top-level | Claude subagent | opencode | Codex window | Claude window |
|---|---|---|---|---|---|---|---|---|
| aiur | 395 | 949 | 3,529 | 165 | 20 | 0 | 2026-07-30 → 09-19 | 2026-09-03 → 09-20 |
| archon (both eras) | 77 | 36 | 195 | 332 | 138 | 0 | 2026-09-03 → 09-04 | 2026-09-03 → 09-11 |
| khala | 196 | 128 | 871 | 722* | 172 | 2 | 2026-09-16 → 09-26 | 2026-09-18 → 09-26 |
| kevinweaver-dev | 35 | 52 | 74 | 0 | 0 | 0 | 2026-08-01 → 08-02 | — |
| private-multisig (private) | 25 | 20 | 126 | 59 | 45 | 0 | one day | one day |
| croptracker (private) | 3 | 3 | 17 | 0 | 0 | 0 | one day | — |
| **Total** | **731** | **1,188** | **4,812** | **1,278** | **375** | **2** | | |

\* khala Claude includes 9 sessions from a nested `claude-proof` dir that an agent
spawned under ticket 165's runtime tmp.

Codex total check: 6,000 agent + 501 at a repo root + 33 elsewhere = 6,534.

**Sessions per ticket** (top-level Codex + Claude; `scratch/per_ticket.py`):

| Repo | Median | p90 | Max | Median incl. subagents | p90 incl. subagents |
|---|---|---|---|---|---|
| aiur | 2 | 5 | 11 | 8 | 27 |
| archon | 4 | 10 | 31 | 7 | 18 |
| khala | 4 | 8 | 15 | 7 | 19 |
| kevinweaver-dev | 1 | 2 | 3 | 2 | 6.2 |
| private-multisig (private) | 1 | 7.2 | 13 | 9 | 17.8 |

Findings:

- **80% of Codex agent threads are subagents** that the agents spawned (4,812 of 6,000). The pattern is `source.subagent.thread_spawn`, for example review personas under `/root/<name>_review`. On aiur there are 3.7 subagent threads for each top-level agent thread.
- **Backend mix changed over time.** Codex did almost all agent work until mid-September. Claude did most of archon (332 vs 36) and khala (722 vs 128). 71 khala tickets and 20 aiur tickets had sessions on **both** backends (for example after a fallback or re-dispatch).
- Codex agent sessions by month: 2026-07: 379, 08: 4,017, 09: 1,578.
- Workspaces vs pipeline: aiur shows 472 workspaces for ≥921 labeled issues. The gap is the transcript window (section 0), not tickets that were never dispatched.

---

## 5. Executor sessions

Executor candidates are sessions whose cwd is a repo root (`/home/everdred/github/everdred/<repo>`),
not an agent workspace. Sources:

- Claude transcript dir `-home-everdred-github-everdred-<repo>`.
- Claude `history.jsonl` session IDs for that project path. This covers a longer period, but only interactive prompts.
- Codex sessions with that cwd. `codex-tui` = interactive; `codex_exec` = scripted, not an Executor.
- opencode sessions with that directory.

Script: `scratch/exec_agg.py`.

| Repo root | Claude sessions (history ∪ transcripts) | Claude history window | Claude transcripts retained | Claude Executor subagent transcripts | Codex TUI top-level | Codex TUI subagent threads | Codex TUI window | codex_exec (scripted) | opencode top / child |
|---|---|---|---|---|---|---|---|---|---|
| aiur | 19 | 2026-07-19 → 09-26 | 8 | 537 | 10 | 246 | 2026-07-17 → 09-16 | 36 (all on 2026-09-18) | 8 / 75 |
| architecture-docs | 1 | 2026-09-03 → 09-04 | 1 | 86 | 3 | 37 | 2026-09-03 | 0 | 1 / 0 |
| archon | 4 | 2026-09-14 → 09-25 | 4 | 146 | 2 | 0 | 2026-09-09 → 09-16 | 0 | 0 / 0 |
| khala | 1 | 2026-09-18 → 09-26 | 1 | 259 | 1 | 7 | 2026-09-16 | 1 | 0 / 0 |
| kevinweaver-dev | 4 | 2026-07-31 → 08-11 | 0 | 0 | 3 | 90 | 2026-08-02 → 08-17 | 0 | 3 / 5 |
| private-multisig (private) | 1 | one day | 1 | 110 | 0 | 0 | — | 0 | 0 / 0 |
| croptracker (private) | 1 | one day | 0 | 0 | 0 | 0 | — | 0 | 0 / 0 |

Non-Aiur repo roots, for context only: flowerpot, dotfiles, health, hard-cache, norentgrets.
Codex also ran 10 scripted `codex_exec` sessions from `~/.aiur/executor-worktrees/*`.

- **Few sessions, but very long ones.** aiur has 19 Claude Executor sessions in 10 weeks, and one Claude session in khala covers 2026-09-18 → 09-26. Executor work comes in long, compacted sessions that fan out to subagents: 537 subagent transcripts in aiur in the 30-day window, 259 in khala. A session count understates Executor turnover. Handoffs measure it better.
- **Codex was an Executor too.** In aiur, 10 top-level Codex TUI sessions (2026-07-17 → 09-16) spawned 246 subagent threads.

### 5.1 Handoffs (Executor-to-Executor transitions)

`find ~/.aiur/repo/<o>/<r>/executor/handoffs -name '*handoff*.md'`; cadence from `scratch/handoffs.py`.

| State dir | Handoffs | First | Last | Median gap (min) | Gaps < 10 min | By day |
|---|---|---|---|---|---|---|
| aiur | 18 | 2026-08-11 | 2026-09-16 | 48.7 | 3 | 09-16: 9; 8 other days: 1–2 |
| archon | 5 | 2026-09-09 | 2026-09-10 | 146 | 0 | |
| architecture-docs | 2 | 2026-09-03 | 2026-09-03 | 215 | 0 | |
| khala | **61** | 2026-09-17 | 2026-09-20 | **4.4** | **45** | **09-18: 58** |
| private-multisig (private), kevinweaver-dev | 0 | | | | | |

Each of those state dirs (except `_unresolved`) also has one rolling `executor/handoff.md`.
**Surprise:** khala wrote 58 handoffs in one day, with a median gap of 4.4 minutes. That
looks like a handoff loop or Executor thrash, not 58 real Executor changes.

---

## 6. /aiur-meta output

`scratch/meta_stats.py`. Dates come from filename timestamps and file mtimes.

| State dir | `meta/*.md` | Meta dates | Retro docs `meta/retros/*.md` | All `*.md` under retros (incl. `verdict.md`) | Snapshot dirs (`dashboard-*`, `cli-*`) | `findings.ndjson` lines | Findings window (`observed_at`) | `asks.ndjson` lines |
|---|---|---|---|---|---|---|---|---|
| aiur | 93 | 2026-08-08 → 09-11 | 8 | 39 | 38 | 43 | 2026-08-02 → 08-21 | 5 |
| archon | 22 | 2026-09-10 → 09-11 | 2 | 6 | 8 | 8 | 2026-09-10 | 0 |
| architecture-docs | 0 | — | 1 | 6 | 8 | 0 | — | 0 |
| khala | 0 | — | 3 | 7 | 23 | 13 | 2026-09-16 → 09-26 | 0 |
| private-multisig (private) | 0 | — | 0 | 0 | 0 | 0 | — | 0 |
| kevinweaver-dev | 0 | — | 0 | 0 | 0 | 9 | 2026-08-03 | — |

- **Correction to the brief.** The known figures "aiur retros=39, archon=6, khala=7, architecture-docs=6" count every `*.md` recursively. Most of those are per-check `verdict.md` files inside `<retro>.md.d/dashboard-<epoch>/`. The real retro documents number 8 / 2 / 3 / 1. Each retro doc has a `.md.d` folder of hourly snapshot dirs (38 / 8 / 23 / 8).
- aiur `meta/*.md` by filename date: 08-08: 2, 08-09: 9, 08-10: 15, 08-11: 8, 08-21: 18, 08-22: 20, 08-23: 19, 09-10: 1, 09-11: 1. So 91 of the 93 files come from 7 days. **No aiur meta file is newer than 2026-09-11**, and khala has none at the top level. The durable meta log stopped about 2 weeks ago. Only retros, findings and handoffs continue.

---

## 7. Runs (`~/.aiur/logs/*/`)

`scratch/runs.py` and `scratch/final_runs.py` → `runs.csv`.

- **Repo**: base64url-decode the middle part of `github-<b64>.<n>.log` (for example `YWl1ci10ZWFtL2toYWxh` = `aiur-team/khala`). If a dir has no such files, the repo comes from `<repo>.<n>.subscriptions.json`, then from `<owner>_<repo>-*.alerts.ndjson`.
- **Start**: the dir name.
- **End**: the later of the last `telemetry.ndjson` timestamp and the newest file mtime.
- **Tickets**: distinct `<n>` values.

The first telemetry record is **not** the run start. Telemetry is compacted, so for long
runs it keeps only the last window. For this reason `span_h` (start to end) and
`telemetry_window_h` are separate columns.

| Repo | Runs | Total span (h) | Size (MB) | Distinct tickets with per-ticket logs |
|---|---|---|---|---|
| khala | 20 | 184.7 | 607 | 201 |
| aiur | 5 | 143.9 | 197 | 31 |
| private-multisig (private) | 5 | 161.6 | 102 | 25 |
| empty or aborted boot (0–4 files) | 9 | 0.2 | 0.4 | 0 |
| **Total** | **39** | | **≈869 MB (`du -sh`)** | |

The longest spans:

| Run | Repo | Span |
|---|---|---|
| `20260916T151630Z` | private-multisig (private) | 144 h, 6 files, 0 tickets |
| `20260917T022859Z` | aiur | 133 h, 12 tickets |
| `20260920T010817Z` | khala | 62.6 h, 2 tickets |
| `20260918T104829Z` | khala | 38 h, 31 tickets |
| `20260925T042508Z` | khala | 24.9 h, 74 tickets |

Three runs end at the same moment, 2026-09-22 15:42Z: an aiur run, a khala run and a
private-multisig (private) run. So several daemons were running at once and were stopped together.
Nine of 39 dirs (23%) are empty or aborted boots. Six of those nine are clustered on
09-16 15:15, 09-17 15:23 and 09-25 23:51–23:59, which suggests restart storms.

**Older runs, known only from analytics summaries:** 21 `run-summary.json` files name
source run dirs that are now deleted: 20 aiur runs (`20260808T213030Z` →
`20260917T022859Z`) and 1 architecture-docs run (`20260904T002759Z`). They keep only a
telemetry window, so this census gives no duration or ticket count for them.
Command: `head -c 4000 run-summary.json | grep -o 'logs/[^/]*'`.

---

## 8. Wake streams

`jq -r '[$r,.topic_class,.first_seen_at]|@tsv' executor/<repo>.executor.wakes.ndjson`,
then `scratch/wakes.py` (pivot → `wakes_by_topic_class.csv`, 132 distinct topic classes)
and `scratch/handoffs.py` (`needs_attention`).

| State dir | Lines | Window | `needs_attention=true` | Distinct tickets |
|---|---|---|---|---|
| aiur | 4,749 | 2026-08-18 → 09-20 | 1,743 (37%) | 220 |
| architecture-docs | 1,881 | 2026-09-03 → 09-05 | 1,471 (78%) | 54 |
| archon | 810 | 2026-09-09 → 09-11 | 569 (70%) | 29 |
| khala | 2,203 | 2026-09-16 → 09-26 (live) | 534 (24%) | 195 |
| private-multisig (private) | 117 | 2026-09-15 → 09-20 | 17 | 25 |

By family (first two parts of `topic_class`):

| Family | aiur | khala | arch-docs | archon | private-multisig (private) | Total |
|---|---|---|---|---|---|---|
| system.fleet | 660 | 65 | 1,156 | 562 | 5 | 2,448 |
| ticket.branch | 833 | 687 | 122 | 97 | 50 | 1,789 |
| system.dispatch | 1,389 | 6 | 315 | 28 | 0 | 1,738 |
| ticket.agent | 829 | 525 | 94 | 23 | 15 | 1,486 |
| ticket.pr | 532 | 560 | 109 | 63 | 23 | 1,287 |
| ticket.ci | 373 | 357 | 73 | 37 | 22 | 862 |
| system.github | 115 | 1 | 10 | 0 | 1 | 127 |
| system.tracker | 18 | 0 | 2 | 0 | 1 | 21 |

The 12 most frequent topic classes:

| Topic class | aiur | khala | arch-docs | archon | private-multisig (private) | Total |
|---|---|---|---|---|---|---|
| ticket.branch.push | 833 | 687 | 122 | 97 | 50 | 1,789 |
| system.fleet.capacity.starved | 106 | 31 | 1,067 | 523 | 0 | 1,727 |
| ticket.pr.merged | 341 | 192 | 56 | 37 | 22 | 648 |
| ticket.ci.passed | 171 | 325 | 66 | 35 | 19 | 616 |
| system.dispatch.capacity_starved | 218 | 6 | 315 | 28 | 0 | 567 |
| system.dispatch.prewarm_blocked | 515 | 0 | 0 | 0 | 0 | 515 |
| system.dispatch.prewarm_blocked.resolved | 500 | 0 | 0 | 0 | 0 | 500 |
| ticket.pr.opened | 180 | 191 | 52 | 26 | 0 | 449 |
| system.fleet.capacity.resumed | 303 | 20 | 43 | 29 | 4 | 399 |
| ticket.ci.failed | 202 | 32 | 7 | 2 | 3 | 246 |
| system.fleet.capacity.backoff | 171 | 14 | 46 | 10 | 1 | 242 |
| ticket.pr.ready_for_review | 4 | 177 | 0 | 0 | 0 | 181 |

- **Capacity noise dominates the archon and architecture-docs streams.** `system.fleet.capacity.starved` makes up 57% of architecture-docs wakes (1,067 of 1,881) and 65% of archon wakes (523 of 810). In aiur, 1,015 of 4,749 wakes (21%) are the `prewarm_blocked` / `.resolved` pair.
- **The ticket.agent attention wakes differ by repo.** khala has 71 `github-permissions`, 69 `workflow-permissions`, 69 `github-write-access` and 41 `codex-usage-limit` wakes. None of these occur in aiur. aiur has 61 `github-broker-unavailable` and 65 `paused-before_run_failure` wakes.

---

## 9. Surprises (short list)

1. **architecture-docs and archon are one GitHub repo** (renamed, same id 1355265471), but Aiur keeps two state dirs, two wake streams and two agent-transcript namespaces for it.
2. **Most history is gone.** Run logs start at 2026-09-15, Claude transcripts at about 2026-09-01, Codex at 2026-07-16, and aiur label events at 2026-07-17. aiur began on 2026-05-18. 573 merged aiur PRs (May–July) have no local agent trace.
3. **80% of Codex agent threads are subagents.** Agents spawned 4,812 subagent threads for 1,188 top-level threads.
4. **khala: 58 Executor handoffs on 2026-09-18**, with a median gap of 4.4 minutes.
5. **The /aiur-meta log stopped.** No `meta/*.md` in any repo after 2026-09-11, and 91 of the 93 aiur meta files come from 7 days. The known "retros=39" figure counts `verdict.md` snapshots; there are 8 real retro documents.
6. **In September, aiur merge throughput fell to about a quarter of the August rate** (136 vs 499). The fleet was on khala and archon.
7. **aiur agent PRs: 22% closed without merge** (277 of 1,246). archon and khala: under 1%.
8. **Capacity-starved wakes are 57–65% of the wakes in the archon/architecture-docs streams.** They are noise that the Executor must read.
9. **23% of run dirs are empty or aborted boots**, in clusters. Three daemons ended together on 2026-09-22 15:42Z.
10. **A misrooted khala workspace** (`~/.aiur/workspaces/khala/aiur-team/khala`) has 26 Codex sessions, and a nested Claude project exists under a khala agent's runtime tmp.

---

## 10. Reproduce

All scripts are in `~/.aiur/research/refactor-2026-09-26/scratch/`. Run them in this order:

1. `gh_stats.py`
2. `label_stats.py`
3. `codex_scan.py`
4. `codex_classify.py`
5. `claude_scan.py`
6. `exec_agg.py`
7. `per_ticket.py`
8. `headline.py`
9. `meta_stats.py`
10. `handoffs.py`
11. `runs.py`
12. `final_runs.py`
13. `wakes.py`
14. `pr_split.py`
15. `write_csvs.py`

After aggregation I deleted the raw issue and label-event dumps for the two private repos. I also redacted their workspace paths, ticket numbers and session IDs in `codex_*.ndjson` and `claude_projects.json`. To re-run `gh_stats.py` or `label_stats.py` for them, fetch the raw data again.

GitHub fetch commands are in sections 2 and 3. All GitHub calls used REST as `its-everdred`
(about 460 core calls). There were no GraphQL calls, apart from one `rateLimit` probe
(4,947 remaining).
