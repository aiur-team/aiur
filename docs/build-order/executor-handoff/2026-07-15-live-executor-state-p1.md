## Live Executor state (updated 2026-07-15 20:57 PDT)

You are the **Executor**: you run Aiur to implement this feature, make every
PR merge-ready via review, do the merging, keep agents genuinely working, and
act as the fallback when an agent cannot finish its last mile. Everything
below this section is the binding contract; this section is the current live
truth and supersedes stale pre-run wording later in the document.

**Seven-wave reconciliation stop:** the Executor incorrectly marked the
consolidation gate complete after applying DEC-015's ownership overlay while
leaving the materialized ticket phases and preview on different schedules.
The operator stopped the run. Aiur and every direct worker were terminated;
execution could not restart until
[`12-current-execution-waves.md`](12-current-execution-waves.md) and
[`execution-waves.json`](execution-waves.json) form an exact 54-ticket W1–W7
partition, every GitHub member carries exactly the matching `phase:<wave>`
label, and the preview renders that same partition with no legacy-history
view. Native blocker edges remain the readiness authority. That gate passed in
two live ticket reads and one browser render, was committed and pushed as
`develop@4e9ea7fb`, and is recorded on root #1084. Aiur was then force-built
to avoid #1191's mixed-BEAM defect and restarted at the Tailscale dashboard
listener with a sixteen-worker ceiling. At 20:46 PDT the Executor fetched a
fresh `account/rateLimits/read` receipt directly from Codex: weekly usage is
10%, no rate limit is active, and reset is July 22 at 15:37 PDT. The stale 100%
receipt was replaced, and `aiurdev` was rebuilt/restarted from literal branch
`develop` at exact `origin/develop@cbfcdd5a` in the dedicated runtime worktree
`/home/orangekid/github/aiur-runtime-develop`, preserving the original instance
identity and Tailscale listener. The daemon is healthy with a sixteen-worker
ceiling; all currently active/legacy tickets remain `agent:paused` during the
three-PR review drain, so it deliberately owns zero workers.

BO-006/#1094 finished before the stop and was merged to `develop` as
`2f48ac78` via PR #1192 before the reconciliation commit could stale its exact
base. Build, lint, Dialyzer, browser, layout, and 259 focused AgentList tests
passed. Its repository-wide job failed only the already-classified
ProviderLifecycle timing and RepoEvents shared-supervisor teardown races, so
the documented develop flake rule applied; the issue is closed `agent:done`.

**State right now:** planning approval remains frozen at
`4d8de9508206e08e314f2730cd916501a3b4cafd` and publication receipt
`b8db1794c57ba01bd724cc44b8d4ee6de0b79cad`. The complete graph is live at root
#1084 with exactly 54 members, 105 internal native blocker edges, and two
external skill-blocker edges. The immutable files have been restored locally
and both static validators are at 0 errors / 0 warnings.

The direct-takeover drain is complete. DASH-004/#1160 merged to `develop` as
`8322a205`; BO-010/#1168 merged as `99bf768e` after its exact-head guard,
focused 40/40 ExUnit, 24/24 browser, packaged smoke, and protected two-line
allowlist passed. Its only full-suite failures were the already-classified
ProviderLifecycle and BuildGate base timing flakes. Executor convergence PR
#1183 merged to `main`; generic develop-push CI fix #1184 then merged as
`main@e058917b`, and that exact main tip is verified inside
`develop@c099f36b`. Planning PR #1064 then merged into `develop` as
`a58b309a`; its execution receipt, issue graph, prewarm gate, and configured
`develop` base all validated before dispatch.

Aiur initially ran headlessly after the seven-wave reconciliation gate while
its Codex providers were quota-paused. DASH-001/#1108 merged to
`develop` as
`f8b52beb`, BO-005/#1093 as `c7c4d7a8`, and DASH-008/#1114 as `e4955d80`; all
three issues were manually marked `agent:done` and closed because a PR into the
non-default `develop` branch does not apply its closing keyword. BO-003/#1092
then merged through direct Executor PR #1190 as `93d3a049` and was likewise
marked done and closed. Its exact final head passed browser, packaged-layout,
build, strict-lint, Dialyzer, and guard CI plus 72/72 integrated affected tests
and bounded exact-head review. The pre-dispatch drain is complete at
`develop@93d3a049`. The committed handoff/preview snapshot advances the live
branch to `develop@89609a92`. That historical release was later superseded by
the exact-current `develop@cbfcdd5a` restart recorded above.

The Executor therefore activated the bounded direct-takeover fallback rather
than idling. BO-016/#1103 completed its distinct Issue/Pull-request destination
repair and merged to `develop` as `47159958` through PR #1195 after an exact-head
review, 73 focused tests, and the documented develop-suite flake adjudication;
the issue is closed `agent:done`. No Claude worker is running. The external
Claude-authored docs PR #1194 was discovered by direct GitHub polling, moved off
the 53-commit-stale `v2` base, and repaired to state the real workspace security
boundary, distinguish npm CLI installation from repo-local skill availability,
describe the dashboard's read-only default, and expose `aiur-intro` canonically
to Codex. Independent exact-head re-review cleared every blocker, the focused
skill-surface test passed 19/19, and all deterministic CI gates passed. It merged
to `main` as `f189332d`; that exact main tip is verified inside
`develop@c742c851`. BO-007/#1095 then cleared independent exact-head review,
all deterministic gates, and 52 focused tests; its four full-suite failures
were unrelated shared-global-state races, so PR #1196 merged under the bounded
develop flake rule as `develop@4a799ef4` and the issue is closed `agent:done`.
DASH-007/#1113 cleared two bounded exact-head review findings: Open no longer
hides valid non-human authorities while counting them, and durable history now
preserves trusted provenance/supervisor-basis/supersession through the real
LiveView path. Its fresh suite ran 5,692 tests and retained only four classified
global-state/timing failures; all deterministic gates and 76 focused tests were
green, so PR #1197 merged under the develop flake rule as
`develop@cbfcdd5a` and the issue is closed `agent:done`. BO-019/#1106 was first
published as draft PR #1198 at `35973b75` with 77 focused/adjacent tests and all
static gates green. The DASH-007 merge made that head stale, so review was
stopped, current develop was integrated without conflict, and exact head
`08dadc56` passed post-integration format, warnings-as-errors compile, and 45
directly affected tests. Fresh exact-head review then found three bounded P1s:
the production IssueLog API collapses missing/unreadable into healthy empty,
durable history paths/topics are not exact owner/repository-qualified, and
eviction can publish a later generation before a snapshot then reuse it on
rehydration. Those three were repaired and pushed at exact head `b6d22049`,
with 67 focused/adjacent tests and all static gates green. Fresh independent
re-review found two remaining P1s: the qualified filename lacks safe legacy-log
migration/fallback, and the bounded API still reads/parses an unbounded entire
log at boot/request time. One new CI test also assumes configured repository
state that is absent in CI. BO-019 remains in bounded repair and BO-018 remains
blocked.
DASH-011/#1117 is the only other currently-ready ticket without an active
serialization peer, so a third direct Codex implementation worker owns its
exact-pricing seam. It is draft PR #1199 at exact head `7af5958e` with current
`develop` contained; 41 focused tests including three properties plus compile,
format, lint/specs, and Dialyzer are green. Independent exact-head review found
two bounded P1s: observations cannot distinguish provider-defined long-context
Codex rates or Claude cache-write duration while still claiming full coverage,
and the advertised partial-coverage result is unreachable because the query
discards already-priced components on the first missing rate. The same reviewer
now owns that bounded repair and its edge/sparse tests.
DASH-029/#1133 was briefly dispatched from the native graph, but its read-first
amendment exposed the non-native binding order that the live issue body obscures:
DEC-015 requires it to serialize after DASH-026, and unresolved GATE-004 must
preserve Claude exact decimals before JavaScript float conversion. It was
stopped at 15% before source edits, its workpad preserves the protocol research,
and it is paused until both constraints clear. DASH-009/DASH-012/DASH-026 remain
held behind BO-019's shared supervision seam. DASH-021 is now ready because
DASH-007 merged, so DASH-021 took the freed implementation slot and published
draft PR #1200 at exact head `6736d501` with `develop@cbfcdd5a` contained.
Its 142-test affected matrix, compile, format, strict lint/specs, and Dialyzer
are green. Independent security review found three bounded P1s: denied or stale
contexts do not immediately evict protected cache state, subscriptions use only
configuration identity instead of connection-plus-configuration identity, and
deterministic generations let an A→B→A credential rollback revive old proofs.
The same reviewer now owns those rotation, isolation, and non-replayability
repairs. The full-suite failures are baseline-correlated; the untouched
route-shell browser assertion needs a clean rerun, and Executor-root
authenticated/optional manual evidence remains outstanding after the code gate.
Active issues retain `agent:paused` alongside their execution state so the
restarted daemon cannot create duplicate writers. Aiur itself is running
through `scripts/aiurdev` from the literal `develop` branch in the dedicated
runtime worktree, not from the detached documentation checkout.

### Successor checkpoint — preserve this operating shape

This is the minimum self-contained state a successor must recover before doing
anything else:

- **Authority and bounded goal.** The Executor has merge authority and owns the
  last mile: diagnose stalled work, use bounded Codex background workers for
  implementation/review, take direct ownership whenever delegation stops making
  material progress, refresh stale branches, adjudicate CI, merge, update this
  handoff/preview, and keep useful parallelism full. Do not wait for catastrophic
  Aiur failure before taking over. Review only material correctness, durability,
  security, and acceptance-contract risks; the feature stages on `develop`, so
  polish/nit-picking waits for the final integrated feature review. Do not leave
  comments on PRs the Executor already owns merely to communicate with itself.
- **Branch policy.** Build Order feature PRs merge into `develop`. Generic
  stability fixes merge into `main`, after which the exact new `main` tip must be
  merged or fast-forwarded into `develop` before any new feature work starts.
  Every implementation and every exact-head review must contain the exact
  current integration tip; stop a review immediately if another merge makes its
  head stale. Prefer restarting a badly diverged branch over spending hours
  reconciling obsolete code. PR #1194 is not pending: it merged into `main` at
  `f189332d1503fe9d0a3b28f6c99ad4773c9a8462`, and that exact tip is already in
  `develop` through `c742c851`.
- **Current runtime.** Run the product with `scripts/aiurdev`, not a direct Mix
  command. The live instance is built from the literal `develop` branch at
  `cbfcdd5ac426acac59b8050822c7ed254e99807a` in
  `/home/orangekid/github/aiur-runtime-develop`; instance key is `5c1b32aea9`,
  the dashboard was `http://<dashboard-host>:4000` at that checkpoint, and the configured ceiling is
  sixteen workers. The launch shape is `scripts/aiurdev --bg --host
  <dashboard-host> --max-agents 16 /home/orangekid/github/aiur/.aiur/config` after
  loading the root `.env`. Reuse the same instance key for control commands.
  The current HTTP `401` is healthy basic-auth behavior, not a failed listener.
- **Workspace safety.** The original checkout is intentionally detached at
  `4e9ea7fb1cf6` so the literal `develop` branch can belong to the clean runtime
  worktree. It contains uncommitted handoff/preview edits and machine-only
  `.aiur/config` / `.aiur/model-usage.json` state. Do not reset it, blindly commit
  the machine config, expose `.env`, or delete the generated caches while another
  process may use them. Update/rebuild/restart the clean runtime worktree after
  each integration merge; do not run the stale release from the documentation
  checkout.
- **Models and quota.** This run is Codex-only: use current Sol/Terra labels and
  do not spend Claude tokens. A direct `codex app-server`
  `account/rateLimits/read` receipt at 20:46 PDT reported weekly usage at 10%, no
  active limit, and reset at 2026-07-22 15:37 PDT. The old persisted 100% receipt
  was stale and was replaced in machine state. Re-read the authoritative account
  endpoint before treating a persisted receipt as a reason to stop or switch.
- **Why Aiur owns zero workers right now.** Aiur is healthy and intentionally
  running with the three active issues carrying `agent:paused`; three direct
  Codex workers own their bounded repairs, so unpausing would create duplicate
  writers. BO-019/#1106 PR #1198 is repairing legacy-log compatibility, a truly
  bounded tail reader, and a CI-independent test. DASH-011/#1117 PR #1199 is
  repairing provider rate dimensions and reachable partial pricing coverage.
  DASH-021/#1125 PR #1200 is repairing immediate protected-cache eviction,
  connection-scoped subscriptions, and non-replayable A→B→A authorization
  generations. All three PR heads currently contain `develop@cbfcdd5a`; verify
  that again rather than trusting this sentence.
- **Drain order and exact-head rule.** BO-019 is the immediate critical-path
  blocker for BO-018. Merge the first genuinely approved PR, then immediately
  refresh every remaining open head onto the new exact `develop`, rerun its
  affected/static gates, and obtain a fresh exact-head review; never carry an
  approval across an integration change. A repository-wide red suite may use the
  documented `develop` flake rule only after the exact failures are shown to be
  baseline-correlated and all owned deterministic/focused gates are green.
  Security/auth work additionally needs the explicit Executor-root evidence
  below; review prose alone is not proof.
- **Readiness is native plus binding amendments.** The verified W1–W7 labels and
  native `blockedBy` edges are the scheduling authority, but
  [`11-execution-amendment.md`](11-execution-amendment.md) carries binding
  non-native serialization/gate constraints. In particular, do not resume
  DASH-029/#1133 until DASH-026 is complete and GATE-004 preserves Claude's exact
  decimal before JavaScript float conversion. DASH-009, DASH-012, and DASH-026
  also share BO-019's current supervision seam. Do not create speculative scope
  to fill capacity; only dispatch dependency-ready, ownership-safe work.
- **After this three-PR drain.** Advance the clean runtime worktree to exact
  `origin/develop`, force-rebuild if any release coherence is uncertain, restart
  the same `aiurdev` instance, remove `agent:paused` only from the next safe
  critical/earlier-wave set, and use Sol/Terra workers. Maximize *useful*
  concurrency against CPU/memory/ownership constraints rather than an arbitrary
  five-agent cap. Prioritize the critical path, then earlier waves, and only pull
  a later-wave ticket when every earlier safe ticket is genuinely blocked.
- **Known runtime trap.** The normal mtime-based dev rebuild once produced a
  mixed-BEAM release and a missing `graph_catalog_refresh_ms` field. A forced
  `scripts/aiurdev build` fixed it; #1191 records the durable P1. If startup looks
  incoherent, force-build once before diagnosing unrelated application code.
  Issue #1182 is intentionally scheduled in the final execution wave for first
  Executor-takeover alerts at eight hours and hourly reminders thereafter; it
  must not delay this drain.
- **External PR polling.** The external planning/Claude agent does not send an
  Aiur event when it opens a PR. Poll `gh pr list` directly and review/merge any
  promised scoped PR when it appears. Do not mistake already-merged #1194 for
  that future PR, and do not reintroduce Analytics (explicitly excluded from the
  Build Order scope).
- **Operator surfaces.** The live progress artifact is
  `http://<dashboard-host>:4180/docs/build-order/plan-preview.html`; its served copy
  is `/tmp/aiur-pr1064-pack/docs/build-order/plan-preview.html`. Keep ticket/PR
  links, live/merged styling, percentages, and the seven-wave view current at
  meaningful transitions. The dashboard remains available while work runs. The
  ten-minute capacity check and adaptive monitoring cadence are operational
  duties, not a reason to poll pointlessly; record meaningful directives and
  failure discoveries here as they occur.
- **Terminal proof.** Do not call the feature shipped merely because PRs merge.
  After the bounded graph is complete on `develop`, run comprehensive integrated
  review, full CI, and the repository's canonical real CLI manual flow from the
  Executor root: `scripts/aiurdev --test --force --allow-remote`, drive the real
  TUI via wrapper tmux, open a running agent chat, send an Executor message via
  the TUI input, and inspect what the user sees. Also exercise the authenticated
  and optional-unauthenticated dashboard paths, credential rotation/removal,
  cached/queued/in-flight updates, A→B→A rollback, responsive/accessibility
  behavior, and the final Build Order graph. Stop only for operator sign-off on
  promotion from `develop` to `main`.

The normal post-integration `aiurdev --bg` restart also exposed a separate P1
dev-release coherence defect: its mtime-based incremental rebuild assembled a
new `Aiur.Config` consumer with an old `Aiur.Config.Schema.BuildOrder` BEAM,
then crashed on the missing `graph_catalog_refresh_ms` field. A supported
`scripts/aiurdev build` force compile repaired the release and the same launch
succeeded. Duplicate search found no matching issue, so generic Ad Hoc #1191
records the deterministic regression/fix for `main`; it is paused because the
workaround is active and it must not consume current feature capacity.

Exact-head reviews are convergence gates, not open-ended review cycles. PR
#1187 fixed the two reproduced activity-ordering defects and deterministic
lint/Dialyzer failures, then merged under the documented suite-flake rule after
its browser/build/lint/Dialyzer/layout gates passed. PR #1189 fixed exact-money
scale rejection, opaque invalid-UTF-8 serialization, and deterministic lint
debt. After one clean merge of #1187's new `develop` tip, its browser/build/
lint/Dialyzer/layout gates all passed and it merged without waiting for a
second redundant full-suite run; its preceding exact code head had only the
known ProviderLifecycle suite race. Do not reopen either accepted ticket or
add a fresh stylistic review cycle.

BO-003's first repository-wide run completed at 85.08% coverage with 5,590
tests; its only failures were the unrelated DecisionMetrics fixture and
ProgressCheckin timeout already seen on the integration branch. Deterministic
new cases now cover invalid configuration and delayed completions, same-repo
generation fencing without notification, cold rate-limit retry across
release/re-demand, missing Task.Supervisor recovery, bounded pending admission,
reset-first PubSub subscriptions, subscriber churn, and health-only partial
candidate failure. The Executor also reconciles configuration before accepting
task result/DOWN/timeout or due-timer work, retains inactive retry metadata,
and re-arms it on renewed demand. Finish the current bounded exact-delta review,
then integrated current `develop` exactly once after #1187/#1189 landed. The
automatic merge preserved the combined child order
`Task.Supervisor -> WorkflowStore -> RepoBase -> TicketDetailCache ->
GraphProjection -> Events -> CurrentRunMembership.Store -> TicketActivity ->
Orchestrator -> CurrentRunMembership.Reconciler`; an independent read-only
preflight and the 72-test integrated gate found no remaining interaction risk.

The first dispatch exposed a machine-local writable-root mismatch during the
build-gate preflight. The Executor corrected only the active local config,
preserved the workers' workspaces, reset the four infrastructure-only dispatch
counts, and successfully resumed all four tickets. Do not record the local
path in committed documentation.

At 13:41 PDT BO-005/#1093 completed a normal turn, but its immediate recursive
turn inherited a late `progress.checkin` dynamic-tool response and failed with
`turn_start_failed`. Aiur preserved the dirty workspace, resumed the same Codex
thread after its ten-second bounded retry, and the worker advanced from 60% to
70%; this is recovery rather than current gridlock. The failure resembles the
closed queued-after-completion class in #552. Watch for a second occurrence on
this run; if it repeats or loses work, treat the existing fix as regressed and
prioritize a contained stability repair. A single self-healed occurrence does
not justify interrupting BO-005 or expanding Build Order scope.

Restart diagnostics also found P1 issue #1185: a valid persisted workspace-
ownership receipt could fail `binary_to_term(..., [:safe])` in a fresh VM
because its finite v1 atoms had not yet been loaded. PR #1186 targets `main`,
preloads only that closed vocabulary, and passed exact-head review plus every
CI gate except the same unrelated ProviderLifecycle and BuildGate concurrency
flakes on both the original run and unchanged rerun. The Executor applied the
documented flaky-suite/admin rule and squash-merged #1186 to `main` as
`8c3ef518`; current `main` was then merged into `develop` as `6ada3318`. Rebuild
before the next safe daemon restart. Do not restart merely to consume the fix
while takeover workers have uncommitted work.

At 13:46 PDT the configured Codex account reached 100% of its weekly window;
Aiur correctly recorded the reset time, paused all four workers without
spending retry budget, and preserved every dirty workspace. The operator's
no-Claude directive remains binding. Aiur and its dashboard stay alive but its
four provider workers remain paused. Three Codex background takeovers produced
PRs #1187, #1188, and #1189; the Executor directly took BO-003 in the root
slot. Each branch refreshes from current `develop` exactly once at final
handoff, runs scoped validation, and opens its feature PR into `develop`. Do
not resume the Aiur providers until the Codex account is available and no
duplicate takeover writer owns a workspace.

DEC-015 in `11-execution-amendment.md` is now the binding execution overlay.
It preserves the 54-member/105-edge baseline, applies current-`develop`
freshness to every remaining contract, replaces the research draft's lane
issues/labels/long-lived branches with five existing anchor owners, and records
the complete early-ticket audit. BO-016/#1103 must be reopened to add the
separate Pull-request destination; its existing edge blocks BO-018 naturally.
Before that reopen there were 13 completed members; after it, 12 are complete
and 42 remain. All zero-code lifecycle residue is cleared.

The execution receipt is sealed at `c83f143888e6986feb4078df534b19ede4f2f90f`.
The root and all 42 affected tickets each carry exactly one commit-pinned
amendment comment. Two complete live reads agree and validate at 0 errors / 0
warnings across 54 members, 105 internal edges, two external skill edges,
issue bodies, mappings, routing labels, lifecycle partitions, and all 43
comments. The final pre-run work is to land planning PR #1064 on current
`develop`, verify its CI, and rebuild prewarm from that exact integration tip.
Shared GATE-001/GATE-002 evidence is recorded on root #1084 in
https://github.com/aiur-team/aiur/issues/1084#issuecomment-4984606240;
GATE-003 and GATE-004 remain ticket-specific blockers.

All restart prerequisites through the live execution receipt, `develop` push
CI, lifecycle reconciliation, BO-016 reopen, PR #1064 integration, and exact-
tip prewarm are complete. The first safe fan-out is live with one writer per
supervision/ingress seam. All workers remain Codex Sol/Terra; never dispatch
Claude.

### Binding integration and promotion policy

This section supersedes every historical `main`-as-feature-base or repeated
dual-review instruction later in this handoff.

- Lowercase `develop` is the Build Order staging branch. It was created from
  exact `main` and both pointed at `f8f3075d` when this policy was established.
  Every core BO/DASH implementation PR and planning PR #1064 targets `develop`.
- Generic stability, daemon, workspace, CI-lifecycle, and other reusable fixes
  target `main`. After every such merge, merge current `main` into `develop`
  before reviewing, dispatching, or merging more Build Order work. The hard
  freshness invariant is `origin/main` is an ancestor of `origin/develop`.
- `.aiur/config` sets `tracker.base_branch: develop`. Restarted Aiur workers,
  prewarm state, workspace hooks, PR creation, freshness checks, and CI must all
  use that configured integration branch. A PR aimed at another branch is not
  merge-ready.
- Optimize intermediate feature throughput: a Build Order PR into `develop`
  needs current-`develop` ancestry, its scoped acceptance evidence, and green
  CI. Fix clear material correctness/security/contract failures, but do not run
  serial nit-picking or repeated dual-review cycles on otherwise accepted
  intermediate work.
- `develop` is not promoted piecemeal. When the entire bounded feature is
  integrated, run one comprehensive cross-feature review, full repository CI,
  and the required real CLI/dashboard/TUI acceptance on the exact `develop`
  head. Resolve material findings there, then stop for operator sign-off before
  opening or merging a `develop` → `main` promotion PR.
- Existing paused/stale feature branches may be preserved, refreshed, or
  restarted from current `develop` at Executor discretion. Prefer a clean
  restart when semantic drift or conflict repair costs more than reimplementing
  the ticket from its contract.

### Completed pre-restart execution sequence

This sequence is complete and explains the gate that authorized the current
run. Do not repeat it merely because a worker slot is available:

1. The Executor directly owns every already-started stability PR with bounded
   background workers. Merge reusable fixes into `main`, then synchronize exact
   current `main` into `develop` after each merge.
2. The Executor directly owns every already-started BO/DASH PR. Refresh,
   preserve, or cleanly recut each branch against `develop` according to the
   cheapest safe path, and merge all of them into `develop` before dispatching
   another ticket.
3. Apply the binding correction in `11-execution-amendment.md`; preserve
   `10-late-wave-consolidation.md` as research provenance only. Keep the
   canonical 54-member/105-edge graph, use existing lane anchors, and do not
   create lane issues, lane labels, or stale long-lived branches.
4. Audit every remaining ticket document, live issue body, dependency,
   implementation plan, ownership seam, and acceptance tail against the run's
   observed failures. In particular, remove avoidable sequential/shared-file
   churn; state current-`develop` ancestry and refresh/restart expectations;
   assign shared files and supervision seams; front-load deterministic focused
   tests; require one coherent self-review before PR handoff; and prevent CI,
   review, comment-wake, finalization, and lifecycle gridlock. Preserve the
   approved feature boundary—this audit improves contracts rather than adding
   speculative tickets.
5. Validate the revised pack and reconcile the exact live graph. Only then
   restart `aiurdev` against `develop` with Codex Sol/Terra and dispatch the
   consolidated remaining work.

Intermediate Build Order PRs retain the speed-focused gate above. The audit is
not permission to reinstate repeated dual-review cycles; material integration
risk is accumulated for the one comprehensive `develop` promotion review.

The recorded runtime session ceiling is 15 workers, governed by
Aiur's effective-slot controller and shared build gates. The operator target is
10–15+ useful agents whenever dependency width and measured
CPU/memory/provider/review capacity permit. The temporary ceiling of 10 was
restored to 15 after the 13:43 and 13:53 ten-minute audits both measured load
below 18. A 14:03 build spike reached load 41 without memory pressure; by the
14:13 hard audit load was 10.89 with about 21.6 GiB available, so the Executor
kept the safety ceiling at 15 and recovered the completed-turn rework rows
#1097/#1148/#1162. At 14:19 all three were genuinely turning alongside
#1109/#1151, #1091 remained in fresh CI, and three independent Executor review
lanes were staffed. #1161 was then explicitly deactivated before requeueing its
single current-head Dialyzer repair. This is measured scheduling, not an
arbitrary worker cap. #1146 is
preserved but paused because its wrong-base behavior is
contained by current config, while #1151's CI-wake defect is actively
recurring. Build-gate P1 #1154 remains in the current Ad Hoc wave because
namespace-local lease IDs directly blocked core verification. Token measurement
#1171 completed without another model turn: the Executor ran all three ccusage
views, recorded the non-empty Claude/Codex baseline in comment `4974061960`,
and closed the measurement-only ticket. The no-change window began at 14:14
PDT; #1169 remains undispatched until a fresh delta is captured no earlier than
18:14 PDT, and #1170 remains gated behind the separate post-Serena measurement
window.
#1090,
#1093, #1108, #1111, #1123, and #1130 remain
protected behind #1161's workspace-replacement fix. Unrelated #855 stays
paused and consumes no provider capacity. All providers are Codex Sol or
Terra; never dispatch Claude.
