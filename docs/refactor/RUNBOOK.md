# RUNBOOK — Running the Refactor Loop

**Start here if you are the agent running the aiur loop for the
production-readiness refactor.** This is a long, ongoing, mostly-asynchronous
refactor executed across many phases. You may be a fresh agent with no memory
of prior iterations — **this document, the GitHub issues/PRs labeled
`refactor`, and the `v2` branch are your memory.** Read this fully, detect
where things stand, do the next unit of work, report.

The plan behind all of this is in `docs/refactor/00-overview.md` and the five
companion docs. This runbook is how to *operate*; those are what to *build*.

---

## 1. Orient in five minutes

1. Read this runbook top to bottom.
2. Read `00-overview.md` (goals, deviations, conversion protocol); skim
   `phasing-and-parallelization.md` (phases, duties) and
   `regression-safety.md` (the safety net).
3. Detect current state (§4).
4. Pick the next unit of work (§5) and go.

## 2. Invariants — never violate

- **No feature removed.** `feature-inventory.md` (1,062 FI-IDs) is the
  contract. Structure changes; behavior does not.
- **`v2` is green after every merge.** Full `make ci` from `src/`.
- **Characterization tests are read-only for executors.** A CI check fails
  any PR touching `src/test/aiur/regression/` without an operator-applied
  override label. If a characterization test fails, the change is wrong — the
  executor stops and reports, never edits the test.
- **All refactor work targets `v2`, never `main`.** Main is untouched until
  the finished `v2` is validated by the human.
- **Every refactor ticket carries the `refactor` label** plus `agent:todo`,
  `complexity:N` (1–3), and `model:claude` on concurrency/persistence/timing
  work. **Only `refactor` issues ever receive `agent:todo`** (that is the
  only thing keeping the loop from grabbing unrelated work — the tracker has
  no extra-label filter). Today there are zero stray `agent:todo` issues;
  keep it that way.
- **Commits (yours and every executor's): 3–7 word imperative messages.
  Never mention the tools, models, or "generated with" in commit messages or
  PR descriptions.** (Also repo convention — `.claude/skills/using-aiur/dev-loop.md`.)
- **You own the merges.** Executors never self-merge. You own PR readiness,
  green builds, conflict resolution, at-merge checks, and phase-exit.

## 3. Execution pre-flight (once, before the first phase runs)

1. **Bootstrap `v2` enablement** (direct operator commits — backstop role, not
   loop tickets, because the loop cannot cleanly target `v2` until these
   exist): make `Aiur.RepoBase` honor `tracker.base_branch` (today
   `src/lib/aiur/repo_base.ex:28` hardcodes `@default_branch "main"` for
   clone/fetch/reset), and add `v2` to the CI `push:` branches in
   `.github/workflows/ci.yml`. Details: `research-v2-mechanics.md`.
2. **Set `tracker.base_branch: v2`** under `tracker:` in the run's
   `.aiur/config`. Notify-on-push and auto-subscriptions follow this;
   blocker-branch detection is already base-agnostic.
3. **Land the phase-1 safety net first** (the mandated Phase-1 tickets in
   `regression-safety.md` §3): characterization suite + tripwire CI guard,
   the `:log_file` test-isolation fix, the SlotPolicyTest #506 fix, and the
   website CI job. Nothing risky merges until these are in and green.
4. **Verify label separation:** `gh issue list --label agent:todo --state
   open` must contain only `refactor` issues.
5. **Ramp config:** raise `agent.max_concurrent_agents` toward the phase
   width (~10) and watch the #465 load gate (`vmstat` idle %, not loadavg).
6. **Canary:** run 1–2 low-risk refactor tickets end-to-end
   (workspace → PR → `v2` merge → CI green) to prove the pipeline before
   opening a full-width phase.

## 4. Detect current state (where am I?)

Single source of truth is GitHub + `v2`, not memory:

- `gh issue list --label refactor --state all` — the backlog. By agent
  state: `agent:todo` = queued, `agent:in-progress` = running,
  `agent:human-review` / `agent:rework` = **needs you**, `agent:merging` /
  closed = landing/done.
- `gh pr list --base v2 --state open` — PRs awaiting your merge.
- `v2` CI status (red `v2` = halt, see §9).
- The **progress log** at the bottom of this file — append-only; you update
  it every iteration so the next agent knows what you did and why.

Decision table: unreviewed backlog and the operator gate is set → stop and
present for review; PRs in `human-review` → review and merge or route to
`rework`; phase incomplete → drive it; phase complete and phase-exit
checklist green → verify the phase's features (§7) and open the next phase;
all phases done and full sweep green → hand off `v2` to the human for the
merge to main.

## 5. The loop — one iteration

1. **Re-orient** (§4).
2. **Attend to anything needing attention first:** red `v2`
   (halt-and-repair, §9), `human-review` PRs (review → merge or `rework`),
   stalled agents (no workpad update ~15 min on a codex backend → add
   `model:claude` to reroute).
3. **Advance one step:** open the next issue batch (dependency order,
   delayed-open), or merge ready PRs one at a time, or run phase-exit, or
   open the next phase.
4. **Verify** (scoped — see §7).
5. **Record:** append a dated entry to the progress log (§12).
6. **Report:** concise status — what advanced, what is next, anything the
   human must see — and re-emit the restart goal (§11) if continuing.

## 6. Ticket and issue conventions

- **Ticket docs:** `docs/refactor/tickets/T-*.md`. Fields: Phase, Depends-on,
  Labels (`agent:todo refactor complexity:N [model:claude]`), Files,
  Inventory-IDs, Characterization-tests (risky tickets), Problem/context,
  Scope (exact), Out of scope, Acceptance criteria, Verification (Agent gate
  = `make ci` from `src/`, plus the website gate for `website/` tickets;
  At-merge = the named `Check:` probes + any TUI checks). PR base = `v2`.
- **Issue creation** (successor-agent job, per `00-overview.md`): create in
  dependency order; every issue gets the `refactor` label; rewrite
  `Depends-on: T-NNN` to real issue numbers from your own creation log;
  verify the T-id→number mapping before applying `agent:todo`.
- **Delayed-open:** a dependent's issue is created only after its blocker
  merges to `v2`. Single-file decomposition chains run as serialized
  sub-waves (open wave N+1 only after wave N merges).
- **Stay-in-scope:** ticket boilerplate tells the executor to avoid editing
  files outside `Files:`. You handle any drift, conflicts, and rework at
  merge.

## 7. Verification cadence (scoped, not exhaustive)

**Do not re-check all 1,062 features on every PR.** Verify only what changed:

- **Per PR / at merge:** the Inventory-IDs that PR touches — their named
  characterization tests pass unmodified, and the ticket's `Check:` probes
  and any TUI checks pass.
- **Per phase:** at phase-exit, verify the union of features that phase
  touched (e.g., a phase that touched 10 features confirms those 10 still
  behave). This can run **while the next phase is already executing** —
  verification of phase N overlaps execution of phase N+1.
- **Full 1,062-feature sweep:** exactly once, at **final `v2` acceptance**,
  before the human's merge to main.

## 8. Phase model and duty split

Phases are aiur-loop runs (nominally 3, more is fine — the brief allows it).
Within a phase, concurrent tickets never share a file. You (the loop-running
agent) own everything between conversion and completion: open each phase's
batch, monitor, keep PRs ready and `v2` green, resolve conflicts, merge one
at a time (update-branch + fresh CI before each), run at-merge and phase-exit
checks, and use each phase's aiur run as live validation that prior phases'
merges still work. Full detail: `phasing-and-parallelization.md`.

## 9. Halt-and-repair, new issues, and backstop

- **Red `v2` or a characterization failure:** pause the loop, stop
  opening/claiming issues, open a top-priority `refactor` fix issue
  referencing the offender, amend affected downstream ticket docs, resume.
- **Dialyzer error outside a ticket's scope:** rebase `v2`, rerun; still
  failing → file a `needs-triage` finding, do not scope-creep.
- **Unforeseen bugs:** open new `refactor` issues yourself and slot them into
  a phase (same conventions, complexity 1–3 preferred).
- **Backstop:** if aiur itself becomes unusable, implement any fix necessary
  to restore the fleet directly, then record it (issue + PR into `v2`).
- **Catastrophic:** if the fleet is unrecoverable and you cannot make
  progress, stop and report to the human — do not thrash.

## 10. Running aiur

Use the `aiur-run` skill to launch and babysit the fleet; `aiur-monitor` /
`aiurdev watch` for status; `aiur set max-agents N`, `aiur pause`,
`aiur resume`, `aiur stop` to control it. Config is `.aiur/config`. Keep runs
observable and stop idle real-agent runs promptly to control cost.

## 11. The restart goal

Each iteration is seeded by a short restart goal the human passes back. When
you receive it: read this runbook, detect state (§4), do the next unit (§5),
then report and re-emit the goal so the human can continue the loop. The loop
ends only when the refactor is complete (full sweep green, `v2` ready for
main), the human pauses it, or a catastrophic failure blocks all progress.

## 12. Human touchpoints

The human is asynchronous and appears only at defined points (exact set is
operator-selected — see the progress log for the current setting):

- Review of the ticket backlog before execution (depth per operator choice).
- **Final `v2` acceptance** before the merge to main (always).
- On catastrophic failure.

Everything else is autonomous.

---

## Progress log (append-only — update every iteration)

- **2026-07-06** — Prep complete: `refactor` label created; `v2` branch cut
  (carries the full plan); this runbook written. Six planning docs +
  research artifacts committed on `refactor-planning-prompt` (PR #732).
  Zero stray `agent:todo` issues. **Not yet started:** ce-doc-review of the
  planning docs, ticket generation, execution pre-flight (§3). Operator
  review-gate setting: _pending_. Next unit: per the restart goal.
