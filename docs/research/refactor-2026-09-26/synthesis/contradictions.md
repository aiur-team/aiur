# Contradictions to settle before the refactor

The detailed [report-wide contradiction audit](report-wide-contradictions.md)
compares recommendations across all 32 raw code-review units, 986 canonical
planning findings and the corrected source reports. Its conflicts are design
decisions, not additional bug counts. The [60-claim audit](claim-question-audit.md)
and [verified claims](verified-claims.md) govern historical interpretations.

| Tension | Required reconciliation | Evidence |
| --- | --- | --- |
| Several status/dashboard proposals add a snapshot, cache or loader. | Name one field owner and timestamp; derived CLI/web views must preserve unknown and stale states. | `loose-2-02`, `orch-b-01`, `web-rest-02` in the [audit](report-wide-contradictions.md). |
| GitHub parser, membership and quota proposals touch the same read path. | Keep completeness with the reader, monotonicity with the store and admission with the credential budget; decide degraded CODEOWNERS trust explicitly. | `github-a-01/02/04/07`, `github-b-02/04` in the [audit](report-wide-contradictions.md). |
| Journal, projection and file writers propose different retry/fail-closed rules. | Distinguish durable authority from rebuildable views before choosing quarantine, retry or stop-write behavior. | `loose-1-02/03`, `platform-misc-09`, `loose-4-04` in the [audit](report-wide-contradictions.md). |
| Backend session, turn and queue extractions could create another broad coordinator. | Assign process lifecycle, turn settlement, queue persistence and ETS ownership separate cohesive contracts. | `agent-backends-cc-04`, `agent-runtime-01/02`, `agent-backends-oc-11` in the [audit](report-wide-contradictions.md). |
| Raw gap buckets and review titles invite stronger causal/severity claims than the evidence supports. | Use corrected denominators, local point diagnoses and reviewed severities; leave unproved causal hours and lower-priority incidence provisional. | [Causal timeline](causal-gap-attribution.md), [claim audit](claim-question-audit.md), [review](../review/code-review.md). |

The [CE plan](../../../plans/2026-09-29-001-refactor-production-readiness-plan.md)
turns these into phased decisions and acceptance checks. Do not implement each
finding's example helper as a separate new owner; the desired result is fewer
competing paths and a measured net line change.
