# Aiur refactor requirements framing

This is the requirements framing behind `docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`. The user wants Aiur to keep the Executor and agents making useful progress through failures while reducing code and operational complexity. The desired result is a smaller set of components with one owner for each durable state and visible failure, not a package split measured only by new repository count.

## Evidence that shapes scope

- The corrected gap model has 108 retained intervals of at least 30 minutes, totaling 727.73 exact hours; five long intervals contribute 447.86 hours. The historical classifier cannot assign a causal human/daemon share to every interval (`docs/research/refactor-2026-09-26/synthesis/problem-map.md`, `docs/research/refactor-2026-09-26/synthesis/claim-question-audit.md`).
- The corrected agent corpus has 12,768 short continuation turns and about 20 hours of measured turn time, with concentration in a few threads; 186 hours included idle time before later resumes (`docs/research/refactor-2026-09-26/agents/agent-failure-modes.md`).
- The frozen review covers 32 units and 1,033 source IDs, reconciled into 986 planning findings; three P0 and 94 P1 remain after static review. P2/P3 are provisional (`docs/research/refactor-2026-09-26/review/code-review.md`).
- The feature inventory has 216 entries and 91 skeptical checks of proposed cuts, merges or externalizations. Twelve whole-file deletion scenarios cover a conditional gross footprint of 17,944 lines in 51 distinct files; no net saving has been measured (`docs/research/refactor-2026-09-26/features/feature-inventory.md`, `docs/research/refactor-2026-09-26/features/loc-reduction.md`).
- The frozen tracked-text census finds 359 files above 500 lines and 1,192 above 200. Seven of the 359 occur in the conditional deletion scenarios, so decomposition remains a distinct program (`docs/research/refactor-2026-09-26/synthesis/file-size-analysis.md`).

## Product decisions

- Preserve Aiur's two operating modes: a human drives the CLI, or a coding agent acts as Executor while the human stays in conversation. The visible progress, attention and handoff contract must work for both.
- Preserve accepted capabilities and operator data until an evidence-backed replacement passes acceptance. `none-found` usage is not permission to cut a surface.
- The user directed removal of the local PR deletion guard and GitHub cache dashboard before the next npm release. These pending release removals are outside the future refactor saving ledger. (session-settled: user-directed — chosen over keeping additional deletion gates and dashboard inspection: they add complexity the user does not want.)
- The completed refactor must enforce 500 physical lines as a hard limit for every tracked text file, with 200 as a cohesion review preference. Generated, vendor, test, docs and skill text do not receive a permanent exception. (session-settled: user-directed — chosen over an advisory-only file-size target: the user required an automated hard cap.)
- Treat source-reference graph shape as an extraction warning. Choose package boundaries only after ownership, startup, failure and test contracts are explicit; code movement alone is not LOC reduction.

## Requirements

- R1. The Executor can distinguish actionable work, a human wait, provider unavailability, uncertain delivery and a stale or unknown observation without a false success state.
- R2. A ticket has one authoritative lifecycle decision and a durable, observable route from rework evidence to dispatch, including failed writes and closed fences.
- R3. Agent continuation waits on a concrete condition and resumes on a relevant event or bounded timer; pause and process containment agree on whether the worker is stopped.
- R4. Event, command and review delivery retain identity, ordering and receipts through restart; ambiguous external mutations reconcile before retry.
- R5. GitHub read completeness, cache monotonicity, webhook fallback and credential budget admission remain correct under truncation, pagination and failure.
- R6. A proposed cut, merge or externalization is challenged against current use, indirect callers, documented behavior and a replacement or migration path.
- R7. The line-count gate measures all tracked text by one physical-line convention, blocks new debt immediately, tracks existing debt to zero and then enforces the universal 500-line limit.
- R8. Shared extraction preserves native Muse behavior and all other accepted backends; new Gemini support follows the separately queued post-release ticket rather than expanding this refactor scope.
- R9. Each behavior change has a regression test that fails when its production hunk is reverted, plus real CLI/TUI acceptance for user-visible flows.
- R10. Savings claims use an observed baseline, a counted production population and a before/after measurement; moved lines and conditional candidates are reported separately.

## Acceptance and unanswered decisions

The refactor succeeds when real foreground Aiur runs with multiple agents show correct chat, attention, pause/resume and delivery behavior; required CI, browser and release checks pass; every tracked UTF-8 text file is at most 500 lines; and a before/after census reports net code, test, docs and generated text change without double counting. The 200-line preference remains reviewable through explicit cohesion reasons rather than a mechanical split.

The branch-tip contextual private-source review is complete at `docs/research/refactor-2026-09-26/synthesis/privacy-provenance-audit.md`; new implementation evidence still needs review before publication. Before product-code work is dispatched, refresh all counts and findings against the implementation base and validate the frozen 359-file owner map’s proposed assignments and dispositions on merged main. The causal timeline audit identifies local prewarm/dependency point causes but cannot allocate the historical gap hours; prospective progress measurements must record actionable demand and distinguish observation from acknowledgement and action. The CODEOWNERS degraded-trust rule, store-specific durability policy and first package boundary require explicit technical decisions in the plan.
