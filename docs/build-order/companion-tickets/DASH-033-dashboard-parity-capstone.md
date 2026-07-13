# DASH-033 — Prove existing-dashboard parity

**Kind:** executable

**Provenance:** planned in plan v1 after the shipped-dashboard capability re-audit

**Complexity:** 3 — Integrated real-dashboard proof across independently accepted companion systems

**Risk:** high

**Depends on:** DASH-001, DASH-003, DASH-005, DASH-007, DASH-015, DASH-022, DASH-027, DASH-028, DASH-031, DASH-034

**Serializes with:** BO-015 — shared browser harness, acceptance evidence, and closeout documentation

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-033

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

The shipped Executor Control Center is proven end to end to preserve current
operational behavior while meeting the accepted prototype delta for shell,
Units, conversations, controls, Commands, run/provider/accounting summaries,
Recent outcomes, authentication, accessibility, live
convergence, and responsive layouts.

## Context and evidence

The prior dashboard is real production code, not a blank implementation base.
Its Fleet, Decision lifecycle, recent merge audit, Decision history, Analytics,
auth modes, PubSub, and control seams must survive the companion rollout. Each
prerequisite has a focused acceptance gate, but no ticket currently proves the
composed existing-pages experience. This capstone owns convergence only; it is
not permission to expand the feature or reopen deferred reliability work.

## Scope

- Establish the exact configured integration branch/SHA containing every
  prerequisite and the resolved predecessor baseline. Reproduce on current
  main-equivalent code rather than an obsolete prototype or planning branch.
- Run the real dashboard through the repository's canonical CLI/manual-testing
  path in read-only and authenticated writable modes. Exercise reconnect and
  daemon-driven updates rather than browser-only fixture mutation.
- Prove responsive route navigation for Units, Commands, Build Order, and the
  real Analytics destination, including share/back/refresh, safe areas, theme,
  reduced motion, 320/390/768/960/desktop, and 200% text zoom.
- Prove Units scopes/overlapping chips, terminal membership, unknown/stale
  facts, ticket context, safe read-only conversation mirror, per-unit controls,
  authoritative positive capacity changes, and focus preservation under live
  row updates.
- Prove the complete retained Decision lifecycle still works through Commands:
  direct old-record lookup, filtering, provenance/confidence, confirmation,
  dispatch/retry/acknowledgement, revisions, follow-ups, and deep links.
- Prove nonfinancial run summary, provider meter cards, usage/cost accounting,
  exact-generation tier annotations, Remote/headless coverage, asterisk
  disclosure, contributor reconciliation, and content-free locked mode.
- Prove `Finished this run` outcomes use the accepted current-run member/merge
  contract without relabelling the global RecentMerge audit or deleting
  Decision history.
- Collect bounded screenshots, browser/a11y results, performance/overflow
  evidence, relevant CI, and a concise documentation/compatibility handoff.
- Route a failed prerequisite acceptance back to that ticket as contained
  rework. Record nonblocking discoveries in the deferred ledger; do not create
  an expanding reliability backlog during capstone convergence.

## Non-goals

- Implement a missing prerequisite, redesign Build Order graph behavior,
  replace Analytics, create planning mutations, or add a new general reliability
  program.
- Require pixel-for-pixel prototype parity, copy fake data/client mutations, or
  declare success from unit tests, logs, HTTP calls, or screenshots alone.
- Keep working until every adjacent bug or optimization is exhausted.

## Existing owner and reuse target

Use the repository's BO-008 browser harness, canonical `aiurdev --test` manual
workflow, current OCC component/route tests, and every prerequisite's synthetic
fixture. This ticket adds only integration fixes, proof, and durable handoff
needed for the bounded dashboard companion definition of done.

## Contract and invariants

- Maximum parallelism remains subordinate to this finite acceptance boundary.
  Review findings default to contained rework in the owning prerequisite.
- Read-only, writable, authenticated, unauthenticated-locked, degraded, stale,
  restart, empty, and healthy states remain distinguishable in the composed UI.
- No protected value, raw protocol payload, transcript, credential, account
  identity, capability URL, or local path appears in browser content or proof.
- Current Fleet/Decision/Recent/Analytics behavior is preserved or explicitly
  replaced by an accepted, tested contract; nothing silently disappears.
- Passing requires current-main integration, CI, documentation, and real
  end-to-end operator-visible evidence.

## Refreshable implementation notes

- Refresh the exact route/component names and canonical test command at pickup.
  Do not reuse the prototype's static data as a production fixture.
- Use deterministic synthetic providers for boundary coverage, then one real
  CLI/dashboard run for operator-visible proof. Redact all captured evidence.
- Maintain a short parity checklist keyed to the existing-page subset of
  DREQ-001..034 and the shipped
  baseline rather than adding implementation behavior to this ticket.

## Acceptance and verification

### Agent gate

- Full component, LiveView, provider, storage, control, Decision, browser,
  accessibility, security, performance, and repository CI suites pass on the
  exact configured integration SHA.
- Automated browser matrix covers all named routes, breakpoints, zoom/theme/
  motion modes, keyboard/touch/focus paths, reconnect/live updates, auth modes,
  degraded providers, and absence of page-level overflow.
- A traceable checklist maps every companion requirement to prerequisite proof
  and composed proof, with no silently waived acceptance item.

### At-merge gate

- Rebase on all ten terminal prerequisites, resolve shared composition only
  through their published contracts, pass current main CI, and land the
  documentation/evidence update with no unresolved P0/P1 dashboard blocker.

### Human/manual evidence

- From the Executor repository root, launch the real CLI as prescribed by
  `AGENTS.md`; drive the dashboard and TUI like an operator; observe Units,
  Commands, conversation, controls, summaries, Recent, Analytics, read-only/
  locked, live-update, desktop, and 390px behavior.

## Failure, security, migration, and accessibility cases

- A failed provider or stale projection degrades its bounded region and cannot
  crash navigation or erase safe facts. A failed acceptance item blocks this
  capstone and returns to its owner; nonblockers are deferred with evidence.
- Proof artifacts use synthetic/redacted data and never include secrets,
  account identity, raw logs/provider payloads, workspace paths, or the user's
  dashboard credentials.
- Validate every schema migration/replay through its owner before the composed
  run. Semantic structure, names, focus, touch, zoom, motion, and non-color
  state are required across the complete experience.

## Surfaces

- Reads: all accepted companion contracts, configured integration SHA, real
  dashboard/TUI behavior, CI, browser/a11y/performance evidence.
- Writes: bounded integration fixes, parity checklist, screenshots/evidence,
  documentation, and tests.
- Contracts: composed dashboard definition of done and predecessor-behavior
  preservation.
- Safety: finite feature boundary, protected-data nonleakage, and deferred-
  findings circuit breaker.

## Sibling boundaries and open gates

This capstone is outside the Build Order root and cannot delay the 19-ticket
Build Order graph's completion. It starts only after its terminal prerequisites
and any transitive Claude protocol-authority gates are resolved. Findings stay
within the bounded companion program unless separately authorized.
