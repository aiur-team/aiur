# Verified claims and corrections

This is the synthesis of the 60 claims in the six source reports. Every claim
has a reproduction check and an interpretation check in `verdicts/`; the table
below links to the saved evidence. `No` means the inherited wording or
inference did not hold, not that its underlying problem disappeared. Several
checks were performed sequentially by the continuing researcher, and recovered
provenance is labelled in the verdict records; artifact coverage does not turn
them into independent experiments. The code review's two independent skeptic
passes are tracked separately.

## What the evidence supports

**Census.** The retained local histories are incomplete and have different
windows. aiur merged 136 PRs in September 1–26 against 499 in August, while
intake fell and per-PR health improved; the raw merge drop is not a measure of
fleet efficiency. Most closed-unmerged PRs in the large historical count were
sandbox, develop-branch or superseded cases. Wake streams contain many repeated
attention records, often scheduled re-asks of one open condition. A wake line
is not an Executor turn, and an above-cursor line is not proof nobody read it.
See claims `census-01` through `census-10` for denominators and exceptions.

**Recurring issues.** The 50-row issue register is a selected, overlapping
incident set, not 50 independent idle intervals. Durable wake cursors were
bypassed by notification-only monitoring; cursor position measures
acknowledgement, not necessarily observation or action. Historical alert
storms were mostly pre-fix windows. Rework routing and release identity remain
real operational concerns, but merged source, checkout, assembled release and
running daemon must be distinguished. Skill size and retrospective cadence
claims were corrected against the frozen revision and retained records.
See `meta-01` through `meta-10`.

**Idle gaps.** The retained model has 108 gaps of at least 30 minutes totalling
727.73 exact hours; five gaps of at least 24 hours account for 447.86 hours.
The original bucket shares are classifier outputs, not causal ownership. In the
current-era aiur/khala subset, 38.5 hours were labelled stranded, but about
18.9 hours were active khala agents waiting on repository write permission.
About 18.5 hours have stronger evidence of genuinely undispatched rework,
chiefly aiur #2678's parked entry and open lifecycle fence. Compaction and
session-limit associations are observational and confounded. See `gaps-01`
through `gaps-10`; do not turn their overlapping durations into additive
savings claims.

**Merged fixes.** The selected fixes show recurring state ownership problems:
several independent writers of `agent:rework`, a lifecycle fence that normally
closes only after provider delivery, per-entry fleet-slot reservation rules,
and GitHub response-size and local-budget errors interpreted differently by
callers. The evidence supports consolidating explicit authority and typed
outcomes, while specific before/after cases do not establish a universal
rewrite rule or measured saving. See `fixes-01` through `fixes-10`.

**Agent sessions.** A real continuation loop remains, but the earlier 186-hour
no-op-turn figure included gaps before the next run; measured turn time is about
20 hours for 12,768 short continuation turns. The pattern is concentrated in
Codex and a few threads; the weekly drop and rebound are explained largely by
provider mix and concentration, not by a fix that later regressed. The
khala #230 loop contributed to a Claude account limit but did not alone cause
the fleet outage. Recovery, guard-command and error-taxonomy findings retain
important narrower conclusions. See `agents-01` through `agents-10`.

**Codebase boundaries.** The frozen survey has a large strongly connected
reference graph and concentrated Orchestrator/GitHub coupling, but graph
reachability does not prove a package cannot be extracted. The 100-field
Orchestrator state, mixed Tracker callbacks and several synchronous control
paths justify smaller ownership boundaries. Exact module/edge counts differ
between the original text scanner and the independent AST scanner; the report
and verdicts retain both methods and revisions. Attention-topic samples are
not a complete lost-alert or idle-time measurement. See `codebase-01` through
`codebase-10`.

## Claim audit index

The linked verdicts contain the full corrected claim, method, contrary
examples, revision and limits. `Yes/No` below refers to whether the original
claim survived each check. A claim can have valid arithmetic (`Yes`) and an
invalid causal reading (`No`).

| Claim and evidence | Reproduction | Interpretation | Correction |
| --- | --- | --- | --- |
| `agents-01` ([done.json](verdicts/done.json)) | No | No | Revised |
| `agents-02` ([done.json](verdicts/done.json)) | No | No | Revised |
| `agents-03` ([done.json](verdicts/done.json)) | Yes | No | Revised |
| `agents-04` ([done.json](verdicts/done.json)) | Yes | No | Revised |
| `agents-05` ([done.json](verdicts/done.json)) | No | No | Revised |
| `agents-06` ([done.json](verdicts/done.json)) | No | No | Revised |
| `agents-07` ([done.json](verdicts/done.json)) | No | No | Revised |
| `agents-08` ([done.json](verdicts/done.json)) | No | No | Revised |
| `agents-09` ([done.json](verdicts/done.json)) | No | No | Revised |
| `agents-10` ([claims-interpretation-tail.json](verdicts/claims-interpretation-tail.json), [done.json](verdicts/done.json)) | No | No | Revised |
| `census-01` ([claims-census-1.json](verdicts/claims-census-1.json)) | No | Yes | Revised |
| `census-02` ([claims-census-1.json](verdicts/claims-census-1.json)) | Yes | Yes | Revised |
| `census-03` ([claims-census-1.json](verdicts/claims-census-1.json)) | Yes | No | Revised |
| `census-04` ([claims-census-2.json](verdicts/claims-census-2.json)) | Yes | Yes | Retained with caveats |
| `census-05` ([claims-census-2.json](verdicts/claims-census-2.json)) | Yes | Yes | Retained with caveats |
| `census-06` ([claims-census-2.json](verdicts/claims-census-2.json)) | Yes | No | Revised |
| `census-07` ([claims-census-3.json](verdicts/claims-census-3.json)) | Yes | No | Revised |
| `census-08` ([claims-census-3.json](verdicts/claims-census-3.json)) | Yes | No | Revised |
| `census-09` ([claims-census-3.json](verdicts/claims-census-3.json)) | Yes | Yes | Retained with caveats |
| `census-10` ([claims-census-4.json](verdicts/claims-census-4.json)) | Yes | No | Revised |
| `codebase-01` ([done.json](verdicts/done.json)) | Yes | No | Revised |
| `codebase-02` ([claims-codebase-structure.json](verdicts/claims-codebase-structure.json)) | No | No | Revised |
| `codebase-03` ([claims-codebase-structure.json](verdicts/claims-codebase-structure.json)) | No | No | Revised |
| `codebase-04` ([claims-codebase-structure.json](verdicts/claims-codebase-structure.json)) | No | No | Revised |
| `codebase-05` ([claims-codebase-structure.json](verdicts/claims-codebase-structure.json)) | No | No | Revised |
| `codebase-06` ([claims-codebase-structure.json](verdicts/claims-codebase-structure.json)) | Yes | No | Revised |
| `codebase-07` ([claims-codebase-routing.json](verdicts/claims-codebase-routing.json)) | No | No | Revised |
| `codebase-08` ([claims-codebase-control.json](verdicts/claims-codebase-control.json)) | No | No | Revised |
| `codebase-09` ([claims-codebase-control.json](verdicts/claims-codebase-control.json)) | No | No | Revised |
| `codebase-10` ([claims-codebase-structure.json](verdicts/claims-codebase-structure.json)) | Yes | Yes | Revised |
| `fixes-01` ([done.json](verdicts/done.json)) | No | No | Revised |
| `fixes-02` ([done.json](verdicts/done.json)) | No | No | Revised |
| `fixes-03` ([done.json](verdicts/done.json)) | No | No | Revised |
| `fixes-04` ([done.json](verdicts/done.json)) | Yes | No | Revised |
| `fixes-05` ([done.json](verdicts/done.json)) | Yes | No | Revised |
| `fixes-06` ([done.json](verdicts/done.json)) | No | No | Revised |
| `fixes-07` ([done.json](verdicts/done.json)) | Yes | No | Revised |
| `fixes-08` ([done.json](verdicts/done.json)) | No | No | Revised |
| `fixes-09` ([claims-interpretation-tail.json](verdicts/claims-interpretation-tail.json), [done.json](verdicts/done.json)) | No | No | Revised |
| `fixes-10` ([done.json](verdicts/done.json)) | Yes | No | Revised |
| `gaps-01` ([claims-gaps-headline.json](verdicts/claims-gaps-headline.json)) | No | No | Revised |
| `gaps-02` ([claims-gaps-attribution.json](verdicts/claims-gaps-attribution.json)) | Yes | No | Revised |
| `gaps-03` ([claims-gaps-prewarm.json](verdicts/claims-gaps-prewarm.json)) | No | No | Revised |
| `gaps-04` ([claims-gaps-largest.json](verdicts/claims-gaps-largest.json)) | No | No | Revised |
| `gaps-05` ([claims-gaps-prewarm.json](verdicts/claims-gaps-prewarm.json)) | No | No | Revised |
| `gaps-06` ([claims-gaps-dependencies.json](verdicts/claims-gaps-dependencies.json)) | No | No | Revised |
| `gaps-07` ([claims-gaps-downtime.json](verdicts/claims-gaps-downtime.json)) | No | No | Revised |
| `gaps-08` ([claims-gaps-boundaries.json](verdicts/claims-gaps-boundaries.json)) | No | No | Revised |
| `gaps-09` ([claims-gaps-wake-consumption.json](verdicts/claims-gaps-wake-consumption.json)) | No | No | Revised |
| `gaps-10` ([claims-gaps-12.json](verdicts/claims-gaps-12.json)) | No | No | Revised |
| `meta-01` ([claims-meta-5.json](verdicts/claims-meta-5.json)) | No | No | Revised |
| `meta-02` ([claims-meta-5.json](verdicts/claims-meta-5.json)) | Yes | No | Revised |
| `meta-03` ([claims-meta-5.json](verdicts/claims-meta-5.json)) | No | No | Revised |
| `meta-04` ([claims-meta-6.json](verdicts/claims-meta-6.json)) | No | No | Revised |
| `meta-05` ([claims-meta-6.json](verdicts/claims-meta-6.json)) | No | No | Revised |
| `meta-06` ([claims-meta-6.json](verdicts/claims-meta-6.json)) | No | Yes | Revised |
| `meta-07` ([claims-meta-dispatch.json](verdicts/claims-meta-dispatch.json)) | No | No | Revised |
| `meta-08` ([claims-meta-deployment.json](verdicts/claims-meta-deployment.json)) | No | No | Revised |
| `meta-09` ([claims-meta-cadence.json](verdicts/claims-meta-cadence.json)) | No | No | Revised |
| `meta-10` ([claims-meta-review.json](verdicts/claims-meta-review.json)) | No | No | Revised |
