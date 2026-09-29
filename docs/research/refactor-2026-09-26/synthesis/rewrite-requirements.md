# Evidence-backed rewrite requirements

The full [requirements framing](../../../brainstorms/2026-09-29-aiur-refactor-requirements.md)
and [phased CE plan](../../../plans/2026-09-29-001-refactor-production-readiness-plan.md)
own implementation detail. This page binds the research findings to the
minimum behavior and acceptance constraints; it authorizes no product edit.

1. **Progress and ownership.** One accountable lifecycle decision must join
   tracker labels, review/CI evidence, delivery, fences and slots. Actionable,
   waiting, stale, unknown and uncertain outcomes must remain distinct with
   observed age. Validate against the recorded parked-rework timelines and
   failure injection. [Problem map](problem-map.md), [review](../review/code-review.md).
2. **Durable delivery.** Events, commands, reviews, wakes and external
   mutations need identity, ordering, bounded retry, acknowledgement and
   action receipts across restart. A cursor advance alone is not completion.
   [Verified claims](verified-claims.md), [contradictions](contradictions.md).
3. **Agent and backend continuity.** Replace unconditional continuation with
   a condition-driven wait while preserving throughput, pause containment,
   native Muse and accepted backend behavior. Measure redundant turns and
   provider use on actual traffic before claiming savings. [Problem map](problem-map.md),
   [feature inventory](../features/feature-inventory.md).
4. **GitHub correctness and trust.** Preserve complete or explicitly
   incomplete reads, monotonic cache writes, webhook fallback and credential
   budget admission. Choose degraded CODEOWNERS trust before restructuring
   authorization. [Contradictions](contradictions.md), [review](../review/code-review.md).
5. **Evidence-backed simplification.** Recheck all 216 feature decisions on
   the implementation base. Challenge dynamic use and operator value before
   deletion. Remove old owners and duplicate paths when merging; moved code
   is not a saving. PR #2840 and #2841 release removals are outside the future
   refactor ledger. [Feature catalog](../features/features.json),
   [LOC scenarios](../features/loc-reduction.md).
6. **Cohesive file sizes.** The final automated gate covers every tracked
   UTF-8 text file, including docs, tests, skills, generated and vendor text:
   500 physical lines passes and 501 fails. Above 200 requires a cohesion
   explanation. The corrected frozen baseline counts 359 files above 500 and
   1,192 above 200; every tracked path and line count reproduces. The
   [owner map](oversized-file-owner-map.md) proposes a disposition for all 359
   paths. Confirm each semantic seam before retiring the counted debt.
   No arbitrary line-slice modules or permanent exclusions.
   [Census](file-size-analysis.md).
7. **Acceptance and measured outcome.** Run the real foreground CLI/TUI for
   user-visible flows, required CI/browser/release checks, and production-hunk
   red/green tests for changed behavior. Report before/after physical lines
   by area, excluding relocated lines, plus observed baselines and reachable
   populations for any quota or latency saving. [CE plan](../../../plans/2026-09-29-001-refactor-production-readiness-plan.md),
   [LOC report](../features/loc-reduction.md).

Historical gap categories are not causal shares. The
[causal timeline](causal-gap-attribution.md) establishes local prewarm and
dependency point causes but cannot allocate the 151-hour gap or 78.18%
waiting-model share. Prospective instrumentation must support later causal
duration claims.
