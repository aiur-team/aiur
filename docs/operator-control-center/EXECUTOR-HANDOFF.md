# Executor Handoff — Operator Control Center wave

This document hands off the **Executor** role driving the OCC (Operator Control Center)
build to the next agent. Read it top to bottom before touching the fleet. It captures the
role, the full current state, the merge mechanics, the operational playbook, the hard-won
diagnoses, and the exact next steps.

Snapshot time: **2026-07-12 ~17:00 PT**. Repo: `its-everdred/aiur`.

---

## 0. Who you are: the Executor

The **Executor** is the human-or-agent driving an `aiur` run — not a passive monitor. You:

- **Make every PR merge-ready.** Run correctness + adversarial review (dual CE review,
  front-loaded in parallel), adjudicate findings, and get the PR to green + reviewed.
- **Do the merging yourself** (agents don't merge). You are the merge authority.
- **Keep agents genuinely working.** Catch stalls, wedges, and unoptimized behavior; unsnag
  anything that breaks aiur's ability to create or run agents. **You are always the fallback**
  — when an agent can't finish the last mile, you finish it (hand-fix code, push its commits,
  restart it).
- **Curate the backlog.** File tickets for bugs and bottlenecks; pull in and unblock work.
- **Own decisions.** You are the decision authority on IRE's noisy attention flags and on
  operational forks — use judgment, decide, and record it; only escalate product/scope/
  irreversible calls to the developer.

Prime directive: **loop until every ticket we care about is merged and all orchestrator +
OCC work is in `main`, proven working in the running app.**

---

## 1. Standing goal (the 5 clauses)

1. **Epic 1 — triage (DONE):** the open backlog was triaged; obsolete/pre-V2 tickets closed;
   the first `aiur` runs as a standing regression watch on the post-V2 refactor.
2. **Epic 2 — ship the OCC (MAIN GOAL):** decompose PR #971's plan into codex-sized tickets,
   ship them. Backend first → OCC-4 UI → **OCC-10 integration capstone LAST**. The UI must
   **connect to the real backend** (DecisionStore / DecisionProjection / DecisionMetrics /
   fleet state), not render mock data. Fold the docs-rebrand work into the wave.
3. **Fleet on codex 5.6 sol:max**, with `.aiur/config` auto-fallback to Claude on real
   rate-limit exhaustion. Switch manually only if the fallback doesn't fire. Track **real CPU**
   (`vmstat` id%), not the lag-inflated 1-min load.
4. **Executor role** (see §0): dual review, you merge, you're the fallback, you file tickets,
   you're the decision authority.
5. **Stop condition:** every OCC + orchestrator ticket merged to `main`, OCC proven in the
   running app.

---

## 2. Full current state

### 2a. Merged to `main` — the entire OCC BACKEND is done ✅

`main` HEAD is `3bbc064a` (OCC-8). All eight backend tickets are merged:

| Ticket | What | PR |
|---|---|---|
| OCC-1 | decision domain + persistence + projection | #1017 |
| OCC-2 | project attentions into decisions | #1021 |
| OCC-3 | answer dispatch + delivery correlation | #1027 |
| OCC-5 | fleet-state expansion (explicit waiting reasons) | #1014 |
| OCC-6 | decision history + outcomes | #1025 |
| OCC-7 | supervising-agent autonomy + decision API | #1038 |
| OCC-8 | durable decision revisions | #1038 |
| OCC-9 | decision latency metrics | #1023 |

Plus OCC-0/#988 (auto codex→claude fallback) and the planning/docs PRs (#1006/#1011).

### 2b. In-flight — OCC-4 UI (`#987` / PR #1037) — THE LONG POLE

- Branch `aiur/987-occ-4-operator-control`, HEAD `1fe78323`, base `main`, MERGEABLE.
- **Structurally correct and review-passed:** real componentized LiveView modules under
  `src/lib/aiur_web/components/operator_control_center/` (overview, decision_inbox,
  decision_card, decision_detail, fleet_table, history, recent_outcomes, decision_action,
  decision_revision_action, lifecycle_components, agent_log_modal) + `control_center_presenter.ex`,
  `dashboard_live.ex`, `decision_commands.ex`, `decision_events.ex`. A 4-lens review
  (correctness + adversarial + backend-wiring + agent-native) **confirmed it is wired to the
  real backend with no mock data, XSS/CSRF-safe, and agent-native**.
- The **final responsive design** (mobile card layouts) was imported from the Claude design
  project and landed (`f996d396`).
- **Must-fixes from review — status:**
  - ✅ **Enrichment-history bug FIXED** (`1fe78323`): `persist_enrichment/4` in
    `decision_store.ex` was the only audit-append path missing the `recent_audit` companion;
    added `recent_audit: remember_recent_audit(state.recent_audit, event)` so `:enriched`
    events show in the dashboard history + `/observability`.
  - ⬜ **/observability default** (fast-follow): `DecisionHistory.list/1` still defaults to the
    bounded `recent_audit_history(50)` window, which changes the public `/observability`
    `decision_history` field from full-history. Fix: keep `list/1` default = full history;
    have the dashboard pass an explicit bounded option.
  - ⬜ **`DecisionAction.answer_label/1`** needs a catch-all clause returning `"Unavailable"`
    (crashes the LiveView on a malformed answer today).
  - ⬜ **Answer idempotency key** isn't reset on the error path in `decision_commands.ex`
    (blocks resubmitting a changed answer after a transient failure).
- **`#987` is currently PAUSED** by the Executor (it had finished the design + moved to
  finalizing the PR body without doing the must-fixes). Resume it to do the 3 remaining
  fast-follow fixes, or hand-fix them yourself, then **merge to `main`**.
- The remaining fast-follows are also filed as review findings — they are display/observability/
  robustness, not core-flow correctness, so the UI may merge with them as fast-follows if speed
  is paramount. Executor's call.

### 2c. Remaining OCC tickets

| Ticket | What | State |
|---|---|---|
| **#1026 OCC-10** | integration capstone — wire UI actions to OCC-3/7/8/9 end-to-end + prove it | **NOT STARTED — must be LAST**, gated on #1037 merging |
| #1033 | docs: document the dashboard page + fill doc gaps (screenshots, example data) | held until dashboard done |
| #1034 | rename the aiur-driver role `operator` → **`Executor`** across code/docs | open |

### 2d. Bottleneck-fix PRs — ALREADY BUILT, under review

These fix the last-mile tax (§5). Merging them + a daemon rebuild makes the rest of the wave
run without wedging:

| PR | Fixes | State |
|---|---|---|
| **#1039** | P1 bootstrap-race (workspace checkout wiped mid-turn) | green + MERGEABLE, in review |
| #1036 | P1 coordination-RPC hang (bound tool latency) | needs CI |
| #1046 | require explicit dependency unblock signal | test failing |
| #1045 | AIMD recovery speed | green + MERGEABLE, in review |
| #1042 | post-planning stall diagnosis (spike) | green + MERGEABLE, in review |
| #1047 | bound dashboard decision projection | green + MERGEABLE, in review |

A dual-review workflow was running against #1039/#1045/#1042/#1047 at handoff — check its
verdicts, then merge the ones marked `merge`/`merge_with_nits`.

### 2e. Other open follow-ups / bottlenecks

`#1043` (bound projection — has PR #1047), `#1044` (dashboard-writable auth hardening, in
rework), `#1049` (large claude_design MCP results overflow the codex inline cap — see §5),
`#1024/#1028/#1029/#1030/#1031/#1032` (stall/finalization-wedge/AIMD/bootstrap/coord-RPC/emit —
most now have the PRs in 2d), `#728` (claude-backend agents lack coordination tools),
`#1022` (docs rebrand).

### 2f. Fleet & config (`.aiur/config`)

- **Routing: all 5 tiers = `codex:gpt-5.6-sol:max`** (heaviest codex 5.6, max effort). The
  operator directive is to keep codex 5.6 (sol/terra) as the default. Auto-fallback (#988) is
  merged and active — it handles REAL exhaustion; don't pre-empt it.
- `base_branch: main` (changed from `v2` this session — see §3). `WorkflowStore` hot-reloads
  `.aiur/config` every ~1s, no restart needed.
- Throughput dials: `max_concurrent_agents: 16` (runtime-capped to **9** via `set max-agents`),
  `max_concurrent_builds: 2` (the real CPU protector), `mix_scheduler_cap: 4`,
  `max_load_average: 5.5`, `target_load_average: 4.5`, `pre_warmed_sessions: 3`.
- Box: 12 cores. At handoff ~80% idle with only 3 agents working — **lots of headroom**;
  dispatch more of the backlog in parallel.

---

## 3. Merge model & mechanics

- **Base is now `main`.** New agent branches base off `main`; **merge PRs directly to `main`**.
  (The old model routed through a `v2` integration branch, then fast-forwarded `main`; `v2`
  and `main` were kept identical and `v2` is now retired. Any PR still based on `v2` is fine to
  retarget to `main` — they were identical at the switch.)
- **Merge command:** `gh pr merge <n> --repo its-everdred/aiur --squash --admin` (use
  `gh pr ready <n>` first if it's a draft). `--admin` merges past the known **SlotPolicy flake
  #506** (`Aiur.Opencode.SlotPolicyTest grow_slot/1 ceiling`, seed-dependent, unrelated to OCC).
- **ALWAYS verify `base == main` before merging.** OCC agents build **stacked PRs** (a PR's base
  is often another feature branch, not `main`). A mis-based `--squash` lands the code into the
  wrong branch silently. Gate every merge:
  ```
  gh pr view <n> --json baseRefName --jq '.baseRefName'   # must be main
  git merge-base --is-ancestor origin/main origin/<branch> && echo REBASED || echo STALE
  ```
  A green PR can be green against a **stale base** — rebase (via
  `gh api -X PUT repos/its-everdred/aiur/pulls/<n>/update-branch`, which does a clean 3-way
  merge and re-runs CI) before merging, or it regresses the just-merged dependency.
- **Shared-file rebase cascade:** OCC-3/6/7/8/9 all touch `src/lib/aiur/decision_store.ex`, so
  they serialize — each must rebase on the prior before merging. Confirm `git merge-tree` shows
  0 conflict markers before trusting a 3-way merge.
- **v2 merges don't auto-close issues.** After merging, `gh issue close <n>`.
- After merging, **verify the squash actually landed on `main`**:
  `git log origin/main` contains the commit, `git rev-list --count origin/main..origin/<branch>`
  is 0.

---

## 4. Operational playbook

Control the fleet with `scripts/aiurdev`:

- `scripts/aiurdev agents` — STATE / RUNTIME / ACTIVITY per agent.
- `scripts/aiurdev status` / `--bg` — daemon status / background launch.
- `scripts/aiurdev set max-agents N` — runtime cap (raise into idle CPU, lower on thrash).
- `scripts/aiurdev pause <id>` / `resume <id>` — cooperative pause (parks at next turn
  boundary; a truly wedged turn streams past it).
- `scripts/aiurdev message <id> "<text>"` — **inject a turn trigger** into the agent's native
  queue. This is how you unstick an idle/paused agent; `resume` alone re-pauses. Avoid shell-
  special chars (backticks/`$`/parens) in the message — store it in a variable.
- `scripts/aiurdev alerts --needs-attention` — attention flags.

**Fallback patterns (you are always the fallback):**

- **Message-unstick:** a paused/idle agent that isn't converging (frozen HEAD, no file edits,
  not load-throttled, not attention-flagged) needs a `message` to trigger a real turn.
- **Finalization-wedge push:** an agent that committed but won't `git push` — push its work
  yourself: `cd ~/code/aiur-workspaces/its-everdred/aiur/<id> && git push origin HEAD:<branch>`.
  Safe when the tree is clean; the agent's later push is a no-op.
- **Hand-fix the last mile:** when nudges fail, take over. **Use a clean git worktree, never
  the agent's live workspace and never the main working tree** (the main tree holds the live
  `.aiur/config` — never `git checkout`/`stash`/`reset` it):
  ```
  git fetch origin <branch>
  git worktree add --detach /tmp/fix origin/<branch>
  # edit, then:
  cd /tmp/fix && git -c user.name='its-everdred' -c user.email='<email>' commit -am "<msg>"
  git push origin HEAD:<branch>
  git worktree remove /tmp/fix
  ```
  Verify Elixir edits with `elixir -e 'Code.string_to_quoted!(File.read!("<f>")); IO.puts("OK")'`
  before committing. Run `make lint` (= `make fmt-check` + credo `--strict`) before pushing.
- **Restart a wedged agent:** pause it (or it restarts at the 4h duration cap / via the stall
  watchdog). A restart is **branch-safe** — the checkout logic re-fetches the existing remote
  ticket branch (`checkout.ex`: "prefer it over a fresh base branch"), so no committed work is
  lost; only the current unproductive turn dies. A fresh thread clears a bloated/looping one.
- **Front-load review with the `Workflow` tool** — parallel dual-CE review (correctness +
  adversarial) per PR, adjudicate, merge. See §7.

---

## 5. Diagnosis knowledge — the last-mile stalls

Agents reliably do the hard part (the feature) then lose 10–30 min each on the mechanical last
mile. Root cause is a cascade from one bug, plus independent wedges. All are now filed WITH
fix-PRs (§2d):

- **#1030 bootstrap-race (P1, root):** on the `todo→in-progress` label transition the workspace
  bootstrap replaces/removes the git checkout **beneath a running turn**, so the agent burns
  10–30 min restoring + cold-rebuilding. Hit all 5 OCC agents. Fix: PR #1039.
- **#1031 coord-RPC hang (P1):** `aiur_declare_blocker`/`emit_event` do synchronous disk-backed
  work on the tool path; under the bootstrap storm the reply hangs/times out (side-effect still
  lands). Agents re-attempt, fall back to raw `gh`. Fix: PRs #1036/#1046.
- **#1024 post-planning stall:** an agent finishes a planning turn then freezes ~1h (not load-
  throttled, not attention-flagged); only `message` recovers it. Suspects: `stall_timeout_ms`
  (60 min == the observed stall) and the daemon turn re-trigger path. Diagnosis PR #1042.
- **#1028 finalization-wedge:** commits but never `git push`. Fix: push it yourself, or the PR.
- **#1029 AIMD re-ramp too slow:** after a load backoff the envelope re-grows ~1 agent/poll,
  leaving the box 60–83% idle with queued work. Fix: PR #1045.
- **#1049 large-design MCP overflow:** the `claude_design` MCP returns the full design HTML
  (~144–183 KB) inline, which **overflows the codex agent's inline tool-result cap** → the
  agent can't ingest it, retries, and (on a bloated thread) wedges into a CI-poll loop. This
  wedged two `#987` sessions. **Workaround that works:** a fresh-thread session fetched the
  design to disk via an authenticated `claude --print` writable session, then read it from
  disk. If you hit this, restart the agent (fresh thread) or stage the design on disk for it.

**Thrash ceiling:** ~8–11 concurrent agents thrash the 12-core box (load 20+, 0% idle).
`max_concurrent_builds: 2` is the key protector. After a backoff the AIMD envelope re-ramps
slowly. Track **real CPU** (`vmstat 1 2` id%), not the 1-min load.

---

## 6. Critical gotchas — do NOT repeat these

- **Codex rate-limit `%` is USED, not remaining.** The `rate limits updated: primary N% / Mm`
  line in agent activity is percent of the window **used** (`M`=window minutes; `10080m`=weekly,
  `300m`=5-hour). A LOW number is HEALTHY. The codex dashboard ("Weekly usage limit: X%
  remaining") is authoritative. (An Executor misread `5% used` as `5% left`, wrongly diagnosed
  exhaustion, and switched routing to Claude — the dashboard showed 92% remaining. Reverted.)
  Only switch off codex on REAL exhaustion (used% near 100 or an explicit `usage_limit` error).
- **Verify `base == main` before every merge** (stacked PRs — see §3). A mis-based `--squash`
  silently lands in the wrong branch. (An Executor merged OCC-7 into OCC-8's branch this way,
  then had to recover.)
- **A green PR can be stale-green.** Always run the `--is-ancestor` gate (§3).
- **Never edit `src/test/aiur/regression/`** (protected characterization tests).
- **Never `git checkout`/`stash`/`reset` the main working tree** — it holds the live
  `.aiur/config`. Use worktrees for hand-fixes.
- **Commits & PR descriptions: no AI/model/"generated with" mentions, no attribution trailer.**
  Commit messages are 3–7 word imperative.
- **Drive rework via `gh issue comment`** (issue_comment), NOT `gh pr review` — a formal review
  neither flips the ticket nor is read by the agent. Post durable directives as issue comments;
  ephemeral `aiurdev message` queue entries are wiped on a restart.
- **`gh pr/issue edit` fails on the classic-Projects GraphQL error** — patch labels via REST:
  `gh api -X POST/DELETE repos/its-everdred/aiur/issues/<n>/labels`.
- **Watcher heuristics false-alarm.** "No commit in N min" ≠ stuck — an agent may be editing or
  in a review phase. Distinguish stuck (no commits AND no file edits AND no log activity) from
  working-but-quiet. The definitive success signal is the **push**.

---

## 7. Review discipline

Every PR gets dual CE review before merge, front-loaded in parallel via the `Workflow` tool:
`compound-engineering:ce-correctness-reviewer` + `ce-adversarial-reviewer`, each diffing the
PR against its merge-base, returning findings ranked by severity + a merge recommendation. For
UI, add a **backend-wiring/no-mock audit** and `ce-agent-native-reviewer`. Adjudicate: only
`must_fix_before_merge` blocks the merge; downgrade display/observability/robustness findings to
fast-follow tickets at your judgment. This session's reviews caught real must-fixes (the
enrichment-history bug, an "inert in production" OCC-9 feature, the /observability regression)
before merge — hold that bar.

---

## 8. Concrete next steps (in order)

1. **Finish OCC-4 UI (#1037).** Resume `#987` (or hand-fix in a worktree) to land the 3
   fast-follow must-fixes (§2b): /observability default, `answer_label/1` catch-all, idempotency
   reset. Then confirm `base == main` + green CI + `--is-ancestor`, and **merge to `main`**;
   `gh issue close 987`.
2. **Merge the reviewed bottleneck fixes** (§2d) — start with **#1039** (bootstrap-race). After
   merging the orchestrator fixes, **rebuild + relaunch the daemon** so the running fleet picks
   them up (they only take effect on restart) and the rest of the wave runs tax-free.
3. **Dispatch OCC-10 (#1026) — the capstone, LAST.** Wire the UI actions (answer/revise/enrich)
   to the OCC-3/7 dispatch + decision API end-to-end and prove it in the running app. This is
   the gate for Clause 5. Consider Claude Opus for this one ticket if codex wedges on the
   integration — it's the hardest.
4. **Docs:** #1033 (dashboard docs + screenshots + example data), #1034 (`operator`→`Executor`
   rename), #1022 (docs rebrand).
5. **Burn down follow-ups** into the idle headroom (§2e): #1044, #1049, #1043/#1047, #728.
6. **Loop until Clause 5 is met:** every OCC + orchestrator ticket merged to `main`, OCC proven
   working in the running app.

Keep the fleet on codex 5.6 sol:max. Track real CPU. You are the fallback — when an agent can't
finish, you finish. Merge as things land; don't batch. Good luck.
