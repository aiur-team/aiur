# Report-wide contradictions and rewrite decisions

This is a cross-report planning audit of all 32 raw review units in
`../review/raw/` and the 986 canonical entries in
[`../review/findings.json`](../review/findings.json), read alongside the six
historical source reports and their 60-claim audit. It does not add findings or
change their reviewed severities. The raw units cover 1,033 source IDs; the
index preserves every ID after 30 merges. The two independent skeptic passes
cover the 182 inherited P0/P1 IDs. The 851 inherited P2/P3 IDs remain
provisional, so a title alone is not authority for implementation.

Method: enumerate all 32 JSON unit IDs and their findings, scan every title,
severity and recommendation, compare ownership proposals across units, then
read the cited source/reconciliation for the conflicts below. This is a
recommendation and claim-consistency pass, not a fresh runtime review of all
1,033 raw findings. The source snapshot is `3339b887`; merged code must be
rechecked before tickets are written.

## Recommendations that need one decision

| Evidence | Tension | Rewrite decision required |
| --- | --- | --- |
| `web-occ-06` and `web-rest-08` | Both propose a web-wide safe-call helper for swallowed exceptions, one named `SafeRead` and one `Safe`. Implementing both creates two fallback/telemetry policies for the same symptom. | Define one tagged result and reporting contract for expected unavailable reads; let unexpected failures remain visible. Replace call sites by domain, not by a blanket rescue wrapper. |
| `loose-2-02`, `orch-b-01`, `web-rest-02` | One proposal makes status read a published `SnapshotStore`, another repairs missing fields in the existing snapshot projection, and the dashboard cache proposal moves loader work into tasks. Three separate read models could disagree on freshness and default values. | Give each status field one owner and timestamp; make CLI and web project from the same complete source. Keep expensive loading outside the cache GenServer without adding a second authority for state. |
| `github-a-01`, `github-a-02`, `github-a-07` | CODEOWNERS parsing, team membership fetching and the allowed-user snapshot are each proposed for consolidation or asynchronous publication. A new parser alone does not decide what happens when team resolution fails; an ETS snapshot alone can preserve an unsafe or empty list. | One parser and one paginated resolver publish an explicitly healthy/degraded versioned snapshot. Specify whether stale membership remains trusted and for how long before changing dispatch authorization. |
| `loose-1-02`, `loose-1-03`, `platform-misc-09`, `loose-4-04` | Different stores latch read-only after append, projection or journal errors. Their proposals range from continuing with an in-memory state to retrying and quarantining. Treating all errors as best-effort would erase the distinction between a rebuildable projection and the durable authority. | State the source of truth and recovery rule per store: durable journal append failure, derived JSON write failure, corrupt tail and transient sync failure require different behavior. The decision must retain event identity and operator-visible health. |
| `build-order-11`, `telemetry-usage-04`, `loose-3-03` | Lost subscriptions are variously answered by crashing at boot, monitoring/re-subscribing, and exposing reload health. One universal retry loop would hide ordering failures; one universal crash policy would discard recoverable state. | Define dependency restart contracts by owner: initial subscribe failure, later `:DOWN`, and data-plane failure must have explicit retries, catch-up and health signals. |
| `loose-4-02`, `loose-4-03`, `platform-misc-05`, `platform-misc-07` | One finding asks for a corrected `:global.trans` file lock, another asks to remove a cluster-wide global lock from long hook runs, and HostLock has its own stale-lock race. A generic lock helper cannot safely replace all three. | Choose local file-writer ownership for per-host JSON, bounded workspace lock scope for hook logs, and an atomic inter-daemon workspace lease. State which lock protects which data and its timeout. |
| `agent-backends-cc-04`, `agent-runtime-01`, `agent-runtime-02`, `agent-backends-oc-11` | Shared JSON-RPC session plumbing, a common turn-settlement function, common queue bookkeeping and single-owner ETS are adjacent extraction suggestions. Collapsing them into one broad `AppServer.Session` would recreate a large module and blur turn-state authority. | Keep process/session lifecycle, turn settlement, queue persistence and ETS table ownership as separate cohesive contracts. Deduplicate code only after the ownership graph and failure semantics are explicit. |
| `github-b-02`, `github-b-04`, `github-a-04` | A guarded ResourceStore write, an ETS-backed quota split and paginated comment reads all touch GitHub read policy but own different freshness and budget decisions. A generic cache layer could accidentally make page-one data look complete or let stale writes win. | Put pagination completeness in the reader result, monotonicity in one store primitive, and quota admission in the credential budget owner. Preserve typed incomplete/unavailable results across those boundaries. |
| `nonelixir-shell-03`, `nonelixir-shell-08`, `loose-3-06` | Duplicate tmux config, divergent root discovery and duplicate workspace path construction each have an existing owner candidate. Adding an adapter to reconcile each copy would preserve the duplication. | Delete the unshipped/config duplicate, resolve root/config once at launch, and reuse `Workspace.workspace_path_under/2` for test reset. Test the shipped paths, not an alternate copy. |

These rows are *coordination conflicts*, not evidence that any of the cited
bugs is false. Most individual fixes are compatible once ownership is chosen.
Do not translate every proposal's example module name into a new module.

## Claims that must not be carried forward literally

| Original claim or reading | Corrected interpretation | Evidence |
| --- | --- | --- |
| Short continuation turns cost 186 hours and a later weekly rebound proves the prior fix regressed. | 12,768 short turns consumed about 20 measured turn-hours; the larger figure included intervals before the next run. Provider mix and a few threads explain much of the weekly shape. | [`verified-claims.md`](verified-claims.md) (`agents-01`–`agents-04`), [`../agents/agent-failure-modes.md`](../agents/agent-failure-modes.md). |
| The historical `b/c` gap bucket, roughly 78%, is a causal share owned by a human/Executor bottleneck. | The fractions reproduce as classifier outputs, but precedence, overlapping intervals, permissions waits and label lag prevent causal ownership inference. The current-era subset includes about 18.9 hours of active agents waiting for repository write permission. | [`verified-claims.md`](verified-claims.md) (`gaps-01`–`gaps-04`), [`gap-measurement-verification.md`](gap-measurement-verification.md). |
| An above-cursor wake was unseen or unacted on. | It is unacknowledged in that cursor; notification-only observation and later tool results can coexist with an old cursor. Action completion needs its own receipt. | [`verified-claims.md`](verified-claims.md) (`gaps-09`, `meta-02`), [`gap-measurement-verification.md`](gap-measurement-verification.md). |
| A large source-reference component proves package extraction cannot work. | The graph counts differ by scanner and revision, and source references are not runtime calls. The 100-field Orchestrator state and synchronous mutation paths are stronger evidence of ownership pressure. | [`architecture-verification.md`](architecture-verification.md) (`codebase-02`–`codebase-09`). |
| A source commit or `aiurdev` control command proves the running release contains the current code. | Checkout, assembled release, running process and installed CLI are distinct identities; control commands can intentionally reuse the old daemon. | [`deployment-verification.md`](deployment-verification.md) (`meta-08`). |
| Every raw P0/P1 title retains its inherited severity or whole causal chain. | The reconciliation moved 19 of 25 severity disagreements to P2; for example `agent-backends-oc-05` retains a diagnostics defect, but its quota consequence needs an unproven provider banner. `agent-runtime-03` overlaps the specific pause bug in `agent-runtime-01`. | [`../review/verdicts/severity-reconciliation-draft.json`](../review/verdicts/severity-reconciliation-draft.json), [`../review/code-review.md`](../review/code-review.md). |

The six source reports have been revised, but their historical numeric fields
and raw findings remain for provenance. Planning should quote the corrected
interpretation and denominator, not a striking original headline. No sampled
P0/P1 mechanism was disproved by the two skeptic passes; the 851 lower-priority
source claims still need verification before they become rewrite requirements.

## Rewrite requirements supported by this audit

1. Give each lifecycle transition, durable record, status field, GitHub read
   result, agent turn and workspace path a named owner. An extraction must
   delete competing paths, not add a coordinator above them.
2. Preserve typed states for unknown, stale, incomplete, permission-denied,
   outcome-unknown and permanently failed results. A zero, empty list or
   success response must not stand in for one of these states.
3. Make lost subscription, background append, ambiguous mutation and restart
   recovery observable and bounded. The acceptance test must inject the
   relevant failure and fail when the owner or recovery hunk is removed.
4. Keep launch, package and runtime identities explicit. Verify the real
   foreground CLI/TUI against the built release after source changes merge.
5. Use a single file-size gate over tracked text with a hard 500-line limit
   and a 200-line design preference; assign oversized files to cohesive
   responsibility splits. Measure physical LOC removed, and keep code merely
   moved to another module or package out of savings claims.
6. Challenge each keep/merge/cut/externalize choice against observed usage and
   user value. The requested local deletion-guard and GitHub cache dashboard
   removals are release work; after they merge, exclude them from future
   refactor savings and do not recreate their complexity.

## Open questions for brainstorm and plan

- Which process owns the authoritative ticket lifecycle transition when
  tracker labels, provider delivery, CI, review and operator decisions arrive
  out of order? What is the durable replay and idempotency contract?
- Which snapshot fields must be strongly current for dispatch and which may be
  stale with an age on CLI/web? Where is the single publication boundary?
- What is the trust policy for a degraded CODEOWNERS/team resolution result?
  Stale trust and empty trust have different security and availability costs.
- Which journal failures permit continued operation, and which must stop
  writes? Who acknowledges and retries an ambiguous external mutation?
- Which backend differences are truly shared session lifecycle, and which are
  provider-specific turn/permission semantics? What is the smallest module
  boundary that preserves both?
- Which proposed cuts have measured live use, and which are just hard to see
  because the census spans different revisions or operating modes?
- How will the implementation count real no-progress intervals, redundant
  turns, and LOC removed without attributing overlapping historical gaps or
  code moved between packages as a saving?
