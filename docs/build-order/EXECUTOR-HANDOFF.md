# Build Order Executor Handoff

## Current state and pre-run checklist (updated 2026-07-13)

You are the **Executor**: you run Aiur to implement this feature, make every
PR merge-ready via review, do the merging, keep agents genuinely working, and
act as the fallback when an agent cannot finish its last mile. Everything
below this section is the binding contract; this section is where things
stand and what must happen, in order, before the first dispatch.

**State right now:** the planning pack is complete, independently reviewed
(nine lenses; see `09-plan-review-synthesis.md`), reconciled, and validating
clean — canonical and publication validators both report 0 errors / 0
warnings and the 102-test publication suite passes. **No GitHub issues have
been created.** Skills PR #1065 is reconciled with `main`, fully green, and
MERGEABLE. Draft PR #1064 carries this pack.

**Ordered pre-run checklist:**

1. **Operator decisions** (see `questions.md`, "Questions for Kevin" plus the
   2026-07-13 decisions section): the **single-Build-Order consolidation is
   DONE** — one root contains every ticket (all 54 BO + DASH members) so
   agents parallelize across the whole graph; membership, denominators, and
   this handoff reflect it, and ledger question 1 is resolved as "keep — the
   accounting family is included in the consolidated graph". Still pending:
   the publication-ceremony scope, merge candidates, structural parallelism
   changes, and an /aiur-build verification owner.
2. **Merge PR #1065 into `main` first** (operator-approved 2026-07-13; the
   old wait-for-run constraint is lifted). The skills must be on `main`
   before Build Order work is dispatched. Verify `/aiur-build`, `/aiur-run`,
   `/aiur-monitor` are discoverable afterward (GATE-002).
3. **Finalize and publish** the issue graph per `github-publication.md` at
   whatever ceremony scope the operator chose. Every issue body carries the
   full ticket contract plus a "Plan context" block linking back to this
   pack at the approved commit.
4. **Record GATE-001's resolution** on the live root and prove GATE-002,
   then obtain the operator's explicit run authorization.
5. **Run Aiur** via `/aiur-run` and drive to the terminal condition.

**Read-first map for this run:** `README.md` (pack index) →
`08-implementation-pointers.md` (verified per-ticket file/module/function
anchors for all 54 tickets — workers start here, and every published issue
links its own section) → `07-graph-parallelism-review.md` (waves, critical
path, serialization cliques) → `09-plan-review-synthesis.md` (review verdict
and accepted recommendations). Day-one width is 5 tickets (BO-004, BO-008,
DASH-006, DASH-017, DASH-018 have no blockers); staff the top fan-out spine
first — DASH-003 (8 dependents), BO-008 (6), BO-004 (5), BO-017 (5), BO-005,
DASH-001, DASH-008 — a stall there starves more of the fleet than anything
else. The serial critical path is BO-004→001→002→003→007→011→012→013→014→015
(amber in the committed plan preview, `docs/build-order/plan-preview.html`);
keep it staffed continuously.

## Start gate

This handoff becomes executable only after the live Build Order root contains a
uniquely marked `aiur-build-order-reconciliation` comment linking a successful
immutable post-publication receipt whose exact commit contains all three valid
reconciliations, both external gates below are recorded as resolved, and the
user separately authorizes a run. Re-run the trusted final-comment verifier;
neither caller-supplied identity or query JSON, Git object substitution,
imported foreign history, nor a merely local/API-visible commit is a start
gate. The verifier anchors the repository to the configured GitHub origin,
fetches the exact receipt-recorded comment ID, and proves approval plus receipt
remain ancestors of the unchanged tip of the frozen branch while separately
proving approval is an ancestor of receipt. It rejects legacy graft entries in
both the worktree and common Git directories, and all authority API reads pin
`github.com` with finite timeouts. The frozen branch ref is
`refs/heads/build-order-research`. Deletion or a force-push that removes
either commit revokes this gate; never substitute `main`, a pull ref, or a tag.
Planning publication does not queue work. Until then, do not run Aiur,
implement tickets, or add `agent:todo`.

The immutable receipt and final verifier attest the publication-finalization
snapshot: all 56 issues are open and unlocked, have their receipt-bound
titles/bodies/full labels, the root has exactly 54 children, every
non-root has no children, and all 107 blockers are exact. Run that full verifier
immediately before the first execution mutation. Once the authorized run
begins, later lifecycle changes are legitimate runtime truth and do not rewrite
the receipt: gate resolution may update live issues, the skill-delivery issue
may close, and member issues may acquire `agent:*` labels. Record and resolve both
external gates while the skill issue is still open; only after both gates are
proven may the Executor close the skill issue and dispatch member work. Never close
the skill issue or add dispatch labels first and then attempt to use the now
historical OPEN receipt as though it were a fresh publication snapshot.

## Identity and objective

- Build Order: `its-everdred/aiur:build-order-dashboard`
- Plan version: 1
- Repository: `its-everdred/aiur`
- Researched commit: `9849f32963c2a65367bce565b3f5ede3777c218f`
- Approved planning commit: pending final clean review
- GitHub root: resolve live by the hidden Build Order root marker; do not trust
  a copied pending number

Deliver the consolidated 54-ticket program: the authenticated,
GitHub-planning-read-only Build Order feature plus the dashboard companion
members, all direct children of one root (operator decision 2026-07-13).
GitHub owns current plan facts; Aiur owns runtime facts. Linear #1067,
skill-delivery work and deferred findings remain outside the root and cannot
change this run's 54-member denominator or ETA.

## Required startup

1. Read these repository-relative paths in order:
   - `docs/build-order/README.md`
   - `docs/brainstorms/2026-07-12-build-order-requirements.md`
   - `docs/build-order/05-technical-decisions.md`
   - `docs/build-order/build-order.json`
   - every `tickets[].document` path in
     `docs/build-order/build-order.json` (BO-001 through BO-020 under
     `tickets/` and DASH-001 through DASH-034 under `companion-tickets/`)
   - `docs/build-order/validation-report.md`
   - `docs/build-order/github-publication.md`
2. Use `/aiur-run`, not the retired `/aiur-loop` workflow. Verify the loaded
   skill is PR #1065 commit `f92aa045` or an explicitly reviewed compatible
   successor preserving its finite-boundary, review/rework, circuit-breaker,
   and publication rules. A matching skill name is insufficient.
3. Write a three-to-five-sentence `/goal` stating that you are the Executor,
   the finite acceptance boundary, granted issue/merge authority, critical-path
   priority and terminal condition.
4. Before any execution mutation, run the receipt-bound full live verifier and
   requery repository instructions, configured integration branch, the GitHub
   root/members/blockers/full labels/open+unlocked state, active PRs, CI and
   Aiur status. Never use the planning JSON as fresher live GitHub truth.
5. Queue only approved members of the consolidated root under explicit user
   authority. The shared
   predecessor baseline is recorded as resolved (`origin/main` at
   `9849f32963c2a65367bce565b3f5ede3777c218f`), and any ticket-specific
   provider gate (GATE-003 on DASH-019, GATE-004 on DASH-013) must still be
   resolved before those tickets are pickable.

## External pre-dispatch gates

- **GATE-001 — integration baseline (RESOLVED):** the predecessor OCC run is
  complete and the baseline is resolved — `origin/main` at
  `9849f32963c2a65367bce565b3f5ede3777c218f` contains closed #1034 plus every
  accepted OCC successor. Record that resolved branch and SHA on the live
  root; do not silently implement against any earlier snapshot.
- **GATE-002 — Executor skill:** the bounded skill revision above is installed and
  `/aiur-build`, `/aiur-run`, and `/aiur-monitor` are discoverable. The separate
  human skill-delivery issue remains outside the Build Order denominator.

GATE-002 still blocks every Build Order implementation ticket; GATE-001 is
resolved but its branch and SHA must be recorded on the live root. BO-004 and
BO-008 are the independent initial nodes, and the human skill-delivery issue
is a native blocker of both so GATE-002 cannot be bypassed by another branch.
BO-001 follows BO-004 and inherits both gates transitively.

Record GATE-001's resolution and resolve GATE-002 before changing the skill
issue from its publication-finalization OPEN state. Close that issue only after the
installed bounded skill is proven, and only afterward add dispatch state to
ready BO issues under the user's execution authority.

## Authority map

- GitHub: root/member identity, title/body, planning labels, lifecycle/state
  reason and native blockers.
- Aiur: running/queued/retry/paused state, progress, active agent stage, alerts,
  events and latest evidence.
- Planning pack: approved requirements, technical decisions, ticket contracts,
  initial scheduling/conflict metadata, validation and finite boundary.
- Executor: current readiness/capacity, review/rework routing, merge policy
  under authority, recovery, status and final proof.

Unknown/stale provider data never becomes empty, ready, successful or zero.
Aiur progress, including 100%, never clears a GitHub blocker.

## Initial graph and capacity

After both external gates resolve, start BO-004, BO-008, DASH-006, DASH-017,
and DASH-018 in parallel. BO-001
and BO-017 follow BO-004. BO-002 follows BO-001; BO-003 follows BO-002; BO-005
follows BO-017. BO-003, BO-005, BO-016, and BO-019 serialize on the
application-supervision seam wherever hard dependencies do not already order
them; BO-005 also serializes with DASH-029 on observation-envelope
consumption. BO-006 follows BO-005. BO-007 follows BO-001, BO-003, and BO-005.
BO-009 follows BO-001 and BO-008; BO-010 follows BO-008 and BO-009. BO-016
follows BO-004 and owns configured-repository ticket detail. BO-019 follows
BO-005 and owns bounded sanitized recent history. BO-018 follows BO-008,
BO-016, and BO-019 and owns accessible base context. BO-011 follows BO-007 and
BO-018 and adds Build Order relationships and truthful destination links.
BO-012 follows BO-003, BO-007, BO-010, and BO-011; BO-013 follows BO-008 and
BO-012; BO-014 follows BO-008 and BO-013. BO-020 follows BO-003 and BO-012 and
serializes with BO-013/BO-014 on the shared Build Order route surface. BO-015
follows BO-006, BO-014, BO-020, DASH-023, and DASH-033.

The DASH members carry the same in-graph serialization: DASH-001 with BO-012
on the OCC route/navigation shell, DASH-023 with BO-013/014 on the Build
Order route surface, and
DASH-029 with BO-005. DASH-018/019 serialize on the Claude process-lifecycle
adapter. DASH-004/019 depend on BO-004's configured-repository identity. The
eight supervised member services—DASH-002/009/012/018/019/024/025/026—also
declare every independently ready serialization pair
against BO-003/005/016/019 on the central application supervision tree. Hard
dependencies already order the omitted pairs.

Derive current readiness from GitHub native blockers, ticket lifecycle,
declared serialization and real capacity. Phase is only a rollout/display hint.
Maximize progress against ready critical-path work, not raw active count. Do not
activate deferred findings to keep slots busy.

## Review, rework and convergence

- Review each PR against its issue contract, decisions and current base. Use
  parallel independent code review where useful.
- Return a contained finding to the same ticket/worker through rework and the
  event bus. Do not multiply tickets to preserve PR momentum.
- Promote a new issue only for an independent P0/P1 acceptance blocker. Record
  P2/P3 and optimization evidence in the deferred ledger.
- At each status interval compare completed versus created/promoted work. If
  promotion exceeds completion, freeze further promotion until the original
  feature lands.
- Keep branches current, CI green and shared-write work sequenced. Merge only
  under the user's current authority and repository policy.

Report two tracks separately: bounded Build Order critical path/count/ETA, and
reliability/optimization findings as active only when separately authorized or
otherwise deferred. Deferred work cannot consume critical-path capacity or
prevent completion.

## Operational playbook (field-proven in the OCC run)

These patterns come from the predecessor dashboard run that shipped the OCC
wave; the full version lives at
`docs/operator-control-center/EXECUTOR-HANDOFF.md` on branch `occ-planning`.

- **Merge gates, every time:** verify the PR's `baseRefName` is the
  configured integration branch before merging (agents build stacked PRs — a
  mis-based squash lands in the wrong branch silently), and run
  `git merge-base --is-ancestor origin/<base> origin/<branch>` (a green PR
  can be green against a stale base). Merge with `--squash --admin`; the
  known seed-dependent SlotPolicy flake (#506) is mergeable-past when
  build/lint/dialyzer are green. Closing merged issues is manual.
- **Unstick with a message, not resume:** a paused/idle worker that is not
  converging (frozen HEAD, no file edits, not load-throttled, not
  attention-flagged) needs `scripts/aiurdev message <id> "<directive>"` to
  inject a real turn; resume alone re-pauses. Post durable directives as
  issue comments — message-queue text is lost on restart.
- **Finalization wedge:** a worker that committed but never pushes gets its
  work pushed by you from its workspace once the tree is clean; its own later
  push becomes a no-op.
- **Hand-fix the last mile in a worktree:** when nudges fail on lint/dialyzer
  or a small must-fix, take over — always in a fresh `git worktree`, never
  the main working tree (it holds the live `.aiur/config`) and never a live
  agent's workspace mid-edit. Verify Elixir edits with
  `Code.string_to_quoted!/1` and run `make lint` before pushing.
- **Restarts are branch-safe:** the checkout logic re-fetches an existing
  remote ticket branch, so recycling a wedged worker (bloated thread,
  CI-poll loop) loses only the unproductive turn, never committed work.
- **Capacity:** track real CPU (`vmstat` id%), not 1-minute load; the
  observed thrash ceiling is ~8–11 concurrent agents on a 12-core box with
  `max_concurrent_builds: 2` as the true protector. Ramp `set max-agents`
  into measured idle, not optimism.
- **Review discipline:** dual review (correctness + adversarial) on every
  substantive PR, front-loaded in parallel; only `must_fix_before_merge`
  findings block a merge — downgrade the rest to the deferred ledger. Drive
  rework with `gh issue comment` (issue_comment), not `gh pr review`.
- **Hygiene:** commit subjects 3–7 word imperative, no AI/model mentions or
  attribution trailers anywhere; never edit `src/test/aiur/regression/`;
  patch labels via the REST API when `gh issue edit` hits the
  classic-Projects GraphQL error; never paste credentials into files,
  commands, or issues.

## Recovery and Aiur defects

Monitor workers, alerts, Commands, PRs, reviews, CI and machine capacity. First
message/retry or return the owning worker to rework. Take over a critical ticket
only when an Aiur defect or hard operational failure makes that the economical
backstop.

With debug authorization, file a sanitized Aiur issue for a reproducible Aiur
failure. Without it, ask the user first. Always remove credentials, tokens,
private content, account identifiers, environment values, local paths/hosts and
irrelevant source context.

## Terminal condition

Stop only when all 54 members — BO-001 through BO-020 and DASH-001 through
DASH-034 — are implemented, reviewed, green on the
current configured integration branch, merged, documented, cleaned up and
proven after merge.

BO-015 owns the acceptance matrix, real published-root dogfood, synthetic
cycle/invalid/degraded/20/50/100 fixtures and post-merge smoke, and closes the
root only after DASH-033's dashboard-parity proof and the Build Order
acceptance evidence both land. The Executor
runs the canonical real CLI/TUI flow from the Executor repository root because
issue workspaces cannot bypass the `--test` guard. Proof also covers the
authenticated browser, selection/deep links, LKG degradation, live activity,
context/dependency navigation, keyboard/touch/pan/zoom, light/dark/reduced
motion, mobile safe area, 200% zoom and preservation of Units, Commands and
Analytics.

After proof, BO-015 closes the GitHub root with state reason `COMPLETED`. The
loop ends there; it does not continue until every discovered reliability or
optimization opportunity is exhausted.

## Adjacent delivery that must not be lost

Draft PR #1065 contains the isolated `/aiur-build` and bounded Executor skill
rewrite. The operator confirmed on 2026-07-13 that it merges into `main` when
planning wraps — before Build Order dispatch — and the old wait-for-run
constraint is lifted. The branch is reconciled with `main` and green; the
reviewed pin is `f92aa045` with successor commits (main merge + review
amendments: implementation-pointer, sizing, parallelism, epic-label/icon, and
plan-context rules) awaiting the operator's confirmation as the new reviewed
head. Never merge mixed research PR #1064 merely to recover the skill files.
