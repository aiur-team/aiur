# HANDOFF — Running the Refactor Loop

**Start here if you are the agent running the aiur loop for the
production-readiness refactor.** This is a long, ongoing, mostly-asynchronous
refactor executed across many phases. You may be a fresh agent with no memory
of prior iterations — **this document, the GitHub issues/PRs labeled
`refactor`, and the `v2` branch are your memory.** Read this fully, detect
where things stand, do the next unit of work, report.

The plan behind all of this is in `docs/refactor/00-overview.md` and the five
companion docs. This handoff is how to *operate*; those are what to *build*.

---

## Current handoff — 2026-07-07 PDT

**Mode:** Phase 0 blocker recovery. Normal Phase 1 refactor execution is
paused until #768 is fixed or the external Codex usage-limit condition is
explicitly cleared. Aiur is stopped; do not restart the fleet just to probe the
state while this blocker is active.

**Immediate next unit:** finish #768, "Codex `{:error, :unavailable}` /
usage-limit failures should pause agents instead of crashing or retry-looping."
This is a Phase 0 fleet fix, so the PR targets `main` first. After it lands,
pull `main` back into `v2`, run a full `make ci` from `src/`, rebuild with
`scripts/aiurdev build`, then resume Phase 1 with
`scripts/aiurdev --bg --debug`.

**#768 local work already started:** branch
`fix/768-codex-unavailable-pause` from `origin/main` exists in the local
worktree `/private/tmp/aiur-768-main` if that worktree is still present. The
patch was not pushed when this handoff was written. It changes
`AgentRunner`, `Orchestrator`, and `AgentControlCLI` so
`{:error, :unavailable}` is normalized into a paused agent state, with watch
output like `paused: Codex unavailable`. Focused tests and
`mix compile --warnings-as-errors` had passed; before committing, rerun the
format/diff checks and decide whether to run full `make ci`.

Commands already verified for that #768 patch:

```bash
cd /private/tmp/aiur-768-main/src
mise exec -- mix test test/aiur/agent_runner_test.exs --seed 0
mise exec -- mix test test/aiur/agent_control_cli_test.exs --seed 0
mise exec -- mix test test/aiur/orchestrator_status_test.exs --seed 0
mise exec -- mix compile --warnings-as-errors
```

**Evidence:** the stopped Phase 1 run logged app-server usage exhaustion
(`credits.hasCredits=false`) and `AgentRunner` `{:error, :unavailable}`
failures under `~/.aiur/logs/20260707T222706Z-96561`. Local account checks
showed `codex login status` as logged in through ChatGPT, while
`codex doctor --json` did not expose a quota meter; the operator reported the
dashboard showed 5-hour usage limit at 0% remaining.

**Open PRs while paused:**

- #749 / #735: draft PR for RepoBase base-branch work. Leave paused until
  #768 is handled.
- #755 / #739: open PR with request-changes review. The agent is paused and
  should address the review after #768 is handled.

**Model labels:** the default planning rule is that complexity labels select
the backend, but the operator later applied `model:codex` to Phase 1 tickets
after Claude agents appeared rate-limited. Do not strip those current labels
while the run is paused unless the operator explicitly changes that direction.

**Shelved Phase 1 state:** see `docs/refactor/status.md` for the authoritative
issue table. In short, #736/#738 are done, #735/#739/#740-#744/#748 are
paused, and #745-#747 remain undispatched. Do not remove `agent:paused` from
those issues until the blocker is handled and the intended sub-run is ready.

**Ticket docs:** later ticket docs have not all been written. Create and work
only the phase tickets whose `docs/refactor/tickets/T-*.md` files exist and
are issue-ready. Do not dispatch planned later tickets simply because they are
mentioned in an index.

---

## 1. Orient in five minutes

1. Read this handoff top to bottom.
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
- **All normal refactor work targets `v2`, never `main`.** Main is untouched
  until the finished `v2` is validated by the human. The only current
  exception is **Phase 0**: fleet-unblocking bug fixes (#617, #752, #753,
  #754, #756, #764, #765, #768) target `main` first because aiur itself is
  blocked.
- **Every refactor issue carries the `refactor` label** plus `phase:N` and
  `complexity:N` (1–3). By default, do not pre-apply `model:*` routing
  overrides; complexity labels drive backend selection. The current Phase 1
  labels are an operator-directed exception because Claude agents appeared
  rate-limited. **Only the currently active sub-run receives `agent:todo`, and
  only `refactor` issues ever receive `agent:todo`** (that is the only thing
  keeping the loop from grabbing unrelated work — the tracker has no
  extra-label filter). Today there are zero stray `agent:todo` issues; keep it
  that way.
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
   opening a full-width phase. The canary also verifies the
   comment→`agent:rework` path: post a review comment as a code-owner and
   confirm the agent reworks and repushes.

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
checklist green → verify the phase's features (§7), review the just-merged
phase against the next phase's ticket docs, refresh any stale ticket details,
then open the next phase; all phases done and full sweep green → hand off
`v2` to the human for the merge to main.

## 5. The loop — one phase pass

You own PR review and merge; the human does not gate the per-phase loop.

1. **Build & run:** `scripts/aiurdev build`, then launch aiur in background +
   debug (see §10). Agents pick up this phase's `refactor` `agent:todo`
   issues.
2. **Review PRs as they open:** for each PR against `v2`, run `ce-code-review`.
   Leave review comments **as a code-owner account** so the IRE comment
   listener flips the ticket to `agent:rework` and the agent pushes fixes
   (proven working — review→rework→merge). Iterate until the PR meets the bar:
   green `make ci`, characterization tests unmodified, scope respected, no
   feature removed, touched Inventory-IDs still behave.
3. **Merge when ready:** merge each approved PR into `v2` one at a time
   (update-branch + fresh CI before each).
4. **Close the phase (or most of it):** once the phase's PRs are merged,
   `scripts/aiurdev build` again from the updated `v2`, then restart aiur for
   the next phase. The fresh run both begins phase N+1 and live-verifies that
   phase N's merges caused no regressions (scoped per-phase verification, §7).
5. **Refresh next-phase tickets:** before opening or dispatching the next
   phase, the operator agent reviews the full diff made by the phase that just
   landed and re-reads the next phase's `docs/refactor/tickets/T-*.md` files.
   Update those ticket docs when the code they cite has moved or changed
   shape — for example, stale line ranges, renamed functions, new helper
   boundaries, revised acceptance checks, or dependencies affected by the
   previous phase. The goal is that a fresh executor sees ticket details that
   match the current `v2`, not the pre-phase code.
6. **Record & report:** append a dated entry to the progress log (§12);
   report status; re-emit the restart goal (§11).

Throughout, attend to red `v2` (halt-and-repair, §9) and stalled agents (no
workpad update ~15 min → pause for operator routing/capacity adjustment).

## 6. Ticket and issue conventions

- **Ticket docs:** `docs/refactor/tickets/T-*.md`. Fields: Phase, Depends-on,
  Labels (`agent:todo refactor complexity:N`), Files,
  Inventory-IDs, Characterization-tests (risky tickets), Problem/context,
  Scope (exact), Out of scope, Acceptance criteria, Verification (Agent gate
  = `make ci` from `src/`, plus the website gate for `website/` tickets;
  At-merge = the named `Check:` probes + any TUI checks). PR base = `v2`
  for normal refactor work, or `main` for Phase 0 fleet blockers.
- **Ticket numbering & phase visibility:** `T-NNN` files are numbered in
  phase-then-dependency order (T-001 = first phase-1 ticket), and each ticket
  states its **Phase** prominently. The backlog reads top-to-bottom in
  execution order.
- **Write-before-open phase gate:** only create GitHub issues for the phase
  you are about to run, and only from ticket docs that already exist. Later
  phase ticket docs may still be incomplete (currently the planned backlog
  index mentions `T-031`–`T-039` and `T-045`, but those files have not yet
  been written). Do not create, label, dispatch, or work those planned tickets
  until their issue-ready `docs/refactor/tickets/T-*.md` files exist.
- **Issue creation** (successor-agent job, per `00-overview.md`): create
  **oldest-first in phase then dependency order** so the lowest issue numbers
  are worked first (creation order = execution priority); every issue gets
  the `refactor` label and a `phase:N` label; rewrite `Depends-on: T-NNN` to
  real issue numbers from your own creation log; verify the T-id→number
  mapping before applying `agent:todo`.
- **Delayed-open:** a dependent's issue is created only after its blocker
  merges to `v2`. Single-file decomposition chains run as serialized
  sub-waves (open wave N+1 only after wave N merges).
- **Sub-run dispatch cap:** a phase may be split into smaller sub-runs when
  the operator's current capacity is lower than the phase width. It is OK for
  later sub-run issues to exist without `agent:todo`; add that label only when
  you are ready for aiur to claim that sub-run. With the current local
  operator setting of `agent.max_concurrent_agents: 8`, Phase 1 should run as
  Sub-run A (small safety/platform fixes plus the opencode warm-pool cap fix)
  and Sub-run B (the heavier characterization tickets), rather than opening
  all Phase 1 work at once.
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
  to restore the fleet directly, then record it. Phase 0 backstop fixes go
  to `main`; after they land, pull `main` back into `v2` before resuming
  normal refactor work.
- **Catastrophic:** if the fleet is unrecoverable and you cannot make
  progress, stop and report to the human — do not thrash.

## 10. Running aiur

**Review the `aiur-loop` and `aiur-run` skills before your first run.**
**Run `scripts/aiurdev build` before every background+debug launch or restart
(including after pause/resume), and after merging a phase's PRs** — aiur runs
on the very code being refactored, so the release must be rebuilt to include
the latest `v2` changes (and to verify them). Never (re)start the fleet
without building first.

Launch the background loop with:

```bash
scripts/aiurdev --bg --debug
```

Do not use `aiurdev run --bg --debug` for the background loop. That command
routes through the foreground run case in the shared engine and is tracked as
a bug ticket. Use `aiur-monitor` / `scripts/aiurdev watch` for status;
`scripts/aiurdev set max-agents N`, `scripts/aiurdev pause`,
`scripts/aiurdev resume`, and `scripts/aiurdev stop` to control it. Config is
`.aiur/config`. Keep runs observable and stop idle real-agent runs promptly to
control cost.

Review comments must come from a **code-owner account** (`.github/CODEOWNERS`
is the authority signal; an agent's comments on its own PR are never
authoritative) or the comment listener will not trigger `agent:rework`.

## 11. The restart goal

Each iteration is seeded by a short restart goal the human passes back. When
you receive it: read this handoff, detect state (§4), do the next unit (§5),
then report and re-emit the goal so the human can continue the loop. The loop
ends only when the refactor is complete (full sweep green, `v2` ready for
main), the human pauses it, or a catastrophic failure blocks all progress.

## 12. Human touchpoints

The human is asynchronous and appears only at defined points (set 2026-07-06):

- **Full review of the ticket backlog** before any execution — the loop
  generates and presents all tickets, then stops for review.
- **Final `v2` acceptance** before the merge to main.
- On catastrophic failure.

Everything else is autonomous.

---

## Progress log (append-only — update every iteration)

- **2026-07-06** — Prep complete: `refactor` label created; `v2` branch cut
  (carries the full plan); this operating handoff written. Six planning docs +
  research artifacts committed on `refactor-planning-prompt` (PR #732). Zero
  stray `agent:todo` issues. Operator decisions locked: **full backlog
  review** before execution; **canary** (1–2 tickets) before ramp;
  **ce-doc-review runs first**. **Next unit:** ce-doc-review the six planning
  docs → apply fixes → generate the phase-labeled backlog in order → run the
  consistency script → present the full backlog for review, then stop.
- **2026-07-07** — Loop model confirmed: I own PR review (`ce-code-review` →
  comment as a code-owner → the comment listener triggers `agent:rework` →
  merge); the human's touchpoints are the full backlog review, final `v2`
  acceptance, and catastrophic failure. `scripts/aiurdev build` before every
  (re)start.
- **2026-07-07** — Phase 1 issue creation started from written docs only.
  Later planned tickets whose docs do not exist (`T-031`–`T-039`, `T-045`)
  must not be opened or worked until written. Because local capacity is 8
  agents, Phase 1 is split into sub-runs; only the active sub-run gets
  `agent:todo`.
- **2026-07-07** — Phase 1 execution paused because fleet blockers are
  preventing agents from validating, committing, pushing, and shelving work
  reliably. Current state and restart notes live in `docs/refactor/status.md`.
  New **Phase 0** blocker issues (#617, #752, #753, #754, #756) are labeled
  `refactor phase:0` and should target `main`; after they land, pull `main`
  back into `v2`, rebuild aiur, and resume Phase 1.
- **2026-07-07** — Phase 1 restarted after #617/#752/#753/#754/#756 landed,
  then stopped again when active tickets were moved to `agent:error` without
  retry-exhaustion logs. New Phase 0 blockers #764 and #765 were created
  without `agent:todo`; dispatch them only after the blocker workflow target is
  explicitly `main`.
- **2026-07-07** — Phase 0 blockers #764 and #765 landed on `main`, were
  pulled into `v2`, and `v2` passed `make ci` at `ad0d17f`. Dogfood config and
  hooks were retargeted to `v2`, then Phase 1 relaunched for #735/#748 only.
  The run was stopped after Codex app-server reported `credits.hasCredits=false`
  and agents hit `{:error, :unavailable}` / stall retry churn. New Phase 0
  blocker #768 tracks pausing unavailable Codex turns instead of crashing or
  retry-looping. Current issue/PR state lives in `docs/refactor/status.md`.
- **2026-07-07** — While aiur stayed stopped for #768, reviewed Phase 1 PRs
  were landed one at a time: #751 closed #738 at `88cc2de`, and #757 closed
  #736 at `3ea2f17` after a rework fix restored `:log_file` in
  `IssueLogEventHistoryTest`. `v2` passed full `make ci` from `src/` after
  each merge; #757 also passed the two-seed at-merge isolation probe with
  `ISOLATED`. Remaining blockers: #768 before dispatching more Phase 1 work,
  #755/#739 paused rework, #749 draft, #735/#740-#744/#748 paused.
- **2026-07-07** — `RUNBOOK.md` was renamed to `HANDOFF.md` and expanded with
  the current Phase 0 blocker state so a fresh operator can resume from #768
  without replaying the whole session. Keep `docs/refactor/status.md` as the
  detailed issue/PR table and this file as the operating entry point.
