---
title: "Evidence-led Aiur refactor"
date: "2026-09-29"
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
---

# Evidence-led Aiur refactor

## Goal Capsule

Make Aiur reliable enough that the Executor and agents continue making useful progress through provider, tracker, review and host failures, while reducing unnecessary code and giving cohesive components explicit ownership. Use the complete `3339b887` research snapshot, the corrected research verdicts and the native Muse integration as evidence. No production refactor is authorized by this research plan alone; this artifact becomes executable only after the research reconciliation and planning sections are complete.

## Product Contract

### Problem Frame

The measured run history contains long gaps without Executor or agent progress, recurring recovery defects and contracts distributed across a large single-process orchestrator. The codebase survey identifies 35 of 36 proposed boundaries in one static dependency component at the earlier `0972f0297` revision; that measurement is a design warning, not a proof that every component must stay together. Raw code review findings and cut recommendations are candidate evidence until their required skeptical checks and reconciliations are complete.

### Requirements

- R1. Preserve both operating modes: a human driving the CLI and a coding agent acting as Executor while the human stays in conversation.
- R2. Define forward progress from observable ticket, agent, Executor and delivery evidence. Distinguish idle, blocked, waiting for human review, provider unavailable and failed delivery without guessing a specific cause.
- R3. Preserve ticket identity, authority, state transitions, pause/containment, restart and workspace recovery when decomposing the orchestrator and adapters.
- R4. Preserve delivery correlation and exactly-once effects where the product promises them, including operator messages, coordination tools, webhooks and event publications. Make uncertain outcomes visible for reconciliation.
- R5. Keep GitHub polling, cache invalidation, budgets and webhook behavior aligned with `website/docs-app/apis/github.md`; measure claimed savings against real traffic and count the production population a change reaches.
- R6. Define package ownership by responsibility and stable contracts. A component moves only after its cross-boundary state, callbacks, startup order, failure recovery and test seam are explicit.
- R7. Decide keep, simplify, merge, cut or externalize for every inventoried user surface with usage evidence and a skeptical challenge for every cut, merge or externalization. Preserve a used behavior until its replacement passes acceptance.
- R8. Reduce physical source and test lines through removed duplication, unnecessary paths and cohesive decomposition. Moving code between files or repositories is reported separately from deletion and cannot be claimed as a line-count saving.
- R9. Enforce a hard limit of 500 physical lines for each tracked text file in the completed refactor, including generated, vendored, documentation and test text. Prefer files at or below 200 lines; require a cohesion rationale above that preference. No permanent generated or vendor exemption is assumed.
- R10. Give Muse the same explicit lifecycle, delivery, authority and usage ownership as other backends without expanding its unsupported capabilities. Keep the newly accepted native path in regression coverage during shared extraction.
- R11. Migrate in independently reviewable units with characterization of current behavior, regression tests that fail without each behavior change, and a running CLI/TUI check for user-visible flows.
- R12. Publish a traceable decision and evidence record: frozen revision, source finding IDs, contradictory measurements, privacy-safe reproduction, open questions, and acceptance results for each unit.

### Actors and flows

- F1. The Executor starts or resumes a run, sees accurate progress and stale/unknown evidence, responds to an attention, and observes delivery or failure.
- F2. An agent starts in its own workspace, receives a message or tool result once, pauses or restarts, and resumes without losing or duplicating work.
- F3. A developer changes a component behind a stable contract, runs its focused tests and repository gates, and checks the line-count ledger moves toward zero.

### Acceptance examples

- AE1. Given a lost or delayed publication receipt, the Executor sees an uncertain delivery state with correlation identifiers and a safe reconciliation path, rather than a confident success or duplicated action.
- AE2. Given a paused agent with a queued operator message, resume delivers it once and the running chat pane shows the resulting assistant response.
- AE3. Given an oversized tracked text file, the completed CI gate fails with its path and physical line count; a cohesive decomposition under 500 lines passes, and files above 200 prompt a documented review.
- AE4. Given a proposed cut of an apparently unused surface, the decision includes the counted observation population, a search for indirect use, a skeptic result and a migration or removal test.
- AE5. Given a proposed quota or latency saving, the review can trace its measured baseline, units, reachable production population and the merge-time conditions required for the saving.

### Scope boundaries and current evidence

This contract covers research, planning and later implementation of the refactor. It does not itself authorize a mass rewrite, fleet operation or deletion of user data. The research corpus at `docs/research/refactor-2026-09-26/` records 60 claim pairs, 29 of 32 review units, 33 of 91 feature challenges and the full file-size census. These are artifact counts, not a claim that the remaining verdicts or raw findings are correct. The P0/P1 location audit establishes readable spans for 177 of 182 findings; five citations require correction, and all 182 semantic and severity checks remain open.
