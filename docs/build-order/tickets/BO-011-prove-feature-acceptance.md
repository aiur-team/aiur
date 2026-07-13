# BO-011 — Prove merged Build Order acceptance

**Kind:** capstone

**Provenance:** planned in plan v1

**Complexity:** 4 — Current-base integration, real-run proof, documentation, and bounded fixes

**Risk:** high

**Phase hint:** 7

**Depends on:** BO-005, BO-010

**Serializes with:** none

**Requirements:** BOREQ-012, BOREQ-013, BOREQ-014

**Decisions:** DEC-008

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:4`, `model:codex`, `phase:7`, `build-lane:infrastructure`; never `agent:todo`

## Outcome

The complete bounded Build Order feature is current-base green, documented, merged, and proven against its published native GitHub root through the real Aiur CLI and authenticated browser workflow.

## Context and evidence

Parallel provider, projection, TUI, presenter, layout, context, route, and interaction tickets need one explicit owner for integrated acceptance. Without a capstone, late defects become unowned follow-up tickets or the feature stops at unit-test confidence.

The capstone is verification and narrowly contained integration rework, not permission to expand into Units, Commands, accounting, reliability, or optimization programs.

## Scope

- Rebase/merge all Build Order work onto the current configured integration branch and resolve only contained integration defects needed by BOREQ-001..014.
- Use the actual published Build Order root, native sub-issue membership, native hard blockers, labels, closed/open outcomes, and one external/invalid diagnostic to dogfood the page.
- Run the complete provider/parser/projection/presenter/LiveView/browser/accessibility/performance suites and the repository CI gate.
- From the operator repo root, launch the real CLI per `AGENTS.md`, observe the real dashboard under authentication, and exercise selection/deep link, LKG degradation, activity updates, context, light/dark/reduced motion, keyboard/touch/pan/zoom, and 20/50/100 fixtures.
- Write operator/provider contract documentation, graph metadata rules, troubleshooting/freshness semantics, and durable evidence links; remove temporary fixtures or dead compatibility code explicitly assigned to this feature.
- Record deferred non-blockers in the ledger and close the feature only after post-merge current-main proof.

## Non-goals

- Add companion shell/Units/Commands/usage work, dependency editing, Linear, cross-repository graphs, or new reliability optimizations.
- Create separate tickets for contained review/integration findings merely to keep this PR moving.
- Declare success from unit tests, logs, HTTP alone, a prototype screenshot, or a workspace-blocked fake manual run.

## Existing owner and reuse target

Own feature-level acceptance across the merged Build Order modules, dashboard routes, documentation, and actual GitHub planning root. The later Executor owns the operator-root CLI run because issue workspaces are explicitly blocked from launching the canonical `--test` workflow.

## Contract and invariants

- The critical path ends only when implementation, review, current-base CI, merge, documentation, cleanup, and named end-to-end proof all succeed.
- Companion and deferred work never changes Build Order remaining count or ETA.
- Contained defects return to their owner or are fixed narrowly here; non-blockers remain deferred with evidence.
- Manual verification follows the exact real-CLI/TUI/browser contract in `AGENTS.md`; no HTTP/log proxy substitutes.
- Final status is re-queried from GitHub/Aiur rather than copied from the planning PR.

## Refreshable implementation notes

- At pickup, refresh repository instructions, integration-branch policy, published issue mappings, and all active dashboard PRs.
- Prepare an operator-run checklist that can be executed outside the issue workspace and attach durable evidence without secrets/local paths.
- Keep capstone changes narrow; route systemic bugs through the finite-boundary classification.

## Acceptance and verification

### Agent gate

- All automated feature suites and full `make ci` pass on the current integrated base.
- Acceptance matrix maps every BOREQ to exact automated or operator evidence and reports zero unresolved blocker.
- Published graph reconciliation proves parent membership, labels, and native dependencies before dogfooding.

### At-merge gate

- PR is reviewed, current-base green, and merged under the active branch policy.
- After merge, the same CI/feature smoke remains green on current main and documentation links resolve.

### Human/manual evidence

- Executor launches the real CLI from the operator repo root and records authenticated browser plus required TUI evidence for the published Build Order workflow, including degraded provider and 100-node cases.

## Failure, security, migration, and accessibility cases

- Security: scrub tokens, credentials, private issue content, local paths, hosts, account identifiers, and raw provider responses from evidence/bug reports.
- Migration: document restart/LKG in-memory behavior and verify upgrade does not break existing dashboard/TUI routes.
- Accessibility: manual and automated acceptance covers keyboard, touch, screen-reader semantics, focus, contrast, reduced motion, zoom, and narrow viewport.

## Surfaces

- Reads: all merged Build Order contracts; published GitHub Build Order root; real Aiur runtime/dashboard.
- Writes: integration fixes within bounded scope; operator/provider docs; acceptance evidence and deferred ledger.
- Contracts: feature terminal condition; merged-base acceptance matrix; Executor handoff proof.

## Sibling boundaries and open gates

Every implementation ticket is a transitive prerequisite through BO-005 and BO-010. Dashboard companion issues and deferred findings are explicitly outside this capstone and cannot block feature completion.

