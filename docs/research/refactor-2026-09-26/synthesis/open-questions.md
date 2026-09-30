# Open decisions and evidence limits

The [CE plan](../../../plans/2026-09-29-001-refactor-production-readiness-plan.md)
remains `requirements-only`. These questions gate the affected implementation
units; they are not reasons to change current product behavior speculatively.

| Question | Current evidence | Required resolution |
| --- | --- | --- |
| Which process owns the authoritative ticket transition? | Rework/label/fence findings show competing writers and parked entries. [Problem map](problem-map.md), [review](../review/code-review.md). | Name the owner, durable replay/idempotency rule and failure behavior before U2. |
| How does degraded CODEOWNERS/team resolution affect trust? | KTD9 in the [plan](../../../plans/2026-09-29-001-refactor-production-readiness-plan.md) now chooses fail-closed for unknown people and stale team membership while preserving explicit trusted accounts, sanitized Executor visibility, and cause/age. The [current-main trust audit](codeowners-current-main-2026-09-30.md) identifies a silent team-read failure, indefinitely cached path membership, and single-page path reads. | Prove incomplete path/team context, daemon and repository-owner exceptions, and agent-digest exclusion with current-head failure tests before GitHub boundary work. |
| Which store errors stop writes? | KTD10 distinguishes an authoritative fsynced Decision journal append from a rebuildable stale projection; it defines failed/ambiguous append and corrupt-record behavior. The [current-main journal audit](decision-journal-current-main-2026-09-30.md) found ambiguous sync retries and a request notification that crosses projection failure. Other stores still need their own authority tests. | Exercise journal/projection failure and replay, then name per-store authority, notification policy and operator-visible health for affected U3/U6 work. |
| What is the first package seam? | KTD11 chooses the existing in-process GitHub access layers; the 35/36-boundary source-reference component is not extraction proof. The [current-main seam audit](github-access-seam-current-main-2026-09-30.md) identifies pagination, deposit, checkpoint and ambiguous-mutation proof gates. [Architecture verification](architecture-verification.md). | Prove caller, startup and failure parity in-process before proposing a physical package in U7. |
| Which frozen findings still occur on merged main? | All 1,033 source IDs are retained; the 182 inherited P0/P1 source IDs have frozen skeptics. At `main@b4bc11f`, two reviewers classified all 94 canonical P1 findings and two more reconciled their 12 label disagreements at the source level. P2/P3 dispositions remain provisional. [Current-main review](merged-main-b4bc-review.md). | Run the named behavior and population gates on the implementation base before promoting affected findings; static reachability alone does not preserve P1 severity. |
| Can historical idle hours be assigned to a root cause? | Direct point evidence exists for prewarm and six dependency declines; the 151-hour gap and 78.18% waiting model have no minute-level causal proof. [Causal timeline](causal-gap-attribution.md). | Do not allocate retained hours by guess. Instrument positive runnable demand, admission, daemon identity and action receipts prospectively. |
| Which feature cuts save real net lines? | Twelve frozen conditional scenarios cover 51 files and 17,944 gross lines; [ui-29](ui29-current-main-2026-09-30.md) and [usage compaction](usage-compaction-current-main-2026-09-30.md) have current-main checks, but no implementation diff exists. | Recheck use, compatibility and replacement on final release main; measure removed plus added lines after implementation. |
| How will every oversized file reach the cap? | The frozen map has 359 paths. At `main@b4bc11f`, 355 mapped paths remain >500, four are deleted, and two tests are newly oversized: 357 total. The [owner delta](owner-map-b4bc-delta.csv) records 63 changed counts and the new owners. | Refresh on final release main, validate indirect consumers and semantic seams, then enact transitional and universal gates. |

The branch-tip [privacy/provenance audit](privacy-provenance-audit.md) is
complete under its aggregate-only rule, and the later b4bc checkpoint
received a separate privacy and source check. New public tickets and artifacts
still need source-level review. The deletion guard and GitHub cache dashboard
removals have merged but await 0.0.7 publication; their lines must not enter
future refactor savings.
