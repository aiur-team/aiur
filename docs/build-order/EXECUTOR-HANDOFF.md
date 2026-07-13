# Build Order Executor Handoff

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
titles/bodies/full labels, the root has exactly twenty BO children, every
non-root has no children, and all 105 blockers are exact. Run that full verifier
immediately before the first execution mutation. Once the authorized run
begins, later lifecycle changes are legitimate runtime truth and do not rewrite
the receipt: gate resolution may update live issues, the skill-delivery issue
may close, and BO issues may acquire `agent:*` labels. Record and resolve both
external gates while the skill issue is still open; only after both gates are
proven may the Executor close the skill issue and dispatch BO work. Never close
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

Deliver the twenty-ticket authenticated, GitHub-planning-read-only Build Order
feature. GitHub owns current plan facts; Aiur owns runtime facts. The thirty-four
dashboard companions, Linear #1067, skill-delivery work and deferred findings
are separate tracks and cannot change this run's denominator or ETA.

## Required startup

1. Read these repository-relative paths in order:
   - `docs/build-order/README.md`
   - `docs/brainstorms/2026-07-12-build-order-requirements.md`
   - `docs/build-order/05-technical-decisions.md`
   - `docs/build-order/build-order.json`
   - every `tickets[].document` path in
     `docs/build-order/build-order.json` (BO-001 through BO-020)
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
5. Queue only approved BO members under explicit user authority. Companion
   issues remain inactive unless separately authorized; their shared
   predecessor baseline is recorded as resolved (`origin/main` at
   `9849f32963c2a65367bce565b3f5ede3777c218f`), and any ticket-specific
   provider gate must still be resolved.

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

After both external gates resolve, start BO-004 and BO-008 in parallel. BO-001
and BO-017 follow BO-004. BO-002 follows BO-001; BO-003 follows BO-002; BO-005
follows BO-017. BO-003, BO-005, BO-016, and BO-019 serialize on the
application-supervision seam wherever hard dependencies do not already order
them; BO-005 also serializes with companion DASH-029 on observation-envelope
consumption. BO-006 follows BO-005. BO-007 follows BO-001, BO-003, and BO-005.
BO-009 follows BO-001 and BO-008; BO-010 follows BO-008 and BO-009. BO-016
follows BO-004 and owns configured-repository ticket detail. BO-019 follows
BO-005 and owns bounded sanitized recent history. BO-018 follows BO-008,
BO-016, and BO-019 and owns accessible base context. BO-011 follows BO-007 and
BO-018 and adds Build Order relationships and truthful destination links.
BO-012 follows BO-003, BO-007, BO-010, and BO-011; BO-013 follows BO-008 and
BO-012; BO-014 follows BO-008 and BO-013; BO-015 follows BO-006 and BO-014.

If separately authorized companion work is active, honor its companion-owned
cross-pack serialization: DASH-001 with BO-012, DASH-023 with BO-013/014, and
DASH-029 with BO-005. DASH-018/019 serialize on the Claude process-lifecycle
adapter. DASH-004/019 depend on BO-004's configured-repository identity. The
eight supervised companion services—DASH-002/009/012/018/019/024/025/026—also
declare every independently ready same-pack and cross-pack serialization pair
against BO-003/005/016/019 on the central application supervision tree. Hard
dependencies already order the omitted pairs.

Derive current readiness from GitHub native blockers, ticket lifecycle,
declared serialization and real capacity. Phase is only a rollout/display hint.
Maximize progress against ready critical-path work, not raw active count. Do not
activate companions or deferred findings to keep slots busy.

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

Stop only when BO-001 through BO-020 are implemented, reviewed, green on the
current configured integration branch, merged, documented, cleaned up and
proven after merge.

BO-015 owns the acceptance matrix, real published-root dogfood, synthetic
cycle/invalid/degraded/20/50/100 fixtures and post-merge smoke. The Executor
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
rewrite. Its separate human-blocked tracking issue may land only after the
current dashboard Executor stops using the prior contracts. Never merge mixed
research PR #1064 merely to recover the skill files.
