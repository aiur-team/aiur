---
date: 2026-07-14
topic: aiur-quota-waste-reduction
---

# Aiur Quota-Waste Reduction

## Problem Frame

The Aiur fleet runs 100% on Codex under a flat $200 ChatGPT-Pro plan, so the binding
constraint is the **weekly rate-limit quota**, not dollars — quota headroom *is* fleet
throughput. Two months of `~/.codex` session logs (4,028 sessions, 252 tickets) show the
quota is burned mostly on two avoidable patterns:

1. **Cold re-runs.** A ticket averages ~16 separate cold dispatches; the worst (#1091)
   took **85**. Every new rollout is a cold Codex thread that re-pays first-turn overhead
   and — on rework — re-runs brainstorm/plan it already did.
2. **Wasted turns at heavy effort.** `gpt-5.6-terra:xhigh` is 9% of sessions but **45% of
   cost** (~20–40× the per-session cost of `gpt-5.5:high`); stuck agents stream to the
   `max_turns` cap with no progress.

This work cuts wasted turns and cold re-runs so the same plan ships more merged tickets.
It is separate from — and higher-leverage than — the four token tools (see Scope).

Full evidence: `docs/token-reduction/RESEARCH-SPIKE.md` + the empirical artifact.

---

## Actors

- A1. Aiur daemon/orchestrator: dispatches agents; re-dispatches on rework, wake, or
  restart; owns caps, watchdog, and workspace lifecycle.
- A2. Worker agent (Codex): runs one ticket turn; today re-runs brainstorm/plan on a cold
  rework dispatch.
- A3. Human Executor: monitors, reviews, and unsticks agents.

---

## Requirements

Packaged as an **epic + focused child tickets** (operator choice). R-IDs group by child.

**Epic — cut quota waste from cold re-runs and wasted turns**
- R1. The program is measured against the same `~/.codex` session analysis: dispatches per
  ticket and quota-weighted cost per merged ticket must fall versus the current baseline.

**Child T1 — Rework-continuation prompt (no cold re-plan)** *(flagship, highest leverage)*
- R2. When a ticket is dispatched in `rework` state and its Codex thread is **not** resumable
  (cold), the turn-1 prompt is a continuation-style prompt that forbids re-running
  brainstorm/plan — not the full cold `PromptBuilder` prompt. (`src/lib/aiur/agent_runner/turn_prompt.ex`, `build_turn_prompt/4` turn==1 branch, which today has only `resumed` and cold paths.)
- R3. That prompt orients the agent from durable state: it points at the existing
  `## Agent Workpad` and surfaces the unresolved review feedback, so the agent acts on the
  rework rather than re-discovering the whole ticket.
- R4. Escape hatch: the agent may re-plan if it records the reason in the workpad.

**Child T2 — Preserve Codex rollout + worktree across human-review dwell**
- R5. When a completed runner deactivates to `human-review`, its copy-on-write worktree is
  not reaped, so the Codex thread rollout stays resumable through the review dwell.
- R6. Rollout retention is bounded by a disk-safety ceiling but long enough that
  `thread/resume` hits after a multi-hour review, converting cold reworks into cheap resumes
  (compounds T1).

**Child T3 — Git-progress stall watchdog**
- R7. The runtime watchdog gains a progress dimension: between turn boundaries it samples
  commit count / `git diff --shortstat`; if the worktree does not advance across K turns
  while the Codex stream is still active, it **pauses + flags** the ticket for the Executor —
  never auto-kills (a legitimate deep-analysis turn must not be killed).

**Child T4 — Complexity-scaled turn caps**
- R8. `max_turns` (and optionally duration) become settable per complexity tier
  (`max_turns_by_complexity`), so a stuck `complexity:1` ticket caps well before a
  `complexity:5` one, bounding wasted-turn blast radius on trivial work.

**Child T5 — Deterministic affected-test selection**
- R9. A `scripts/affected-tests` helper turns a diff into the affected test files
  (`src/lib/aiur/X.ex → test/aiur/X_test.exs`, expanded via `mix xref graph --sink`,
  complemented by `mix test --stale`) and prints the exact scoped `mix test` command, so the
  agent stops spending a reasoning pass per turn choosing tests. `make ci` stays the
  authoritative full gate; the helper is validated against the known `--stale` blind spots
  (Gettext `.po`, `Application.get_env` runtime config).

---

## Success Criteria

- **Human outcome:** re-running the `~/.codex` analysis after rollout shows a clear drop in
  median dispatches-per-ticket and quota-weighted cost per merged ticket (baseline: ~16
  dispatches/ticket, #1091 = 85; `terra:xhigh` = 45% of cost).
- **Handoff quality:** each child has an observable, testable behavior — a cold rework
  dispatch yields a continuation prompt (T1); a `human-review` ticket keeps its worktree
  (T2); a stalled-but-streaming agent is flagged, not run to cap (T3); a trivial ticket caps
  sooner (T4); the test helper emits a correct scoped command (T5).

---

## Scope Boundaries

- **The four token tools** (ccusage / Serena / context-mode / caveman) — a separate program;
  caveman already dropped, Serena/context-mode are gated trials. Not in this epic.
- **Per-token pricing tricks** (Flex / `service_tier`) — verified no-op under our
  ChatGPT-subscription auth; excluded.
- **Prompt compression / semantic response caching** — down-ranked in research; excluded.
- **Changing model or provider** — out of scope.
- **Reasoning-effort tiering** is in scope only as an operator **config note**, not a child
  ticket: `.aiur/config` `agent.routing` already accepts per-tier `backend:model:effort`, so
  it is an edit + a ccusage measurement, not agent-implemented code.

---

## Key Decisions

- **Epic + focused children** over one bundled ticket: the levers are distinct kinds of
  change (prompt logic, workspace lifecycle, watchdog, config, a script) and parallelize
  cleanly across agents.
- **T1 is the flagship** — it attacks the single largest empirical waster (cold re-runs) and
  is a self-contained change to one module.
- **Watchdog pauses + flags, never auto-kills** — false-positives on deep-analysis turns are
  worse than a late flag.

---

## Dependencies / Assumptions

- `turn_prompt.ex` today has only `resumed` and cold turn-1 branches (verified) — no rework
  branch exists.
- Codex rollouts are retained on disk indefinitely today and `thread/resume` is a real
  app-server method (verified); T2 assumes `$CODEX_HOME` is a persistent path across the
  ticket lifecycle — to confirm in planning.
- `multi_agent_mode=explicitRequestOnly` → per-session token accounting is clean (verified),
  so the success-criteria measurement is trustworthy.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R3][Technical] How does the daemon get the unresolved review-thread bodies +
  workpad content at dispatch time to inject into the T1 prompt (the `build_turn_prompt/4`
  signature / `opts`, and where rework feedback already lives in daemon state)?
- [Affects R5/R6][Needs research] The exact worktree-reap trigger on deactivate-to-review,
  and whether `$CODEX_HOME` is persistent per ticket lifecycle.
- [Affects R7][Technical] `runtime_watchdog.ex` turn-boundary hooks and where to sample git
  progress cheaply.
- [Affects R9][Needs research] Validate `mix test --stale` behavior against this repo's
  Gettext usage and any `Application.get_env` config reads before trusting scoped selection.

---

## Next Steps

→ `/ce-plan` for structured implementation planning (start with the T1 flagship).
