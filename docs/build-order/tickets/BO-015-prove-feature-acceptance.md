# BO-015 — Prove current-base real and synthetic acceptance

**Kind:** capstone

**Provenance:** planned in plan v1

**Complexity:** 4 — Current-base integration, real-root dogfood, synthetic limits, documentation, and post-merge proof

**Risk:** high

**Phase hint:** 8

**Depends on:** BO-006, BO-014

**Serializes with:** none

**Requirements:** BOREQ-015

**Decisions:** DEC-008, DEC-011, DEC-012, DEC-013

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d

**Suggested labels:** `complexity:4`, `model:codex`, `phase:8`, `build-lane:documentation`; never `agent:todo`

## Outcome

The complete bounded Build Order feature is integrated on the current
configured integration branch, reviewed, green, documented, merged under the
active policy, proven after merge against the real published Build Order root
and deterministic limit/failure fixtures, and only then accepted by closing the
root issue with state reason `COMPLETED`.

## Context and evidence

Parallel provider, event, activity, TUI, presenter, browser-harness, layout,
context, route, interaction, and performance PRs can each pass locally without
forming a trustworthy Executor workflow. The prior OCC run showed why a
capstone must exist from the start and why contained integration defects return
to their owning ticket rather than becoming an expanding tail of follow-ups.

The real published root proves GitHub identity, membership, labels, lifecycle,
and native dependencies. Synthetic fixtures prove boundary and failure states
that should not be manufactured against live GitHub.

## Scope

- Requery repository instructions, the current configured integration branch,
  active dashboard work, the approved plan commit, published root membership,
  ticket mappings/labels, and every native hard dependency before integration.
- Reconfirm the live root records both external gates as resolved: the named
  branch/SHA contains the completed OCC baseline, and the bounded Executor
  skill revision remains the loaded contract. A later branch or skill drift is
  an explicit gate failure, not an inferred success.
- Integrate all transitive BO-001..014 work, resolve only contained acceptance
  defects, run the full automated contract/CI matrix, and maintain an acceptance
  matrix mapping every BOREQ to exact automated or Executor evidence.
- Dogfood the real currently published Build Order root through the real GitHub
  provider: select/deep-link it, verify all 15 member identities/labels/native
  edges/outcomes, observe real Aiur activity join, open cached context, navigate
  dependencies, follow one safe destination link, and confirm Build Order
  exposes no GitHub or Aiur mutation handler.
- Use BO-008's synthetic 20/50/100, cycle/self-loop, external/missing,
  malformed-catalog-root, selected structural-invalid, member-warning, stale
  LKG, unavailable-provider, unknown-activity, and fallback fixtures for full
  browser/accessibility/performance proof.
- From the Executor repository root, launch and drive the actual CLI/TUI exactly
  as required by `AGENTS.md`, open a running agent chat pane, send/observe the
  expected user-visible flow, and inspect the authenticated dashboard route.
  Do not substitute direct HTTP calls, logs, or an issue-workspace bypass.
- Verify mouse/keyboard/touch, context focus, all edge/readiness states,
  pan/zoom/fit, light/dark/forced-colors/reduced-motion, 200% text zoom,
  320/390/768/960/desktop, redraw/reconnect, packaged assets, and recorded
  20/50/100 budgets.
- Write the Executor route/interaction guide, GitHub root/member/metadata/
  native-dependency authoring guide, provider health/freshness/troubleshooting
  guide, acceptance evidence index, and bounded cleanup record. Remove temporary
  fixtures/compatibility code only where their ticket contract requires it.
- After the capstone change is reviewed, green, and merged under the current
  configured policy, rerun the required post-merge smoke/proof on the configured
  integration target. The acceptance owner then closes the Build Order root as
  `COMPLETED`; automated child progress never closes it early.

## Non-goals

- Add dashboard companion shell/Units/Commands/usage work, Linear,
  cross-repository/nested orders, GitHub dependency editing, minimap/filtering,
  or unrelated reliability/optimization work.
- Close the root because all children show 100%, because CI alone passes, or
  before post-merge real/synthetic proof is recorded.
- Create follow-up tickets for contained review/integration findings merely to
  preserve capstone PR momentum.

## Existing owner and reuse target

Own feature-level acceptance across all merged Build Order modules, current
dashboard routes/assets, published GitHub root, documentation, and the real
Executor-root CLI workflow. The Executor/acceptance owner performs proof that an
issue-workspace agent is prohibited from running and owns the final root state
transition.

## Contract and invariants

- BO-006 and BO-014 are the two terminal prerequisites and transitively cover
  every implementation ticket; GitHub remains live membership/hard-edge truth
  while the planning pack remains the approved boundary/conflict baseline.
- The feature is complete only after implementation, review, current-configured-
  branch CI, merge, documentation, cleanup, post-merge real CLI/browser proof,
  synthetic boundary proof, and root `COMPLETED` closure.
- Companions, deferred findings, P2/P3 defects, and optimizations never change
  the denominator, ETA, or completion condition.
- Contained findings return to the owning ticket/rework. Only a genuine
  independent P0/P1 acceptance blocker may be promoted; backlog-growth circuit
  breaker policy remains active.
- Evidence is current, source-linked, sanitized, and never substitutes logs or
  API calls for required user-visible TUI/browser behavior.

## Refreshable implementation notes

- Never hardcode `main` or another merge target; resolve and record the current
  configured integration branch/policy at pickup and again before post-merge
  proof.
- Prepare the Executor-root manual checklist before merge so required auth,
  synthetic modes, screenshots, and cleanup can run without issue-workspace
  workarounds.
- Keep capstone code changes narrowly integrative; route systemic non-blockers
  to the deferred ledger and preserve the finite boundary.

## Acceptance and verification

### Agent gate

- Latest canonical planning validator and published GitHub reconciliation pass
  with exact 15-member parenthood, required labels, `model:codex`, no active
  `agent:todo`, and exact native hard edges.
- Every focused suite plus the complete repository CI gate passes on the
  current integrated candidate; the acceptance matrix has no missing BOREQ or
  unresolved blocker.
- BO-008 browser automation passes real-route synthetic 20/50/100/cycle/
  invalid/degraded/fallback/accessibility/performance cases with durable
  sanitized evidence.

### At-merge gate

- Capstone is reviewed and current on the configured integration branch, every
  required check is green, documentation/links resolve, and merge follows the
  then-active authority/policy.
- After merge, the configured integration target passes the same feature smoke,
  packaged-asset check, and real-root provider reconciliation before root
  closure.

### Human/manual evidence

- Executor records the canonical Executor-root real CLI/TUI plus authenticated
  browser workflow, real published-root dogfood, keyboard/touch/theme/motion/
  zoom evidence, and representative 100-member/degraded synthetic evidence.
- Acceptance owner records the evidence link and closes the root with state
  reason `COMPLETED` only after the post-merge proof succeeds.

## Failure, security, migration, and accessibility cases

- Sanitize credentials, tokens, private issue content, account identifiers,
  environment values, local paths/hosts, raw provider responses, transcripts,
  and real user data from evidence and bug reports.
- Verify upgrade/restart preserves existing dashboard/TUI routes and documents
  in-memory LKG/activity restart semantics; all stored migrations from dependent
  tickets are replay/rollback tested.
- Manual and automated evidence covers semantic fallback, keyboard/touch,
  screen-reader summaries/focus, contrast/forced colors, reduced motion, 200%
  text zoom, safe areas, responsive reflow, and non-color edge states.

## Surfaces

- Reads: every merged Build Order contract; approved planning baseline and
  published GitHub root; current configured integration policy; real Aiur
  CLI/TUI/dashboard; BO-008 fixtures/evidence.
- Writes: bounded integration fixes, acceptance matrix/evidence, Executor and
  provider documentation, cleanup record, deferred findings, and final GitHub
  root state transition.
- Contracts: finite feature terminal condition; post-merge acceptance sequence;
  real-plus-synthetic proof; root `COMPLETED` ownership.

## Sibling boundaries and open gates

All implementation tickets are transitive prerequisites. Dashboard companions,
Linear parity, and deferred findings remain outside the root and cannot block
closure. Publication approval, the root's immutable reconciliation-comment
link, and both resolved external gates must exist before execution; no issue is
dispatched by this planning ticket.
