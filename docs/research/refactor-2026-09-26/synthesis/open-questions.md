# Open decisions and evidence limits

The [CE plan](../../../plans/2026-09-29-001-refactor-production-readiness-plan.md)
remains `requirements-only`. These questions gate the affected implementation
units; they are not reasons to change current product behavior speculatively.

| Question | Current evidence | Required resolution |
| --- | --- | --- |
| Which process owns the authoritative ticket transition? | Rework/label/fence findings show competing writers and parked entries. [Problem map](problem-map.md), [review](../review/code-review.md). | Name the owner, durable replay/idempotency rule and failure behavior before U2. |
| How does degraded CODEOWNERS/team resolution affect trust? | Parser, pagination and snapshot recommendations conflict under stale or unavailable membership. [Contradictions](contradictions.md). | Decide stale-trust duration versus fail-closed behavior before GitHub boundary work. |
| Which store errors stop writes? | Durable journals and rebuildable projections have different consequences. [Contradictions](contradictions.md). | Choose per-store authority, retry, quarantine and operator-visible health before U3. |
| What is the first package seam? | A 35/36-boundary source-reference component is a warning, not runtime proof. [Architecture verification](architecture-verification.md). | Count current cross-boundary calls and specify startup, state, failure isolation and reversible extraction before U7. |
| Which frozen findings still occur on merged main? | All 1,033 source IDs are retained, 182 inherited P0/P1 IDs have two skeptics; 851 P2/P3 source IDs lack that independent check. [Review](../review/code-review.md), [current-head validation](current-head-validation-2026-09-28.md). | Reproduce reachable current-head population and disposition each actionable finding before implementation tickets. |
| Can historical idle hours be assigned to a root cause? | Direct point evidence exists for prewarm and six dependency declines; the 151-hour gap and 78.18% waiting model have no minute-level causal proof. [Causal timeline](causal-gap-attribution.md). | Do not allocate retained hours by guess. Instrument positive runnable demand, admission, daemon identity and action receipts prospectively. |
| Which feature cuts save real net lines? | Twelve conditional scenarios cover 51 distinct files and 17,944 gross lines; no implementation diff exists. [LOC report](../features/loc-reduction.md). | Recheck use, compatibility and replacement on current main; measure removed plus added lines after implementation. |
| How will every oversized file reach the cap? | Corrected frozen census lists 359 verified text files >500; the [owner map](oversized-file-owner-map.md) proposes 344 splits, eight regenerate/replace paths and seven conditional removals. | Refresh on merged main, validate indirect consumers and semantic seams, then enact transitional and universal gates. |

The branch-tip [privacy/provenance audit](privacy-provenance-audit.md) is
complete under its aggregate-only rule. New public tickets and artifacts still
need source-level review. The 0.0.6 deletion guard/cache dashboard removals
remain release prerequisites until merged and published; their lines must not
enter future refactor savings.
