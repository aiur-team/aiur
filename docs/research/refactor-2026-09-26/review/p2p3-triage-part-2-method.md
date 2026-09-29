# P2/P3 semantic triage, partition 2

This file accompanies `p2p3-triage-part-2.json`. It covers exactly 297 findings, sorted by ID from `review/findings.json` and indexed 297–593 inclusive (`loose-1-10` through `skills-prompts-cont-36`). The source comparison target is public `origin/main` at `3339b887196d5e9aefb273117a14bf33391ee41f`, which still matches the frozen research source commit.

## Method and limits

For each finding I read its title, description, recommendation, and cited public source ranges. I checked all 1,481 cited ranges against current main: every path exists and every start line is within the file. The JSON records selected source anchors and the original candidate remedy. Quoted string literals in anchors are redacted, so the file does not republish runtime values or private data. The excerpts are a navigation aid; a matching name or constant alone does not prove a behavioral consequence.

`source-supported` means the cited static code supports a mechanism in the claim. It does **not** establish incidence, production impact, magnitude, or that the candidate remedy is safe. `unknown` means the cited excerpts and available static read do not settle the full claim, especially negative assertions, complete caller counts, timing, and cross-document conflicts. No row is `stale` because the checked main commit has not moved beyond the frozen source. No row is `unsupported` because I found no decisive contradictory source evidence in this partition. The disposition is a proposal: `fix` marks an apparent functional or correctness issue for a focused change and regression test; `defer` requires the verification in `proposed_action` before promotion. It is not a release gate by itself.

Result: **139 source-supported, 158 unknown; 13 proposed fix, 284 defer, 0 close**. All 297 rows have current-head caveats and concrete source citations. The absence of runtime tests means none of these statuses should be read as a measured saving or observed failure rate. Recheck current main after the pending release and merge work; especially check the guard-removal finding `nonelixir-shell-29` before closing it.

## Next verification

Resolve `unknown` records with full caller and control-flow review, targeted reproduction for failure claims, and direct checks of any negative or counted claim. For the 13 `fix` proposals, create a small behavior test that fails before the product change. Keep source-supported simplification candidates in the plan only after mapping their owning boundary and proving no behavior loss. Reconcile dispositions with the other two partitions before changing `review/findings.json` or treating this as an implementation queue.
