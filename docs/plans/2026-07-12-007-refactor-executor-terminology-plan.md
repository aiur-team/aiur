---
title: "refactor: Rename the aiur-driver role to Executor"
type: refactor
status: completed
date: 2026-07-12
---

# refactor: Rename the aiur-driver role to Executor

## Summary

Rename the aiur-driver role and dashboard product copy to “Executor” and “Executor Control Center” across shipped UI, messages, prompts, and current documentation, while preserving compatibility-sensitive internal protocol names and historical OCC references.

---

## Problem Frame

Aiur currently calls the person or agent driving a run the “operator.” The confirmed product language is now “Executor,” but that old term is spread across LiveView copy, alerts, agent prompts, public docs, current OCC contracts, and user-visible diagnostics. A partial rename would ship contradictory role names from different surfaces.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds.*

- Compatibility-sensitive internal identifiers and wire values such as `operator_messages`, `operator.progress_request`, `attention.operator-decision`, actor kind `:operator`, OCC ticket IDs, and the existing OCC directory/module paths remain unchanged unless a safe alias is already required by a user-facing surface.
- Historical artifacts under brainstorm, plan, refactor-research, diagnostic, and measurement archives are records of prior work and do not need prose rewrites; current product and OCC contract documentation does.
- The active #1033 dashboard-docs work will author new content with Executor terminology, so this branch should avoid duplicating its new page and screenshot work and inspect that branch before final CI.

---

## Requirements

- R1. The dashboard and all other shipped on-screen copy use “Executor” and “Executor Control Center,” with no aiur-driver role presented as “operator.”
- R2. User-facing alerts, diagnostics, help, prompts, examples, and agent tool descriptions use Executor terminology consistently.
- R3. Current public, contributor, configuration, dashboard, and event-model documentation uses Executor terminology while historical OCC IDs and branch references remain intact.
- R4. Internal compatibility contracts remain stable where renaming would create unnecessary churn or break persisted data, event routing, APIs, or in-flight work.
- R5. Focused tests and repository gates prove copy consistency without regressions.

---

## Scope Boundaries

- Do not rename historical OCC issue IDs, PR references, branch names, or the `occ` label.
- Do not mass-rename internal modules, functions, persisted actor values, queue sources, telemetry keys, DOM event names, or event topics solely for cosmetic consistency.
- Do not rewrite archival brainstorms, implementation plans, refactor research, diagnostics, or measurements that describe historical behavior.
- Do not duplicate #1033’s new dashboard documentation or screenshot deliverables.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur_web/components/operator_control_center/overview.ex`, `src/lib/aiur_web/components/layouts.ex`, and `src/lib/aiur_web/operator_control_center/revision_commands.ex` contain direct shipped dashboard copy.
- `src/lib/aiur/decision_attention.ex`, `src/lib/aiur/alert_feed.ex`, `src/lib/aiur/agent_runner.ex`, and `src/lib/aiur/orchestrator/` contain user-visible decisions, alerts, pause logs, and remediation messages.
- `src/prompts/shared-agent-instructions.md`, `.aiur/`, `.claude/skills/`, and `.codex/skills/` are shipped prompt/configuration surfaces that must teach the new role language while retaining literal protocol tokens where necessary.
- `README.md`, `src/README.md`, `SPEC.md`, `website/docs-app/`, `website/public/llms.txt`, and `docs/operator-control-center/` are current documentation surfaces.
- Related backend and UI work is already merged through #987 and #1026. #1022 is in CI on PR #1040; #1033 is active and coordinated through its workpad.

### Institutional Learnings

- The repository’s refactor research repeatedly identifies operator-message delivery as a fragile compatibility surface, supporting a copy-first rename instead of a broad identifier migration.

### External References

- None. Repository contracts and the Executor’s explicit naming decision are authoritative.

---

## Key Technical Decisions

- Apply a role-language rename, not a protocol migration: user-facing prose and copy become Executor, while stable identifiers remain readable legacy implementation details.
- Treat current OCC contract documents as living product documentation and update their prose/product name; preserve OCC ticket numbering and path names so existing links remain valid.
- Use targeted copy assertions and a final repository search, rather than introducing a new terminology abstraction for static strings.

---

## Open Questions

### Resolved During Planning

- Product name: the Executor confirmed “Executor Control Center.”
- Timing: OCC backend and capstone work are merged, so the coordinated sweep can proceed.
- Docs overlap: #1033 will use Executor terminology in newly authored dashboard docs; this ticket owns the existing-surface sweep.

### Deferred to Implementation

- Exact remaining matches that are true compatibility identifiers versus accidental user-facing prose will be classified during the final search after edits.

---

## Implementation Units

### U1. Rename shipped UI and runtime copy

**Goal:** Present Executor terminology consistently in the dashboard, decisions, alerts, diagnostics, logs, and other runtime-facing text.

**Requirements:** R1, R2, R4, R5

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur_web/components/layouts.ex`
- Modify: `src/lib/aiur_web/components/operator_control_center/`
- Modify: `src/lib/aiur_web/operator_control_center/`
- Modify: `src/lib/aiur/decision_attention.ex`
- Modify: `src/lib/aiur/alert_feed.ex`
- Modify: `src/lib/aiur/agent_runner.ex`
- Modify: affected user-visible copy under `src/lib/aiur/`
- Test: affected files under `src/test/aiur_web/` and `src/test/aiur/`
- Test: `src/test/aiur_web/live/dashboard_live_test.exs`
- Test: `src/test/aiur_web/operator_control_center_components_test.exs`
- Test: `src/test/aiur/decision_attention_test.exs`
- Test: `src/test/aiur/alert_feed_test.exs`
- Test: `src/test/aiur/core_test.exs`

**Approach:**
- Replace displayed product names, role labels, alert reasons, remediation text, and runtime documentation strings with Executor language.
- Preserve internal module paths, event handlers, actor enums, and compatibility tokens; update surrounding prose so those literals are clearly implementation contracts rather than role labels.

**Patterns to follow:**
- Existing exact-copy assertions in dashboard LiveView/component, decision-attention, alert-feed, and runner tests.

**Test scenarios:**
- Happy path: rendered dashboard title, brand aria label, and wordmark name the Executor Control Center.
- Happy path: decision and revision states that require human action display “Executor” follow-up/decision language.
- Integration: generated alert and pause/remediation messages reach their existing sinks unchanged except for Executor terminology.
- Compatibility: decision actor persistence and existing internal event/message routes still accept their established values.

**Verification:**
- Focused runtime and LiveView tests pass, and no shipped string literal presents the role as operator.

### U2. Rename current docs, prompts, examples, and operational guidance

**Goal:** Teach and describe the Executor role consistently across every current shipped documentation and prompt surface.

**Requirements:** R2, R3, R4

**Dependencies:** U1 for final terminology consistency

**Files:**
- Modify: `README.md`
- Modify: `src/README.md`
- Modify: `SPEC.md`
- Modify: `AGENTS.md`
- Modify: `src/prompts/shared-agent-instructions.md`
- Modify: `.aiur/`
- Modify: `.claude/skills/`
- Modify: `.codex/skills/`
- Modify: `website/docs-app/`
- Modify: `website/public/llms.txt`
- Modify: `docs/operator-control-center/`
- Modify: current examples and operational scripts containing user-facing guidance

**Approach:**
- Rename natural-language role references and the product name while retaining literal legacy protocol tokens, internal paths, and historical OCC identifiers.
- Keep mirrored Claude/Codex skill documentation synchronized.
- Avoid #1033’s new dashboard page and screenshot artifacts; inspect its pushed branch before the final gate.

**Patterns to follow:**
- Mirrored `.claude/skills` and `.codex/skills` content.
- Existing cross-links into `docs/operator-control-center/`, whose paths remain stable.

**Test scenarios:**
- Test expectation: none — this unit changes prose and static examples; repository search and docs/site builds provide verification.

**Verification:**
- Current docs and prompts consistently say Executor; only explicitly classified protocol identifiers or historical archives retain operator tokens.
- The website documentation production build succeeds after prose changes, and mirrored skill/prompt files remain synchronized.

### U3. Reconcile active docs work and validate the sweep

**Goal:** Integrate current upstream work, prove the rename is complete, and avoid conflicting changes with #1022/#1033.

**Requirements:** R3, R4, R5

**Dependencies:** U1, U2, #1022/#1033 inspection cues

**Files:**
- Modify: only conflict resolutions or terminology gaps introduced by current `main` and the inspected #1033 branch
- Test: all directly affected test files identified by U1

**Approach:**
- Merge current `main` immediately before final CI as requested, then repeat the role-term inventory against the merged tree.
- Inspect #1033’s validated branch/PR when available and coordinate any remaining shared-doc boundary without duplicating its feature work.
- Classify every residual match as compatibility identifier, historical reference, unrelated use of the English term, or defect; fix all defects.

**Patterns to follow:**
- Scoped pre-PR gate from repository instructions: compilation with warnings as errors, formatting, and affected tests with bounded concurrency.

**Test scenarios:**
- Integration: all affected tests pass after merging current main.
- Edge case: legacy internal tokens still route and decode as before even though surrounding user-facing prose says Executor.
- Documentation: the final inventory finds no unclassified user-facing operator-role reference.
- Documentation: the website and docs production build completes without broken links or rendering errors.

**Verification:**
- Scoped gate is green, final inventory is documented, and the branch contains no accidental #1022/#1033 feature duplication.

---

## System-Wide Impact

- **Interaction graph:** Static copy spans LiveView rendering, decision projection, alerts, prompts, docs, and configuration examples; behavior and routing remain unchanged.
- **Error propagation:** Existing error paths remain identical except for human-readable remediation terminology.
- **State lifecycle risks:** No persistence format or state transition is intentionally changed.
- **API surface parity:** Public prose changes across CLI, dashboard, website docs, prompt/tool descriptions, and current event-model docs together.
- **Integration coverage:** Focused runtime tests plus a final tracked-file inventory cover cross-surface parity.
- **Unchanged invariants:** Internal queue/message APIs, actor kinds, DOM events, event topics, and OCC references remain compatible.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A broad replacement mutates compatibility identifiers or historical records | Limit mechanical edits to natural-language word boundaries in current surfaces, then review every residual and changed token. |
| Active docs branches introduce conflicts or stale terminology | Watch #1022/#1033, avoid their new feature artifacts, merge current main before final CI, and re-run the inventory. |
| Tests assert old copy across many files | Use the inventory to identify affected tests, update only copy expectations, and run all directly related suites with bounded concurrency. |

---

## Documentation / Operational Notes

- “Executor Control Center” is the shipped product name; OCC remains a historical/internal wave abbreviation.
- The final PR should explain that legacy `operator_*` identifiers are intentionally retained for compatibility and diff containment.

---

## Sources & References

- Issue #1034 and confirmed Executor decision: https://github.com/its-everdred/aiur/issues/1034#issuecomment-4954756737
- Related UI/capstone work: #987, #1026
- Active docs coordination: #1022 / PR #1040, #1033
- Related code: `src/lib/aiur_web/`, `src/lib/aiur/decision_attention.ex`, `src/prompts/shared-agent-instructions.md`
