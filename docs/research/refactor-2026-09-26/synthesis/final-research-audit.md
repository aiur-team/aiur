# Requirement-by-requirement research audit

This audit compares the [original eight questions](../README.md), the
[handoff's completion sequence](../HANDOFF.md), and the
[continuation contract](../CONTINUATION.md) with branch-tip artifacts. It
audits frozen `3339b887` research, not implementation on current `main`.
Artifact presence and static reviews do not prove live incidence or a causal
share of historical idle time.

| Original research question | Disposition and evidence | Limit |
| --- | --- | --- |
| 1. Census | Complete for retained windows: [census](../census/census.md) counts tickets, PRs, workspaces, agent/Executor sessions, handoffs, meta and wakes by repository. The [claim audit](claim-question-audit.md) checks its ten headline claims. | Different history windows and local retention make lifetime comparisons lower bounds. |
| 2. Recurring problems | The [ranked taxonomy](../meta/recurring-issues.md) and 50-case register are published; [verified claims](verified-claims.md) correct prevalence/causality readings. | Selected, overlapping cases cannot rank total causal hours by problem. |
| 3. Idle gaps | The [gap report](../gaps/gap-analysis.md) contains 202 intervals ≥15 minutes and 108 ≥30 minutes, with corrected attendance and denominator. The [causal timeline](causal-gap-attribution.md) records direct prewarm/dependency point causes and the bounded host-interruption observation. | **Partial against the literal request to attribute every gap to a cause.** The 151.3621-hour gap and 78.18% waiting-model share lack per-minute causal proof. No honest retrospective assignment is possible from the retained sources; prospective admission, uptime and action receipts are needed. |
| 4. Merged fixes | The [fix history](../fixes/merged-fixes.md) traces selected held and recurrent changes; ten claims received both checks. | It does not prove one universal repair strategy or comparative effectiveness. |
| 5. Agent failure modes | The [session analysis](../agents/agent-failure-modes.md) and ten checked claims distinguish 12,768 short continuation turns from the approximately 20 measured turn-hours. | Retained sessions and provider mix limit fleet-wide cost extrapolation. |
| 6. Feature boundaries | The [boundary survey](../codebase/feature-boundaries.md) and [architecture verification](architecture-verification.md) describe extraction candidates, revisions and graph methods. | Source-reference connectivity is not package feasibility or runtime incidence. |
| 7. Code review | All 32 planned units are represented by [1,033 raw source IDs reconciled to 986 findings](../review/code-review.md). The [lossless index](../review/findings.json) preserves every raw claim; two independent skeptics covered all 182 inherited P0/P1 IDs. [Boundary index](../review/by-boundary.md) and [contradiction audit](report-wide-contradictions.md) cover duplication and unnecessary complexity. | The 851 inherited P2/P3 source IDs lack the same independent skepticism. Frozen static findings require current-head exposure checks before tickets. |
| 8. Feature inventory and LOC | All 216 frozen features have use evidence and a working decision in the [catalog](../features/features.json); all 91 raw cut/merge/externalize proposals were challenged. [LOC scenarios](../features/loc-reduction.md) count 51 unique candidate files and 17,944 gross physical lines without double-counting shared feature labels. | Conditional deletion is not measured net reduction. Dynamic callers, replacement paths and operator value need current-head checks. |

## Cross-cutting completion contract

| Requirement | Audit result |
| --- | --- |
| Privacy and source provenance | [Branch-tip contextual review](privacy-provenance-audit.md) covers private-source contexts and corrections; [lexical checker](../tooling/privacy_check.py) passes. Prior public commits and unpublished journals remain outside branch-tip repair/reproduction. |
| 60 claim pairs and six source reports | [Claim/question audit](claim-question-audit.md) matches 60 IDs and 120 lens values; all six reports carry corrected lead readings. A verdict may preserve a narrower problem while rejecting its inherited headline. |
| Synthesis | [Verified claims](verified-claims.md), [problem map](problem-map.md), [contradictions](contradictions.md), [rewrite requirements](rewrite-requirements.md) and [open questions](open-questions.md) are published with detailed sources linked rather than duplicated. |
| Unnecessary complexity | The catalog classifies 24 working cuts, 10 merges, 110 simplifies, 5 externalizations and 67 keeps. These are frozen planning judgments; the [plan](../../../plans/2026-09-29-001-refactor-production-readiness-plan.md) requires current use, behavior parity and actual removed-versus-moved LOC before implementation. |
| Hard 500/preferred 200 lines | The corrected [frozen census](file-size-analysis.md) reproduces all 3,378 tracked paths, including 359 UTF-8 text files >500 and 1,192 >200. The [owner map](oversized-file-owner-map.md) covers all 359 with proposed dispositions: 344 split, eight regenerate/replace and seven conditional removals. The plan requires an automated universal 500-line gate, transitional counted debt and cohesion review above 200, including docs/tests/skills/vendor/generated text. The codebase does **not** meet the cap yet. |
| CE brainstorm → plan → deepen | [Requirements framing](../../../brainstorms/2026-09-29-aiur-refactor-requirements.md) and a [phased plan](../../../plans/2026-09-29-001-refactor-production-readiness-plan.md) exist. The plan is deliberately `requirements-only`; no documented implementation-ready deepen pass exists. Current-head incidence, validation of the proposed >500-file owner map, degraded CODEOWNERS trust, store durability choices and the first package seam remain blocking planning decisions. |

The frozen >500 owner map is now present, so the remaining plan blocker is
validation of those *proposed* semantic seams on merged main, alongside the
other listed policy and exposure decisions.

## Reproduction checks

- `tooling/research_inventory.py` reports 60/60 claims with both lenses,
  32/32 raw review units and 91/91 challenged feature candidates.
- `tooling/audit_review_synthesis.py` verifies exact raw-claim equality and
  one-time coverage of 1,033 source IDs in 986 canonical findings; 182 have
  two independent static reviews and 851 remain provisional.
- A fresh `tooling/file_size_census.py` run against the complete frozen
  snapshot matches the corrected saved JSON exactly: 3,378 tracked paths,
  3,293 text, 47 binary, 38 symlinks, 1,192 >200 and 359 >500. The owner-map
  CSV path/count set matches all 359 oversized rows exactly.
- `tooling/feature_loc_scenarios.py` reproduces 51 unique candidate files,
  17,944 gross lines and seven >500 paths; these are not net savings.
- `tooling/privacy_check.py` passes, and every relative Markdown link in the
  research tree resolves. No product test or foreground TUI run was claimed
  for this documentation-only research branch.

## Disposition

The frozen research corpus, review and feature/LOC synthesis are published.
The goal's literal per-gap causal attribution and CE deepen-plan completion
remain open. The former cannot be inferred from silence or classifier labels;
the latter needs the listed planning decisions and current-head validation.
No product behavior, universal 500-line compliance or net LOC saving is
claimed by this research branch. Keep the research goal open until those
acceptance decisions are made or the original per-gap requirement is revised.
