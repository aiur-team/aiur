# Phasing & Parallelization

How 30–60 tickets execute safely with ~10 parallel agents per phase, run
end-to-end by an Opus agent acting as Executor through `/aiur-run`, merging into the `v2`
integration branch. Concrete per-ticket tables are **pass 2** (filled during
ticket generation); this document fixes the model and the rules the human
checkpoint approves. Generated 2026-07-06.

---

## The model

- **A phase = one bounded Executor run.** The Opus agent opens the phase's issues,
  runs the loop, merges PRs into `v2` one at a time, runs phase-exit checks,
  then opens the next phase. Phase count is nominally 3–5 and may grow (the
  brief's wiggle-room clause); the binding constraint is loop-runnability,
  not the number.
- **Expected shape:** Phase 1 = the safety net (characterization tripwire +
  CI guards + the six prerequisite tickets in `regression-safety.md` §3) plus
  independent low-risk consolidations (utility dedup). Middle phases =
  decomposition waves (giants) + backend seam + poller/adapter
  consolidations. Final phase = norms adoption, docs framework + pages,
  website updates, cleanup.
- Within a phase, **concurrent tickets never share a file** (`Files:` lists
  are pairwise disjoint — mechanically checked by the consistency script).

## Dependency rules

- **Delayed-open protocol:** a dependent ticket's issue is not opened until
  its blocker is merged to `v2`. This kills the branch-merge-chaining race in
  all cases.
- **Serialized sub-waves:** single-file decomposition chains (orchestrator's
  26 modules land in ~6–8 waves; each giant's waves are defined in its
  `research-arch/giant-*.md`) run *within* a phase as sub-waves — the Opus
  agent opens wave N+1's issue only after wave N merges. Sub-wave tickets are
  exempt from the disjointness check against each other (they serialize by
  construction), and each wave leaves the repo green on its own.
- Cross-phase dependencies use the same delayed-open rule; nothing else is
  permitted (no two in-flight tickets where one depends on the other).

## The arithmetic (why sub-waves, sized for the checkpoint)

The name map creates ~190 new modules from 15 giants. At one-file-per-phase
this could never fit ≤3 phases of small tickets (7,617-line orchestrator ÷ 3
tickets ≈ 2,500 lines each — not complexity 1–3 work). Sub-waves keep each
ticket at one reviewable wave (≤~400 lines moved), giving roughly: orchestrator
6–8 tickets, github client 3–4, init 3, agent_runner 3–4 (includes the seam
migration), renderer 3, codex adapter 3, pane_manager 3, app 2–3, remaining
giants 1–2 each, plus consolidation, safety-net, norms, and docs/website
tickets — landing inside the 30–60 budget. If ticket generation cannot fit
the approved model, the **re-gate rule** applies: stop and return to the
human checkpoint.

## Duty split

- **The aiur-driving Opus agent owns everything between conversion and
  completion:** opens each phase's batch in dependency order, monitors the
  fleet, ensures PRs are ready and `v2` green, resolves merge conflicts,
  merges one PR at a time (update-branch + fresh CI before each), runs
  at-merge checks (`Check:` probes + ticket-listed TUI checks), runs
  phase-exit, opens new issues for unforeseen bugs and slots them into
  phases, and holds backstop direct-fix authority if aiur becomes unusable
  (recording any direct fix as issue + PR afterward). Each phase's aiur run
  doubles as live validation that prior phases' merges work.
- **The human appears exactly twice after the planning checkpoint:** review
  of the final ticket docs before conversion, and acceptance testing of the
  completed `v2` branch before it merges to main.

## Phase-exit checklist (no partial overlap)

All phase tickets merged to `v2` (or explicitly moved to a later phase) ·
`v2` CI green · characterization suite green and unmodified (or override
label audit-trailed) · at-merge checks passed for every merged PR · no
`agent:rework`/`agent:in-progress` stragglers. **No next-phase issues open
while any current-phase ticket is unresolved.**

## Executor-fleet operations

- Complexity labels stay 1–3 (codex-class); tickets touching concurrency,
  persistence, or timing-sensitive paths pre-apply `model:claude`.
- **Quota-stall watch:** a ticket with no workpad update for ~15 minutes on a
  codex backend is presumed quota-stalled — reroute by adding `model:claude`;
  don't wait, don't lower concurrency.
- Config ramp: raise `max_concurrent_agents` toward the phase's width and
  watch the #465 load gate (`vmstat` idle %, not loadavg).
- Halt-and-repair and the dialyzer outside-scope rule:
  `regression-safety.md` §7.

## Pass-2 tables (filled during ticket generation)

- Ticket → phase/sub-wave allocation table.
- Dependency graph (mermaid) with every `Depends-on` edge.
- Per-phase `Files:` disjointness attestation (consistency-script output).
