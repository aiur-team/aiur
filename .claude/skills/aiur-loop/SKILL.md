---
name: aiur-loop
description: "Use when running aiur to continuously improve a repository with its own agents — and you'll stay involved in curating tickets and reviewing/merging the resulting PRs rather than just launching it. Repo-agnostic (works in whatever repo it's invoked from). Triggers: 'run the aiur loop', 'improve this repo with aiur', 'keep aiur working the backlog until done', or a /goal handoff continuing such a run."
---

# Run the aiur improvement loop

A repo-agnostic wrapper around `aiur-run`. It doesn't just launch aiur — it drives a sustained
improvement loop in **whatever repo you invoke it from**: curating the `agent:todo` backlog,
keeping agents fed, and staying involved in review/merge at the level the developer chooses.

**REQUIRED SUB-SKILLS:** `aiur-run` owns the actual launch + lifecycle (pre-flight, build,
prewarm, `--bg`, pause/resume/stop). `aiur-monitor` owns the per-agent status read. This skill
orchestrates them into a loop — it does not duplicate them.

## Step 0 — Ask the developer their involvement (FIRST, every session)

Do NOT assume the developer wants the agent to do all the reviewing and merging. Before
launching anything, ask (AskUserQuestion) and record the answers for the whole session:

1. **Scope** — which tickets/issues are in scope? (a specific list, a label, "all open
   `agent:todo`", or "you curate them"). If you curate, ask what to prioritize (bugs,
   stability, a feature area).
2. **Ticket creation** — should you continuously file NEW `agent:todo` tickets as you find
   work, keeping the queue fed, or only run the existing set? Any limits (stability-only, no
   features, max N)?
3. **Review involvement** — per incoming PR: do you run a code/CE review and comment, do you
   review and the developer reads, or does the developer review themselves?
4. **Merge authority** — who merges? (you merge when CI-green + review addressed / you propose
   and the developer merges / never merge without explicit OK)
5. **Self-fix** — may you take a ticket yourself (CE brainstorm→plan→work→review, or
   debug-first) when an agent is stuck or a fix is complex + important, or always route to agents?
6. **Cadence & concurrency** — **ASK the status-update interval** (offer 5 / 10 / 15 min;
   **default 5 minutes** if they don't specify). Whatever value they pick feeds the **REQUIRED**
   auto-cadence from `aiur-monitor` (not optional) and is recorded once for the session — the
   operator never re-asks. Also ask starting agent count and willingness to ramp concurrency up
   as load allows.

When unspecified, default to the LESS autonomous option and confirm before merging or filing
tickets the developer didn't authorize.

## The loop (run per the Step-0 answers)

1. **Launch** via `aiur-run` in the current repo, **always with `--debug`** so each agent's logs
   are captured under `~/.aiur/logs` for monitoring + diagnosis. Clean slate first (no stray BEAM,
   dashboard port free, epmd clear) — a stale instance will grab newly-`agent:todo` tickets on old code.
2. **Monitor** with `aiur-monitor`. This is REQUIRED, not optional: while the run is live you
   **MUST** post a fresh board (run `aiurdev watch`) every `<the operator's chosen interval>`
   automatically (the `/loop <chosen>m` interval — **default 5 minutes** if unset; "approximately"
   is not license to stretch it past the chosen interval; the operator should never have to ask;
   don't skip a tick when steady — see `aiur-monitor`'s required "Monitoring cadence"). Use the
   interval the operator chose in Step 0 (question 6); the cadence stays automatic and unprompted
   regardless of the value — never let an operator-set interval become "post only when asked."
   Watch for bugs, stuck agents, CPU/FD. **Post each tick as two markdown tables, not prose** —
   **Table 1** the full refactor roadmap (`Ticket | Description | Phase | Status`, one row per
   ticket through the end: merged ✅ / active 🔵 / upcoming ⬜, contiguous done runs collapsible)
   and **Table 2** the optimization/bottleneck backlog (`# | Description | Status`, flagging the
   top blocker). Full spec: `aiur-monitor`'s "Progress-update format (required — two tables)".
   Short shape:

   ```
   ## Table 1 — Refactor tickets
   | Ticket | Description | Phase | Status |
   |---|---|---|---|
   | T-001–T-021 | Phase 1 safety-net + Phase 2 core seams | 1–2 | ✅ all merged |
   | T-024 | orchestrator: comment/PR paths | 3 | 🔵 #851 todo |
   | T-025 | orchestrator: sync subscriptions | 3 | ⬜ upcoming |
   | T-036 | runner: streams slim | 3 | 🔵 #879 in-progress |

   ## Table 2 — Optimization / bottleneck tickets
   | # | Description | Status |
   |---|---|---|
   | #856 | Daemon hardening (scheduler cap + crash-dump) | ✅ merged |
   | #884 | Restore v2 coverage ≥85% | 🔴 in-progress — BLOCKS ALL MERGES |
   | #877 | Close the CI feedback loop | 🔵 in-progress |
   | #873 | Agents skip local credo (lint = #1 CPU) | 🟡 staged in prompt |
   ```
3. **Curate the backlog** — if opted in, file focused `agent:todo` tickets (repro + acceptance
   criteria) so aiur keeps picking up work; keep the queue fed toward the agreed scope.
4. **Review each PR** at the agreed level — typically a code/CE review with findings left as a
   **comment on the linked ticket** so the agent reworks. The first couple of times, verify that
   comment→rework loop actually fires (issue flips to `agent:rework`; agent pushes a fix).
5. **Merge** at the agreed authority (CI green + review addressed), then have the change **proven
   to work** — ideally demonstrated in the running app, not just green CI.
6. **Rebuild periodically** — pull the base branch, stop aiur, rebuild on latest, and rerun on
   the remaining/new `agent:todo` tickets, so agents dogfood the merged changes.

## Concurrency & CPU

Start at a conservative agent count and watch load (CPU, file descriptors / `:emfile`). Ramp
concurrency **up** as the box shows headroom; ramp **down** if CPU pegs or stability/quality
erodes. `aiur-run` documents the config dials (`max_concurrent_agents`, `pre_warmed_sessions`).

## Resume across sessions — /goal

When low on context, write a 2-sentence `/goal` capturing the remaining scope + the standing
intent (keep looping until the agreed work is merged and the app is verified stable), and tell
the developer to paste it back via `/goal` to continue. Update any handoff doc alongside it.

## Notes

- Merging advances the base branch; if the running aiur stops working agents on base-branch
  pushes, merge in **batches at rebuild checkpoints** rather than mid-run.
- Respect the project's own test/validation constraints (some setups block certain checks inside
  agent sandboxes) — judge PRs on the coverage that IS available, not what's intentionally blocked.
