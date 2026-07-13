# Build Order Executor Handoff

## Start gate

This handoff becomes executable only after
`docs/build-order/github-publication.md` contains a successful reconciliation
receipt and the operator separately authorizes a run. Planning publication does
not queue work. Until then, do not run Aiur, implement tickets or add
`agent:todo`.

## Identity and objective

- Build Order: `its-everdred/aiur:build-order-dashboard`
- Plan version: 1
- Repository: `its-everdred/aiur`
- Researched commit: `b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5`
- Approved planning commit: pending final clean review
- GitHub root: pending materialization

Deliver the fifteen-ticket authenticated, GitHub-planning-read-only Build Order
feature. GitHub owns current plan facts; Aiur owns runtime facts. The fifteen
dashboard companions, Linear #1067, skill-delivery work and deferred findings
are separate tracks and cannot change this run's denominator or ETA.

## Required startup

1. Read these repository-relative paths in order:
   - `docs/build-order/README.md`
   - `docs/brainstorms/2026-07-12-build-order-requirements.md`
   - `docs/build-order/05-technical-decisions.md`
   - `docs/build-order/build-order.json`
   - `docs/build-order/tickets/BO-001-define-domain-contract.md` through
     `docs/build-order/tickets/BO-015-prove-feature-acceptance.md`
   - `docs/build-order/validation-report.md`
   - `docs/build-order/github-publication.md`
2. Use `/aiur-run`, not the retired `/aiur-loop` workflow.
3. Write a three-to-five-sentence `/goal` stating that you are the Executor,
   the finite acceptance boundary, granted issue/merge authority, critical-path
   priority and terminal condition.
4. Requery repository instructions, configured integration branch, the GitHub
   root/members/blockers/full labels, active PRs, CI and Aiur status. Never use
   the planning JSON as fresher live GitHub truth.
5. Queue only approved BO members under explicit operator authority. Companion
   issues remain inactive unless separately authorized.

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

BO-001 and BO-008 can begin together. After BO-001, BO-002, BO-004 and BO-009
are independent. BO-003 follows BO-002; BO-005 follows BO-004, and those two
serialize on the application supervision seam. BO-010 follows BO-008/009;
BO-006/007 follow activity; BO-011 follows the presenter; BO-012 joins graph,
presenter, layout and context; BO-013/014 harden interaction and scale; BO-015
integrates and proves the feature.

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
  under the operator's current authority and repository policy.

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
failure. Without it, ask the operator first. Always remove credentials, tokens,
private content, account identifiers, environment values, local paths/hosts and
irrelevant source context.

## Terminal condition

Stop only when BO-001 through BO-015 are implemented, reviewed, green on the
current configured integration branch, merged, documented, cleaned up and
proven after merge.

BO-015 owns the acceptance matrix, real published-root dogfood, synthetic
cycle/invalid/degraded/20/50/100 fixtures and post-merge smoke. The Executor
runs the canonical real CLI/TUI flow from the operator repository root because
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
