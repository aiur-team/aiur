# Claim and research-question audit

Checked against the frozen research artifacts at source revision `3339b887`.
This audit tests **artifact consistency and interpretation**, not whether all
historical source data can be recollected today. The six source reports preserve
their original measurements for provenance; corrected lead text should govern
planning. Do not infer live incidence from a frozen verdict.

## All 60 claims and both lenses

`tooling/research_inventory.py` reports 60 expected claim IDs, 81 verdict
records, all 60 with both a reproduction and an interpretation lens, and no
missing ID. Some records contain both lenses; earlier `done.json` entries hold
them separately. I independently matched the 60 rows in
[`verified-claims.md`](verified-claims.md) to the verdict JSON: **60/60 IDs,
120/120 lens values, zero missing or contradictory table values, zero extra
verdict IDs**. This checks the summary's transcription, not the underlying
methods or all historical observations. The source-verdict corrections are
linked per claim in that table.

| Family | Claims | Reproduction original held | Interpretation original held | Result for source report |
| --- | ---: | ---: | ---: | --- |
| Census | 10 | 9 | 5 | Correct window and denominator language; do not equate raw PR closure with failed work. |
| Recurring issues | 10 | 1 | 1 | Selected, overlapping reports and cursor lag cannot rank causal cost or prove no observation. |
| Idle gaps | 10 | 1 | 0 | Keep classifier outputs distinct from causal attribution and calendar idle time. |
| Merged fixes | 10 | 4 | 0 | Selected recurrences do not prove a universal fix rule or comparative effectiveness. |
| Agent sessions | 10 | 2 | 0 | Correct turn duration, provider-mix and shared-limit inferences. |
| Codebase boundaries | 10 | 3 | 1 | Separate source-reference graphs and revisions from runtime coupling and extraction feasibility. |
| **Total** | **60** | **20** | **7** | Original wording requires correction or caveat for most claims. |

The six reports have been edited in this branch at their misleading lead or
headline statements:

- [`../census/census.md`](../census/census.md): the repo-wide event endpoint's
  July floor is not a loss of per-issue May labels; at least 27 July-merged
  PRs have retained agent sessions; top-level meta-file absence is not a
  global hourly-check absence; 277/1,246 raw closed-unmerged PRs include
  fixtures, develop-branch closures and supersessions; historical capacity
  bursts are not a current wake rate.
- [`../meta/recurring-issues.md`](../meta/recurring-issues.md): the selected 50
  dated records overlap and include a record-keeping gap; 1,529 above-cursor
  wakes are unacknowledged, not proved unread or unacted on; ranking by
  stated costs is not a comparative census.
- [`../gaps/gap-analysis.md`](../gaps/gap-analysis.md): the 75.65% modeled
  no-selected-progress share is not all-calendar idle time; the 66% waiting
  category is a precedence classifier, not a causal human-absence share.
- [`../fixes/merged-fixes.md`](../fixes/merged-fixes.md): selected later reports
  and held examples do not establish a universal dead-process latch pattern
  or a comparative rule that deleting authority always wins.
- [`../agents/agent-failure-modes.md`](../agents/agent-failure-modes.md):
  12,768 continuation turns took about 20 measured turn-hours, not 186;
  2.5 billion is a mostly cached token-event sum, not a saving; one khala
  loop contributed to a shared Claude limit without proving sole causation.
  The deletion-guard command is historical and being removed from the release.
- [`../codebase/feature-boundaries.md`](../codebase/feature-boundaries.md):
  35/36 boundary connectivity is a static source-reference result; the
  original scanner counts 99 mutual pairs and the independent AST check 98
  at the surveyed revision. Neither count proves extraction impossible.

These are corrections to *interpretation*. Historical data cells remain where
they are needed to reproduce the earlier analysis. The source reports still
contain case-level historical language; the linked verdicts remain the
authority if a later sentence conflicts with the corrected lead.

## Eight README research questions

| # | Question | Evidence present | Remaining boundary |
| --- | --- | --- | --- |
| 1 | Census | [`../census/census.md`](../census/census.md) and datasets count issues, PRs, workspaces, sessions, handoffs, run logs and wakes per repo. | Windows differ; local sessions are lower bounds. Do not compare raw counts as complete lifetime populations. |
| 2 | Recurring problems | [`../meta/recurring-issues.md`](../meta/recurring-issues.md) has a taxonomy and case records. | Selected, overlapping documents support qualitative recurrence, not a causal frequency/cost ranking. |
| 3 | Idle gaps | [`../gaps/gap-analysis.md`](../gaps/gap-analysis.md) has 202 >=15-minute modeled gaps, 108 >=30-minute gaps and corrected duration fields. | "Each gap attributed to a cause" remains **partial**: classifier labels and missing progress events do not establish root cause or whether actionable work was pending. |
| 4 | Merged fixes | [`../fixes/merged-fixes.md`](../fixes/merged-fixes.md) traces selected held and recurrent cases. | The case set cannot compare all fix strategies or prove that one mechanism explains every recurrence. |
| 5 | Agent failure modes | [`../agents/agent-failure-modes.md`](../agents/agent-failure-modes.md) contains the retained-session taxonomy. | Corrected 20-hour turn-time and provider-mix readings govern; transcript retention limits population claims. |
| 6 | Feature boundaries | [`../codebase/feature-boundaries.md`](../codebase/feature-boundaries.md) surveys candidate boundaries and dependency graphs. | Package feasibility, runtime ownership and LOC reduction remain implementation hypotheses. |
| 7 | Code review | [`../review/code-review.md`](../review/code-review.md) and `review/findings.json` cover 32 units and 1,033 source IDs; two skeptics checked all 182 inherited P0/P1 IDs. | The 851 inherited P2/P3 IDs are provisional; current-head/runtime checks are needed before tickets. |
| 8 | Feature inventory and cut case | Five raw inventories contain 216 features; all 91 proposed cut/merge/externalize decisions have skeptic checks. The reconciled [`feature-inventory.md`](../features/feature-inventory.md), [`usage-matrix.md`](../features/usage-matrix.md), [`loc-reduction.md`](../features/loc-reduction.md) and [`features.json`](../features/features.json) are now published. | The 17,944-line whole-file footprint is conditional gross deletion potential, not implemented net savings; recheck current usage and source before removal. |

The causal part of question 3 remains incomplete; question 8 now has a frozen
feature/LOC planning synthesis, but no measured implementation saving. The
next plan should explicitly carry these limits and the
user's hard 500-line gate with a 200-line preference; it must not infer a
saving from code movement, a cache classifier or a disabled setting.
