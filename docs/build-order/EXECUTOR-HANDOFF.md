# Build Order Executor Handoff

## Start gate

This handoff becomes executable only after the live Build Order root contains a
uniquely marked `aiur-build-order-reconciliation` comment linking a successful
immutable post-publication receipt, both external gates below are recorded as
resolved, and the user separately authorizes a run. Planning publication
does not queue work. Until then, do not run Aiur, implement tickets, or add
`agent:todo`.

## Identity and objective

- Build Order: `its-everdred/aiur:build-order-dashboard`
- Plan version: 1
- Repository: `its-everdred/aiur`
- Researched commit: `1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d`
- Approved planning commit: pending final clean review
- GitHub root: resolve live by the hidden Build Order root marker; do not trust
  a copied pending number

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
2. Use `/aiur-run`, not the retired `/aiur-loop` workflow. Verify the loaded
   skill is PR #1065 commit `0daf2972` or an explicitly reviewed compatible
   successor preserving its finite-boundary, review/rework, circuit-breaker,
   and publication rules. A matching skill name is insufficient.
3. Write a three-to-five-sentence `/goal` stating that you are the Executor,
   the finite acceptance boundary, granted issue/merge authority, critical-path
   priority and terminal condition.
4. Requery repository instructions, configured integration branch, the GitHub
   root/members/blockers/full labels, active PRs, CI and Aiur status. Never use
   the planning JSON as fresher live GitHub truth.
5. Queue only approved BO members under explicit user authority. Companion
   issues remain inactive unless separately authorized and their shared
   `GATE-OCC-PREDECESSOR-BASELINE` plus any ticket-specific provider gate is
   resolved.

## External pre-dispatch gates

- **GATE-001 — integration baseline:** the predecessor OCC run is complete and the
  configured `tracker.base_branch` contains the researched OCC baseline plus
  accepted successors. At planning time `.aiur/config` and `CONTRIBUTING.md`
  named divergent `v2` commit `3bbc064a`; record the resolved branch and SHA on
  the live root. Do not silently implement against that stale snapshot.
- **GATE-002 — Executor skill:** the bounded skill revision above is installed and
  `/aiur-build`, `/aiur-run`, and `/aiur-monitor` are discoverable. The separate
  human skill-delivery issue remains outside the Build Order denominator.

Both gates block BO-001. Because BO-008 depends on BO-001, they transitively
gate every Build Order implementation ticket.

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

After both external gates resolve, BO-001 is the sole initial ticket. BO-002,
BO-004, and BO-008 follow BO-001. BO-003 follows BO-002; BO-005 follows BO-004,
and those two serialize on the application-supervision seam. BO-009 follows
BO-001 and BO-008; BO-010 follows BO-008 and BO-009. BO-006 follows BO-005.
BO-007 follows BO-001, BO-003, and BO-005. BO-011 follows BO-003, BO-007, and
BO-008. BO-012 follows BO-003, BO-007, BO-010, and BO-011; BO-013 follows
BO-008 and BO-012; BO-014 follows BO-008 and BO-013; BO-015 follows BO-006 and
BO-014.

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

Stop only when BO-001 through BO-015 are implemented, reviewed, green on the
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
