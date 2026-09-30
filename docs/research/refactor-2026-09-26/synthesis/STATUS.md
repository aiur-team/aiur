# Synthesis status — 2026-09-30

Research now lives on `research/refactor-findings`; the research-only files were removed from `main` by PR #2921. The [published v0.0.8 census](u0-v008-release-delta-2026-09-30.md) at `ed43c0e9` has 357 tracked UTF-8 paths over 500 lines, exactly matching the U8 assignment manifest. Since the previous checkpoint, only the reset module and its test grew. This is a source checkpoint only; U0 owner and caller gates and implementation-head behavior checks remain open. v0.0.8 was tagged and published to all four npm packages on 2026-09-30.

The foreground v0.0.8 acceptance run drove three dependent sandbox tickets through the actual TUI. Its second ticket exposed an answered blocking Command whose stopped worker was not reclaimed until a later poll and manual resume. [PR #2927](https://github.com/aiur-team/aiur/pull/2927) merged an answer-triggered normal-poll wake with a failing-before regression; the third ticket's answer was delivered and resolved while its worker was still active. This narrows the U3/U6 decision handoff question but does not prove replay across daemon restart or resolve the other #2818 strands. The three sandbox PRs [#2924](https://github.com/aiur-team/aiur/pull/2924), [#2926](https://github.com/aiur-team/aiur/pull/2926), and [#2928](https://github.com/aiur-team/aiur/pull/2928) merged after the release, so they do not change its census.

The later [released-main P0/P1 action ledger](high-priority-disposition-fc8270bb.md)
now gives all 97 canonical high-priority findings a provisional action and
component owner at `fc8270bb`: 84 `fix` (four already statically addressed in
the release), 12 `defer`, one `keep`, zero `invalid`. Its machine-readable rows
retain both skeptic severities, citation status, and remaining behavior or
decision gates. This supersedes the pre-merge high-priority disposition gap
described below; it does not convert source findings into observed incidents.

The [current-main citation update](merged-main-220b-static-update.md) rechecked
all 986 canonical findings after workspace recovery PR #2879 merged at
`220b8f253`. Relative to `04ef05c41`, thirteen citations moved from identical
to unknown in changed ownership code and tests. The current static counts are
698 identical, 37 stale and 251 unknown. These are review queues, not evidence
that the underlying behavior changed or that the findings occur in live runs.
The [Guardian safety gate](u5-guardian-fail-closed-current-main-2026-09-29.md)
rechecks one ownership finding on that main. A `:gen_statem` rewrite stays
deferred until a malformed receipt can be held durably per ticket without
allowing that ticket to dispatch or stopping unrelated tickets. Existing store
tests distinguish malformed bytes from an unreadable newer version; neither
proves that proposed per-ticket behavior.

The frozen-source research has a corrected 60-claim, two-lens audit, all 32
planned review units, a lossless 986-finding synthesis of 1,033 raw source IDs,
and a 216-feature inventory. The two independent skeptic lenses covered all
182 inherited P0/P1 source findings. See `claim-question-audit.md`,
`../review/code-review.md`, `../features/feature-inventory.md`, and
`final-research-audit.md` for the evidence and its limits.

The source-anchor audit checked all 986 canonical findings against pinned
`main` (`3339b887`). It corrected 30 of 32 defective location references;
two remain freeform or negative claims without a direct positive source anchor.
This proves static citation integrity, not live failure incidence. All 889
provisional P2/P3 findings now have source-level triage in three disjoint
parts under `../review/`. The two reconciliation overlays resolve 17
cross-review IDs without editing those raw partitions. The effective-decision
checker passes exactly: 696 source-supported mechanisms, 192 unknown and
one unsupported overclaim; 244 provisional fixes and 645 deferrals. These
are source-level proposals, not implementation-ready tickets; merged-main
reachability, behavioral gates and runtime incidence remain unverified.

On clean, pre-merge release candidate `0299daca`, the two frozen release P0
mechanisms have static repairs: [PR #2845](https://github.com/aiur-team/aiur/pull/2845)
removes raw GitHub token inheritance from OpenAI-compatible command sandboxes,
and [PR #2846](https://github.com/aiur-team/aiur/pull/2846) scopes stop-time
headless-agent pidfile cleanup to its instance. The [v3 recheck](p0-release-candidate-v3-recheck.md)
records their tests and limits. Four additional findings have changed cited
paths since v2, bringing the pre-merge path-affected set to 294; this is a
source recheck queue, not 294 open defects. Merged-main and runtime checks
remain pending. The recycled-PID identity risk is separate issue #2844.

All 359 rows of the proposed oversized-file owner map have an audit against
the clean pre-release integration candidate. Four paths disappear with the
user-requested GitHub cache dashboard removal; the other 355 still exceed
500 lines, and no new tracked v3 candidate path exceeds 500. The already
oversized launcher grows from 4,174 to 4,200 lines. Owner corrections,
action conditions and the final merged-main recount remain open. The
eight CE source identities are now proved against upstream `4aeaf685` plus
a five-file Aiur overlay, but their updater/regeneration gate remains open;
see [the source audit](u0-ce-source-provenance-2026-09-29.md). The
17,944-line candidate footprint is gross and conditional; no net saving has
been measured. The deletion guard and GitHub cache dashboard removals belong
to the preceding release, not to refactor savings.

The causal-gap audit identifies a few point causes but cannot allocate the
historical duration shares from retained evidence. The contextual privacy
review and lexical scan are complete for the published research tip; scan and
review any new public evidence before pushing it. The detailed plan is
`docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`.
