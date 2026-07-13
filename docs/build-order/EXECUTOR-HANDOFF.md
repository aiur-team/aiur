# Build Order Executor Handoff

## Stop: planning approval is still pending

This handoff is not executable until the operator approves the ticket pack and
`github-publication.md` contains a successful reconciliation receipt. The
approved planning commit and returned GitHub root identity are intentionally
pending in this draft. Do not run Aiur, implement a ticket, or add `agent:todo`
while that gate is open.

## Identity and objective

- Build Order: `its-everdred/aiur:build-order-dashboard`
- Plan version: 1
- Repository: `its-everdred/aiur`
- Researched commit: `3d67b7be722eb649f28088fc8d609dd7b75254c7`
- Approved planning commit: pending operator review
- GitHub root selector/node identity: pending materialization

The objective is to deliver the 11-ticket, authenticated, read-only Build Order
feature. GitHub owns plan facts; Aiur owns runtime facts. The eight dashboard
companions and every deferred finding are outside this run.

## Executor startup

After the pending gates close:

1. Read `README.md`, requirements, technical decisions, canonical JSON, all BO
   ticket contracts, validation report, and publication receipt.
2. Use `aiur-run`, not the removed `aiur-loop` workflow.
3. Write a three-to-five-sentence `/goal` stating that you are the Executor,
   the finite acceptance boundary, granted merge/issue authority, critical-path
   priority, and terminal condition.
4. Requery current repository instructions, integration branch, root
   membership/dependencies/labels, active PRs, CI, and Aiur status. Do not trust
   copied status in this document.
5. Queue only approved BO members under the user's authority. The planning
   publication deliberately leaves them undispatched.

## Authority map

- GitHub: identity, direct membership, title/body, labels, state/state reason,
  and native hard blockers.
- Aiur: running/queued/retry/paused state, progress, active agent stage, alerts,
  events, and latest evidence.
- Planning pack: approved requirements, decisions, ticket boundaries, typed
  scheduling graph, validation evidence, and finite boundary.
- Executor: current readiness/capacity decisions, review/rework routing, merge
  policy under granted authority, recovery, status, and final proof.

Unknown/stale provider data never becomes empty, ready, successful, or zero.
Aiur progress—including 100%—never clears a GitHub blocker.

## Graph and capacity

The canonical graph is `build-order.json`; derive reverse edges/readiness from
it and GitHub. The initial contract gate is BO-001. After it lands, BO-002,
BO-004, and BO-007 can run in parallel. BO-003 and BO-004 serialize on
supervision. BO-003/005/006 then unlock independent work, followed by BO-008,
BO-009, BO-010, and BO-011 as encoded.

Maximize progress against this bounded graph, not raw active-ticket count.
Increase agent capacity only when memory/CPU/build gates and independent ready
work justify it. Do not activate companion or deferred work to keep slots busy.

## Review, rework, and merge

- Review each PR against its ticket contract, shared decisions, and current
  base. Use parallel `ce-code-review` agents where available.
- Contained findings return the same ticket to rework and are delivered through
  the event bus; do not create a follow-up merely to preserve PR momentum.
- Create/promote a new ticket only for a genuine independent P0/P1 feature
  blocker. Record P2/P3 and optimizations in `deferred-findings.md`.
- Keep branches current, CI green, and shared-write tickets sequenced as the
  plan specifies. Merge only under explicit authority and current repository
  policy.
- If created/promoted work exceeds completions in an interval, freeze new
  promotion until the bounded feature completes.

## Recovery and Aiur defects

Monitor all workers, alerts, commands, PRs, reviews, CI, and resource/capacity
state. Prefer messaging/retrying/returning the owning worker to rework. The
Executor may take over a critical ticket only when an Aiur defect or hard
operational failure makes that the economical backstop.

With debug authorization, file a sanitized Aiur bug for reproducible Aiur
failures. Without it, ask before external issue creation. Always remove secrets,
tokens, credentials, private content, account identifiers, environment values,
local paths/hosts, and irrelevant source context.

## Status reporting

Report two independent tracks:

1. Build Order critical path: current ready/active/rework/merged tickets,
   remaining count, blockers, and evidence-based ETA.
2. Reliability/optimization findings: active only if separately authorized;
   otherwise deferred count and notable evidence.

Deferred work cannot change the feature count/ETA, consume critical-path
capacity, or prevent completion.

## Terminal condition

Stop when BO-001 through BO-011 are implemented, reviewed, green on the current
configured base, merged, documented, cleaned up, and proven on current main by
the required end-to-end workflow.

BO-011 owns the acceptance matrix and published-root dogfood. The Executor must
run the canonical real CLI flow from the operator repo root because issue
workspaces may not bypass the `--test` guard. Proof includes the authenticated
browser route and required TUI evidence, provider degradation/LKG, multiple
root selection/deep links, activity updates, context/dependency navigation,
keyboard/touch/pan/zoom, light/dark/reduced motion, narrow viewport, and
20/50/100-member fixtures.

The loop ends there. It does not continue until every bug, optimization, or
reliability opportunity discovered along the way is exhausted.
