# Build Order Executor Handoff

## Live Executor state (updated 2026-07-15 09:57 PDT)

You are the **Executor**: you run Aiur to implement this feature, make every
PR merge-ready via review, do the merging, keep agents genuinely working, and
act as the fallback when an agent cannot finish its last mile. Everything
below this section is the binding contract; this section is the current live
truth and supersedes stale pre-run wording later in the document.

**State right now:** planning approval remains frozen at
`4d8de9508206e08e314f2730cd916501a3b4cafd`; the complete graph is live at root
#1084 with 54 members #1085–#1138 and 107 exact blocker relations. The historical
receipt gate remains operator-overridden for this run. Aiur is deliberately
stopped while the Executor and bounded background workers close the five
already-started feature PRs; do not restart feature dispatch until those
ownership branches land and the remaining graph is consolidated and audited.
Current accepted `main` remains `47f87815`; exact `origin/develop` is now
`80645369`. The completed direct-takeover stability set
now includes configured-base recovery #1146, provider-turn completion #1162,
terminal GitHub CI verdict handling #1151, and sandbox-safe build-gate leases
#1154, plus workspace containment #1161. #1161 cleared the deterministic
coverage floor at 85.02%, passed fresh centralized CI, and was the last active
stability merge. #1141/DASH-018 is merged into `develop` at `80645369`; its
single failed full-suite lane was classified as unrelated current-base timing
flakes after the exact ProviderLifecycle test passed 28/28, the exact
BuildGate test passed 10/10, and the full BuildGate file passed 60/60 at the CI
seed. #1144/DASH-006 and #1168/BO-010 have each integrated that exact head and
are in fresh exact-head CI at `ecc59aa7` and `e3373f36`, respectively. Their
bounded reviews and focused gates are green; #1168 also has fresh exact-head
Executor approval for its intentional two-line compile-time-path allowlist.
#1160/DASH-004 and #1163/BO-016 are now active in parallel as direct bounded
takeovers against current `develop`; preserve the useful DASH-004 WIP while
excluding generated cache and restoring protected regression files from the
base, and keep BO-016 within its existing seven-finding packet. Aiur remains
stopped. The core program is 9/54 merged with 45 remaining.

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

### Binding execution sequence before Aiur restarts

Do not restart Aiur merely because a worker slot is available. The operator's
current sequence is strict:

1. The Executor directly owns every already-started stability PR with bounded
   background workers. Merge reusable fixes into `main`, then synchronize exact
   current `main` into `develop` after each merge.
2. The Executor directly owns every already-started BO/DASH PR. Refresh,
   preserve, or cleanly recut each branch against `develop` according to the
   cheapest safe path, and merge all of them into `develop` before dispatching
   another ticket.
3. Apply Claude's researched Waves 5–10 consolidation in
   `10-late-wave-consolidation.md`, reconciling it against what actually merged.
   Update the canonical pack, live GitHub issue graph, dependencies, labels,
   and preview; do not treat the research draft as self-executing authority.
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

**Current operating decisions:**

1. Use explicit `progress.checkin` events as the percentage authority. Workpad
   checkboxes are useful planning evidence but are not the live progress meter.
2. Replace unconditional five-minute model wakes with an adaptive shell wait:
   wake immediately for attention, agent-state, PR/CI, daemon, stale-log, or
   unchanged-progress/thrash signals; otherwise force a health audit after a
   quiet ceiling. Start at 10 minutes, bound it to 2–20 minutes, shorten after
   an intervention, lengthen after repeated no-action audits, and retain a
   wake/outcome history so later phases tune thresholds from evidence. A user
   check-in always interrupts the wait.
3. Keep `docs/build-order/plan-preview.html` current at meaningful execution
   snapshots and every phase boundary. Show actual event-reported percentages
   while work is active and verified/merged truth when a phase closes; avoid
   committing a new snapshot for every uneventful local poll.
4. Diagnose reproducible Aiur defects and file them, then apply two gates before
   activation: the work must be authorized/in-boundary (or a direct P0/P1
   blocker), and measured CPU, memory, build, serialization, and agent-slot
   headroom must exist. Otherwise schedule it for a later phase without
   `agent:todo`. Issue #1140 records the tracked per-workspace Hex cache defect;
   it is deferred because Phase 1 currently has no compute or slot headroom.
   Issue #1142 owns permanent adaptive-monitoring and resource-triage skill
   delivery after this multi-phase run supplies tuning evidence; its prototype
   is active operationally but it also has no dispatch label.
5. Maintain this handoff whenever an operator directive, execution override,
   capacity decision, discovered blocker, or validation authority changes.
6. Before feature dispatch resumes, rebuild the prewarm base from live
   `origin/develop`. Although
   `prewarm.poll_seconds` is zero, each tracker dispatch cycle calls
   `RepoBase.refresh_async/0`; after every merge verify the base fetches,
   rebuilds, and reaches the new `develop` before newly-ready dispatch begins.
7. At 19:13 PDT the adaptive watcher caught #1088's operator-decision alert:
   PR #1144 had opened against legacy `v2`, producing 429 unrelated files.
   The Executor auto-retargeted it through the REST API to authorized `main`,
   reducing the diff to 12 files, recorded the decision on #1088, and messaged
   the worker to rerun scoped validation and resolve the attention. This is the
   canonical response when a branch is based on current `main` but GitHub PR
   creation inherits the repository's legacy default base.
8. The same defect reproduced on PRs #1143/#1086 and #1145/#1087. Both were
   REST-retargeted to `main` and reduced to scoped 13-file and 23-file diffs;
   the workers retain their real lint/browser-test rework. P1 issue #1146 owns
   a durable fix that carries `tracker.base_branch` through agent PR creation.
   It has no dispatch label while CPU, build slots, and all five agent slots
   are saturated; the Executor auto-retargets any recurrence and may activate
   #1146 only in genuine spare capacity without displacing ready critical-path
   work.
9. At 19:23 PDT the Executor found the concrete override: both live configs
   already said `tracker.base_branch: main`, but the dogfood `.aiur/hooks`
   fetched/checked out/merged hard-coded `v2` and `.aiur/prompt.md` explicitly
   instructed agents to open PRs against `v2`. Both live copies were corrected;
   hooks now consume injected `THIS_BASE_BRANCH` with a `main` fallback. The
   isolated fix was shell-validated and pushed directly to `main` as
   `e27e96db7d5326d5744ec5bcca40ce32b0d8812f`. The running prewarm checkout
   then fetched/reset to that SHA and rewrote `.aiur-base-built` after the
   commit timestamp, proving refresh plus rebuild on a live `main` advance.
   Keep #1146 open until the next agent-created PR targets `main` without
   intervention; do not claim automatic wrong-base repair from configuration
   inspection alone.
10. At 19:34 PDT a controlled restart proved that startup removes durable
    `agent:paused` labels from active-state tickets via
    `PauseResume.recover_startup_pause_override/2`. Deferred #1032 and #678
    immediately consumed two Sol turns, displacing BO rework; #99, #728, and
    #1030 were exposed to the same defect. P1 #1148 records the contradiction
    with the documented pause contract. Run containment removed active-state
    labels from all five deferred tickets while retaining `agent:paused`, then
    restarted cleanly; do not restore their active-state labels during this
    bounded feature run. The local dashboard is healthy on `127.0.0.1:4000`;
    direct non-loopback binding correctly refused to start without basic-auth
    credentials, and adding a Tailscale Serve listener requires host sudo. The
    separate progress prototype remains reachable on the existing Tailscale
    listener at port 4180.
11. PR #1145/#1087 reached a clean all-green head, then two independent
    Executor reviews converged on five contained BO-008 gaps: no authenticated
    navigation proof, a transform-only performance primitive, unsanitized
    binary browser artifacts, no CI invocation of the failure-evidence
    verifier, and recursive cleanup of a caller-owned artifact directory. The
    deduplicated review is recorded at
    `https://github.com/its-everdred/aiur/pull/1145#issuecomment-4964932068`;
    #1087 returned to `agent:rework` rather than merging a green-but-incomplete
    harness. Keep all fixes on #1087; do not file five follow-up tickets.
12. At 20:05 PDT Claude refreshed the committed OCC design and plan preview
    with complexity-weighted phase-progress bars. Operator direction assigns
    this only to later-phase #1107/BO-020; it does not alter Phase 1 dispatch.
    BO-020 now points at the prototype `.bo-prog` / `renderBoSummary` reference,
    consumes BO-007 authoritative progress, preserves unknown/stale states, and
    renders `sum(complexity * progress) / sum(complexity)` with color-independent
    accessible text. Analytics is intentionally excluded and cannot become a
    ticket or acceptance dependency. The prototype's CDN-loaded d3 remains
    non-authoritative; production layout stays within BO-009/BO-010's vendored
    platform contract.
13. PR #1147/#1089 reached a clean all-green head, but dual independent review
    found four contained trust/acceptance defects: bare legacy records could
    inject unhashed provenance, new provenance-bearing schema-1 events were not
    compatible with the previous decoder's rollback hash semantics,
    credential-shaped strings could enter allowlisted identity fields, and the
    required store-backed lifecycle/history matrix was incomplete. The
    deduplicated review is at
    `https://github.com/its-everdred/aiur/pull/1147#issuecomment-4965018879`;
    #1089 returned to `agent:rework` and resumed. Keep every fix on #1089.
    At the same snapshot #1086/#1143 and #1090/#1141 are green and in dual
    Executor review, #1088/#1144 is rerunning its failed test, and #1087/#1145
    remains in its existing review-driven rework.
14. At 20:16 PDT the operator added a hard hourly retrospective to the adaptive
    Executor monitor. Immediate event/attention wakes and the adaptive quiet
    ceiling remain in force, but neither resets this independent one-hour due
    time. Every audit records an `action` or `no-action` reason; once per hour
    the Executor reviews the preceding hour's wake/outcome history, identifies
    redundant/no-action checks that a more specific Aiur/event-bus notification
    could replace, and records one small cadence/trigger adjustment or an
    explicit unchanged decision. Do not overfit isolated misses. At BO-015,
    synthesize repeated evidence into at most one or two deferred Aiur
    notification/polling issues under the normal scope circuit breaker; these
    optimizations cannot delay Build Order acceptance. The run-isolated helper
    and durable `/aiur-run` contract are in PR #1150; this run uses stable ID
    `aiur-dashboard-program-20260713` and its first isolated retrospective is
    due at 21:30 PDT.
15. Dual review returned #1086/#1143 to rework for three contained repository-
    identity gaps: ambiguous bare-number API results leaked one arbitrary
    nested identity, noncanonical/contradictory structs could be marked
    joinable, and rate-limit fallback redispatch dropped identity metadata.
    The packet is at
    `https://github.com/its-everdred/aiur/pull/1143#issuecomment-4965070307`;
    #1086 resumed and owns every fix.
16. Dual review returned #1090/#1141 to rework for the provider-account
    generation lifecycle as a whole: authenticated startup did not seed a
    binding, RPC waits dropped lifecycle notifications, subscription and hard-
    teardown boundaries could preserve/cross stale generations, and five
    related continuity/degradation cases violated the ticket contract. The
    single consolidated packet is at
    `https://github.com/its-everdred/aiur/pull/1141#issuecomment-4965072012`;
    #1090 resumed. Do not split these findings into new tickets.
17. Dual review returned #1088/#1144 to rework despite green CI: the default
    query path named the wrong store module, response paging still performed
    unbounded store/metrics reads, partial detail health was hidden, canonical
    counts did not reach the UI, and required property/replay/security coverage
    was absent. The consolidated packet is at
    `https://github.com/its-everdred/aiur/pull/1144#issuecomment-4965131360`;
    keep all fixes on #1088.
18. At 20:34 PDT the Executor diagnosed a production CI-wake loss on
    #1087/#1145. The agent posted its review-resolution PR comment under the
    same `its-everdred` GitHub login used by the operator, and CODEOWNERS
    correctly marked that login trusted. Because `github.bot_account` is unset
    (setting it to the shared login would also suppress real operator comments),
    Aiur treated the agent's own reply as new human feedback and moved the
    ticket `ci-wait -> rework` at 03:13:02Z, nine seconds before lint failed at
    03:13:12Z. `CiLifecycle` polls only `ci-wait` and `human-review`, so no
    `ticket.1087.ci.failed` event was emitted. P1 bug #1151 owns the bounded
    origin/provenance regression and was dispatched into the genuinely free
    fifth Terra slot; it is outside the 54-ticket Build Order denominator. The
    immediate recovery also exposed a wedged completed-turn runner: an Executor
    message and progress event remained queued while control reported "already
    running." A cooperative `pause 1087` followed by `resume 1087` invoked the
    fallback descendant reap, restarted the same workspace/session, and
    delivered the queued lint repair. Use this contained recovery before
    considering manual code edits, and retain #1151's regression ordering:
    agent reply -> CI wait -> self-comment ingestion -> later CI failure.
19. At 20:54 PDT the Executor restarted Aiur from the repository root so the
    engine loaded the operator's root `.env`. Agent GitHub operations now use
    `its-applekid`, while Executor shell operations remain `its-everdred`;
    `tracker.github.bot_account: its-applekid` suppresses only actual bot
    self-comments. The config and prewarm base were pushed/refreshed to
    `97518e96`. Deferred enhancement #1152 owns an `aiur init` question that
    explains and writes this setting; it has no dispatch label because it does
    not block the finite Build Order.
20. At 21:01 PDT #1086/BO-004 was squash-merged after focused post-rework
    review. The Build Order preview was refreshed at `10464902` with real
    100/90/60/50/60 Phase-1 check-ins, merged-card rendering, and cleared-edge
    rendering; its Tailscale listener remains on port 4180. #1087/BO-008 is
    code-approved and all-green, but its head predates current `main`, so the
    Executor returned it to its existing agent for a merge-based current-main
    update and fresh CI rather than bypass the stale-base gate.
21. At 21:30 PDT #1087/BO-008 was squash-merged after its current-main head
    passed fresh full CI and independent re-review. The resulting cold fan-out
    admitted the five newly ready tickets #1085, #1103, #1104, #1111, and
    #1123. It also reproduced the known workspace-bootstrap failure: #1103
    and #1123 retained Codex processes whose `/proc/<pid>/cwd` points at a
    deleted inode, while the host canonical path points elsewhere. #1085,
    #1104, and #1111 were recovered only after their canonical checkouts became
    valid and they received an Executor re-probe message. This is not a new
    ticket: #1030/PR #1039 owns active-turn/replacement safety, and #1054/PR
    #1060 owns deterministic log-only hook recovery. Both PRs require current-
    main refresh, fresh exact-head CI/re-review, merge, and an Aiur rebuild/
    restart before another broad fan-out. Never clone or replace a canonical
    workspace underneath a mismatched live generation.
22. The same fan-out drove host load to 43 while multiple `before_run` hooks
    cold-compiled simultaneously; control reads temporarily timed out although
    the BEAM and tmux session remained alive. Evidence was preserved, the
    runtime ceiling was reduced from 16 to 6, and useful existing workers were
    left running. Raise capacity again only from measured headroom. The 21:32
    hourly retrospective found three recorded wakes and three concrete actions,
    with no token-only wake evidence; cadence remains short during this active
    incident and widens after steady state.
23. Progress-estimate capture is committed on this branch at `b5aecac1` and
    writes only normalized percentage/timestamp/lifecycle facts to private
    operator-local NDJSON. The 23:28 PDT scan retained 191 samples. Latest
    emitted estimates are DASH-006 90%, DASH-017 40%, DASH-018 60%, BO-002
    20%, BO-009 20%, BO-017 20%, and DASH-004 60%;
    and verified BO-001 remains 100% merged. Preserve the earlier
    DASH-006 100% sample even though independent review subsequently returned
    it to rework: that mismatch is phase-end calibration evidence, not a reason
    to rewrite history.
    After the final merge in each GitHub
    `phase:N` cohort, freeze/checksum the cohort, reconstruct implementation,
    local-test, CI, review, rework, and merge tails, run a background analysis,
    and make at most one evidence-backed guidance adjustment (or record no
    change). Apply a changed rubric only to tickets first dispatched after that
    version boundary; never serialize the graph for the experiment.
24. The preview now carries a sixth **Ad Hoc** epic for tickets created during
    execution without changing the approved 54-ticket denominator. Current
    members are #1139, #1140, #1142, #1146, #1148, #1149, #1151, #1152,
    #1154, #1161, #1162, closed duplicate #1164, and deferred #1171; all carry
    `build-lane:adhoc`. Assign `phase:N` only when an ad hoc ticket is actually
    picked up, using the closest active phase, then freeze that assignment;
    #1139, #1151, #1161, and #1162 are Phase 1, while deferred, untriaged, or
    never-picked duplicate tickets remain phase-unassigned and render in the
    preview's TBD row. Repeat this labeling and preview update for every new
    run-created ticket.
25. At 21:56 PDT PR #1150 passed fresh exact-head CI on current `main`, its
    abandoned-lock regression received an independent clean re-review, and the
    Executor squash-merged it as
    `b24e0d7248ace9b53f98802042aae700e73d3316`. This is monitoring/runbook
    infrastructure, not a Build Order member and not #1149; do not count it in
    either the 54-ticket denominator or the Ad Hoc ticket lane.
26. GATE-003 research found a secure Aiur-only DASH-019 path with no
    `aiur-claude` source change: a dedicated loopback OTLP HTTP/JSON logs
    receiver, independent of dashboard enablement, with one unguessable
    capability per registered worker generation. Aiur injects endpoint and
    static auth headers into both the published `aiur-claude@1.0.0` child
    environment and direct REPL/Remote Control launches; the receiver
    authenticates before body read/decode, accepts only logs and allowlisted
    `claude_code.api_request`, and bounds body, connection, rate, replay, and
    sensitive attributes. Exact compatibility evidence pins Aiur
    `db340dcbf51dfaf66814ab457c3e08e4f7b2b38f`, adapter source
    `0f4bea8c08e101fd970dd31b62dba6c5f83bba31`, published adapter 1.0.0, and
    Claude Code 2.1.208. This architecture selection remains an explicit human
    decision; keep #1123 paused until it is ratified and its deleted-inode
    workspace is repaired. No Claude execution or token use is required for
    the gate or its synthetic compatibility fixture.
27. At 22:08 PDT the Executor correlated the repeated fleet build spikes to a
    direct sandbox/build-gate defect. Aiur exported
    `AIUR_BUILD_GATE_DIR=~/.aiur/build-gate`, but that directory was absent
    from the live Codex `workspaceWrite` writable roots. Agent Mix commands on
    at least #1088 and #1151 therefore failed their queue-record write with
    `EROFS`; `build_gate.bash` reported `queue_record_failed` and failed open,
    silently bypassing `max_concurrent_builds: 2`. Dead queue/phase records are
    secondary debris, not the causal defect. P1 Ad Hoc #1154 owns the durable
    sandbox-policy, failure-mode, cleanup, and regression fix. It remains
    phase-unassigned and undispatched while host load is elevated. The root
    dogfood config has a local-only, uncommitted writable-root containment for
    this host; do not copy its machine path into portable defaults.
28. At 22:12 PDT the Executor performed a controlled root-level restart to load
    current `main` plus that containment. New Codex thread settings prove the
    canonical build-gate path is now writable alongside workspace and Git roots;
    the fleet is pinned to Codex 5.6 Sol, and `aiurdev status` reports the shared
    gate enforcing 2/2 active builds. Startup reproduced #1148 by stripping the
    `agent:paused` overrides from #1103/#1123; both labels were restored before
    re-admission. The scheduler also admitted unrelated legacy #855 during its
    AIMD ramp, so the Executor paused it immediately rather than spend a Build
    Order slot. #1030 and #1054 were admitted first to land the two known
    workspace-bootstrap blockers; #1054 was explicitly stopped from pushing a
    stale 407-file local tree and directed to transplant only its bounded issue
    changes onto `b24e0d72`.
29. Independent review of #1151/PR #1153 rejected exact head `ad64fc5e` despite
    green CI. Its `:global.trans` key reused the pathname as requester identity,
    allowing parallel provenance writers to enter together and lose a record;
    generation-time telemetry enrichment also bypassed the central provenance
    predicate. Both focused findings were posted to the existing PR and queued
    to the existing worker with concurrency and telemetry regressions required.
    This is contained #1151 rework, not a new ticket.
30. The 22:34 PDT hourly retrospective found two action wakes and zero
    no-action wakes in its measured hour, so the Executor retained the short
    incident cadence rather than widening during active rework/CI transitions.
    Independent reviews then returned bounded rework to #1030, #1088, #1089,
    and #1151 without filing follow-up tickets. The completed-runner rearm wedge
    recurred on #1030/#1088; normal pause-override recovery restarted #1030,
    while #1088 required reaping one verified idle app-server generation before
    requeue. Treat this as operational evidence for the existing monitoring and
    runner-recovery work, not a reason to expand the current feature scope.
31. At 22:50 PDT #1085/BO-001 was squash-merged as
    `6446dc6cfe24c51d67ff0be577a4486adfb6ccfe` after exact head `4f965f5d`
    passed all fresh CI, contained both prior review fixes, received a clean
    independent re-review, and proved current `main` ancestry. The root checkout
    fast-forwarded without disturbing its local dogfood config. Main-advancement
    directives were queued to active branches before their next push, including
    #1054's bounded linked-worktree candidate.
32. At 23:12 PDT direct workspace blocker #1054/PR #1060 was squash-merged as
    `a83a7e7230ffdc7b266baa287f2abd7b9dee39eb` after exact head `22bc8422`
    passed fresh full CI, a focused clean re-review, and the current-main
    ancestry gate. The Executor preserved the root's local-only dogfood config,
    fast-forwarded `main`, rebuilt the release, and restarted Aiur at runtime
    cap 6. Startup again removed pause overrides, so #855/#1103/#1123 were
    immediately restored to `agent:paused`. New worker settings prove the
    restarted release uses the canonical issue workspace, Codex 5.6 Sol/Terra,
    and the local `/home/orangekid/.aiur/build-gate` writable-root containment;
    do not commit that machine path into portable defaults. Admission is
    ramping rather than cold-starting the full queue simultaneously. At 23:22
    all six admitted slots are real, active workers: blocker #1030, Phase-1
    rework #1088/#1089/#1090, critical-path #1091/BO-002, and #1096/BO-009.
    #1088 initially retained its pre-fix invalid-cwd runner; a deliberate
    pause, observed paused state, and resume created a fresh productive turn.
    Load briefly reached 20.2 during the ramp, so cap 6 remains the measured
    ceiling until the launch/build spike decays.
33. #1088/PR #1144 returned to `agent:rework` after two independent reviews of
    exact head `4ed81f01` found that its equal-timestamp cursor direction,
    full-store GenServer scan, corrupt-prefix health propagation, canonical
    inbox chip counts, and true property/generative coverage remained unmet.
    The deduplicated packet is at
    `https://github.com/its-everdred/aiur/pull/1144#issuecomment-4966048101`.
    Preserve its new replay/security tests, but keep every remaining finding
    on #1088 rather than filing follow-up tickets. Its implementation slot was
    immediately backfilled by #1104/BO-017.
34. Direct blocker #1030/PR #1039 reached exact all-green head `77ec7b60`, but
    two independent reviews found the repair still leases individual turns
    rather than the incumbent runner/session generation. The duplicate can wake
    in an ordinary between-turn or paused-session gap, and abnormal termination
    can leave an unmonitored active-turn entry that parks every retry forever.
    The consolidated packet is at
    `https://github.com/its-everdred/aiur/pull/1039#issuecomment-4966093657`.
    Keep #1030 in rework: require a monitor-backed generation lease spanning
    SessionLifecycle/after-run, exception-safe turn closure, and sequential-
    turn, paused-session, and owner-death regressions. This is the existing
    blocker ticket, not a reason to expand scope.
35. The 23:36 PDT hard hourly retrospective recorded four action wakes
    (workspace-fix merge/restart, stale-runner recovery/backfill, and the two
    review-driven rework packets) plus one isolated no-action 60-second CI
    poll. There were no repeated no-action signatures, so cadence remains
    unchanged rather than tuning from one sample. The next independent hourly
    review is due around 00:36 PDT; immediate event/attention wakes remain in
    force.
36. DASH-017/#1089 exposed a real compatibility conflict: schema 2 makes the
    trusted-provenance binding non-strippable but is rejected by the current
    rollback reader, while schema-1 supplemental fields can all be deleted and
    mistaken for legacy unknown provenance. The Executor kept both acceptance
    contracts and authorized a hash-covered, namespaced string wrapper around
    the already durably reserved integer event identity for newly written
    `requested`/`enriched` snapshots. The persisted Decision envelope uses the
    marked identity so the current reader can require the provenance binding;
    the original reserved integer remains the `Publisher.publish_persisted`
    ID and subscription cursor so global monotonicity is unchanged. The worker
    must prove exact old-reader/new-record replay, complete three-field deletion
    rejection, malformed-marker/tamper rejection, legacy integer/string replay,
    and numeric publisher-cursor behavior. The durable decision is at
    `https://github.com/its-everdred/aiur/issues/1089#issuecomment-4966200021`;
    do not substitute a two-phase rollout or weaken complete anti-stripping.
37. At 00:03 PDT BO-017/PR #1156 exact head `3bc75ee5` completed its second
    review wave. The security/API/reliability reviewer confirmed the earlier
    envelope-spoof, attempt-ID, observed-time, and producer-coverage findings
    are fixed. Correctness review found one remaining P1: queued follow-up
    turns construct `ToolExecutor` without the lifecycle attempt, so their
    observations lose attempt provenance. The second review also required the
    ticket's explicit duplicate-ID, out-of-order occurrence/ingestion, and
    pre/post-`Boot.remark/0` restart regressions; CI separately found contained
    Credo line-length/arity failures. All findings remain on #1104. Its
    app-server turn then stayed idle while Aiur counted the slot as working,
    despite a direct message and durable external PR comments. Because the
    complete owned tree was pushed, the Executor recycled only the
    `agent:rework` transition: the slot immediately backfilled #1090 and #1104
    was safely requeued. This live wake failure was appended to existing Ad Hoc
    #1151 rather than multiplying tickets.
38. The 00:05 PDT progress capture retained 219 normalized samples. Latest
    agent-reported estimates are DASH-006 80%, DASH-017 50%, DASH-018 60%,
    BO-002 20%, BO-009 40%, and BO-017 90% before its contained review rework.
    Static preview commit `de157f90` publishes those exact percentages and
    states; do not silently replace agent estimates with Executor guesses.
39. DASH-018/PR #1141 exact head `cd4a8cc9` passed full CI and closed the
    earlier nine lifecycle blockers, but three independent reviews found two
    privacy P1s and one restart P2. `Handshake.read_account/2` still returned
    the complete account response past the transport boundary; malformed JSON
    could still be logged verbatim by `AppServer.RPC`; and a supervised
    `ProviderAccountGeneration` restart invalidated the live session's captured
    owner authority permanently. All three were reproduced or directly traced,
    posted to #1090, and returned to that existing worker. Its completed CI-wait
    generation again remained counted as working after the rework transition;
    a safe label recycle freed the slot for #1030 and requeued #1090. Add this
    wake evidence to #1151 rather than filing another runner issue.
40. Direct blocker #1030/PR #1039 pushed exact head `a0ceb4ef`; two reviewers
    confirmed the prior between-turn/paused-session and owner-death findings
    are fixed, but adversarial review reproduced one remaining P1. An isolated
    `ActiveTurns` restart recreates empty generation/turn state while sibling
    AgentRunner tasks survive, allowing a duplicate generation to acquire and
    refresh the incumbent workspace. #1030 must make registry failure preserve
    or reconcile leases, or terminate incumbent runners before replacement,
    and prove that restart boundary before merge.
41. BO-002 opened draft PR #1157 at `93b2018b`; build, test, Dialyzer, browser,
    and guards reached green but Credo rejected an over-parameterized and
    over-nested paging implementation plus line/alias findings. The rework must
    consolidate bounded paging state instead of suppressing checks. DASH-006
    pushed reviewed-query head `a6f39901`; its first fresh CI lint found only
    four owned line-length violations while exact-head reviews continued. Both
    packets remain contained on their owning core tickets.
42. The 00:19 PDT sampler retained 231 normalized samples and preview commit
    `efb505e2` publishes the latest emitted values. BO-002 still reported 20%
    despite reaching CI; preserve that discrepancy for the phase-end status
    calibration analysis rather than rewriting the historical estimate.
43. BO-017/#1104 converged at exact head `c35d27ca`: QueueDrain retained the
    original lifecycle attempt through every queued/resumed turn, the stronger
    duplicate/out-of-order/restart gates landed, all required CI passed, and
    three exact-head review lenses were clean. The Executor squash-merged PR
    #1156 to `main` as `d3d6999ac0ef9848423ab58b42c4542f2317c4e8` and the
    issue closed. Core progress is therefore 4/54; BO-005, DASH-002, DASH-008,
    and DASH-026 are dependency-ready once the bounded rework queue permits.
44. By 00:38 PDT five of six counted app-server generations had completed
    turns without rearming after durable rework/CI transitions; only BO-009 was
    still producing events. Every stale ticket had a fully pushed owned tree,
    and BO-009's uncommitted tree was durable, so the Executor performed a
    controlled root restart. BO-009 reported expected `port_exit: 0`; its full
    staged/unstaged tree remained intact and #1096 was returned from
    `agent:error` to rework with a durable recovery note. After BO-017 merged,
    the root fast-forwarded and rebuilt once more on `d3d6999a`. Startup pause
    stripping was contained by immediately restoring #855/#1103/#1123, then
    explicit issue-level resume restored six Codex Sol/Terra workers:
    #1030/#1088/#1089/#1090/#1091/#1096. Do not interpret the controlled
    BO-009 port exit as an implementation defect.
45. The 00:44 PDT sampler retained 245 normalized samples. Preview commit
    `e3935534` records BO-017 as 100% merged and publishes the latest emitted
    estimates; DASH-006's restart reset to 20% is intentionally preserved as
    calibration evidence.
46. BO-002/#1091 pushed lint-clean exact head `31116ae5` and released its
    worker slot into CI, which Aiur immediately backfilled with DASH-004/#1111.
    Three independent exact-head reviews then found contained acceptance gaps:
    cross-page `totalCount` drift could publish a partial graph, canonical
    duplicate identities could evade whole-struct comparison, malformed
    lifecycle state could publish as complete, an unlabeled issue could pass as
    the selected root, failure evidence could erase observed counts, and the
    required selected-root 0/101/drift proofs were absent. With machine load
    above the 12-core count,
    the Executor did not raise concurrency; it paused DASH-004 at its durable
    60% checkpoint and resumed critical-path BO-002 in the same sixth slot.
    Preview state reflects that swap without changing either ticket's emitted
    percentage.
47. DASH-017/#1089 reached exact head `77fa5ed7`; all required CI passed, two
    independent reviews were clean, current `main` was an ancestor, and the
    Executor squash-merged it as `cdd2d7e395fde7048197429bb55aa58c9819a064`.
    A third adversarial review completed just after the squash and traced a
    directly in-scope acceptance gap: ordinary non-debug dispatches do not
    mint `telemetry_attempt_id`, so persisted Decision provenance loses its
    attempt identity outside telemetry-enabled runs. The trace was confirmed
    on landed source. #1089 was reopened in place for the narrow correction;
    no follow-up issue was created and accepted progress remains 4/54 until
    the correction is reviewed, green, and merged.
48. A deliberate runtime pause reserves an agent slot by design; only CI-wait
    pauses release capacity. #1108's brief replacement generation was parked
    to restore BO-002 priority and ended in a contained controlled
    `agent:error`; its durable `agent:paused` override remains until recovery.
    When load fell to 10.5 on 12 cores and only one build slot was active, the
    Executor raised the runtime ceiling from 6 to 7. The reserved #1108 pause
    plus six productive Codex workers now consume that ceiling without adding
    a seventh coding workload.
49. The 01:13 PDT progress capture retained 271 normalized samples. Latest
    emitted core estimates are DASH-006 70%, DASH-017 70%, DASH-018 80%,
    BO-002 30%, BO-009 80%, and DASH-004 50%. Preview state uses those emitted
    estimates and keeps landed-but-reopened DASH-017 out of the accepted count.
50. Subsequent exact-head review kept four superficially green tickets inside
    their original acceptance boundary. #1030 still allowed external agent
    runtimes to survive an `ActiveTurns` restart and allowed an interloper to
    own the replacement ETS table. DASH-018 recovery stranded the session's
    original consumer binding and misclassified nullable Codex `authMode` as
    unsupported instead of logout. Ad Hoc #1151 used a non-unique
    `:global.trans/2` requester, could lose concurrent origin-ledger writes,
    still lacked the reproduced stale-working wake repair, and let telemetry
    reclassify stored agent replies as external. All findings remain on their
    owning tickets; none produced a new issue.
51. BO-009/#1096 opened PR #1158 at `dc2d7fbe`. Vendor pin, integrity, license,
    hashes, and byte sizes are correct, but full CI caught a forbidden
    compile-time `__DIR__` manifest path. Review also reproduced a
    credential-shaped opaque ID crossing the geometry-only worker boundary and
    found that packaged-release/offline and responsiveness tests did not prove
    their production claims. The worker must use release-safe runtime
    resolution without editing the regression guard, enforce non-semantic IDs,
    and strengthen the two acceptance proofs on the same ticket.
52. DASH-017 follow-up PR #1159 at `6f3bf461` correctly mints attempt IDs when
    telemetry is disabled and passed full CI, but its test manually constructed
    the dispatcher output. Review requires the actual telemetry-disabled
    dispatch/run-option-to-Decision path so the production wiring cannot
    regress while the test stays green. BO-002 then pushed its real five-
    invariant repair head `6d897e34`; review and the remaining CI tail now run
    against that head rather than the earlier main-only merge.
53. The 01:35 PDT progress capture retained 298 normalized samples. Latest
    emitted estimates are DASH-006 80%, DASH-017 90%, DASH-018 100%, BO-002
    80%, BO-009 80%, and DASH-004 70%. DASH-018's reported 100% remains visible
    beside blocking review rework as intentional phase-end calibration data.
54. At 01:42 PDT Aiur's applekid `GITHUB_TOKEN` exhausted its REST allowance;
    new/rework generation preflight failed closed until the authoritative
    01:50:50 PDT reset. Operator `gh` keyring auth remained healthy, but the
    Executor did not silently switch worker identity or restart onto a
    different account. Existing local work continued, clean committed heads
    were already pushed, and the six queued/rearmed Codex workers resumed
    automatically after reset. Treat this as a bounded provider window, not a
    reason to file another execution issue.
55. The 01:47 PDT hourly retrospective found an action-dense hour—one merge,
    exact-head review/rework routing, stale-generation recovery, analytics and
    handoff maintenance, and rate-limit diagnosis—but repeated 30–60 second
    reviewer/status polls with no changes were low-value token burn. The wake
    history had not been fed, so the adjustment is now binding: record every
    monitoring outcome and prefer shell/event waits during CI/review tails
    while retaining the operator's five-minute status reports.
56. At 02:04 PDT the static preview's green `ready` label caused an operator to
    reasonably read native dependency readiness as active dispatch. The
    preview now says `dependency-ready` and explicitly records that host load,
    Aiur capacity, declared serialization, and paused state still gate a
    worker. This is presentation clarification, not a change to the approved
    dependency graph or 54-ticket denominator.
57. The host briefly reached load 54 on 12 cores while five workers overlapped
    Mix test, Dialyzer, and release builds. The Executor held new dispatch
    until load fell below the configured hard gate, then restored the one
    independent candidate: DASH-001/#1108 moved from the controlled
    `agent:error` + `agent:paused` hold to `agent:todo` and Aiur started its
    Codex Terra worker at 02:15 PDT. BO-005, BO-016, DASH-002, and DASH-026
    remain dependency-ready but serialize with active DASH-018 and must not be
    fanned out merely to increase the worker count.
58. BO-002/#1091 pushed exact head `3ed5a427` with fresh all-green CI after
    repairing OPEN lifecycle validation. Its worker remains paused while two
    independent exact-head review waves run in isolated report-only
    worktrees; review capacity, not another implementation turn, is now the
    fastest route to the next critical-path merge.
59. DASH-001/#1108 reproduced a workspace-provisioning race already seen in
    BO-016/#1103: a logs-only directory was accepted as an existing workspace,
    source and `.git` appeared during repair, then vanished underneath the live
    Codex process, which terminated with `invalid cwd`. The Executor preserved
    checksummed logs, quarantined the source-free workspace, and performed one
    bounded `agent:todo` requeue; capacity/load still gates its next dispatch.
    P1 Ad Hoc #1161 owns the bounded durable fix—single provisioning ownership,
    atomic logs-preserving repair before provider startup, and overlapping
    retry/resume regressions. It deliberately has no `phase:N` or `agent:todo`;
    assign the closest active phase only when safe capacity actually picks it
    up.

60. A production queue-drain audit correlated four stranded Codex workers
    (#1088, #1091, #1096, and #1111) with the same lifecycle defect: each
    runner remained inside `Aiur.AppServer.TurnLoop.receive_loop/2` after the
    provider emitted idle plus `turn/completed`, while 8–12 operator messages
    accumulated. Aiur seeds one outstanding turn and increments the counter for
    every successful operator `turn/start`; multiple deliveries during one
    provider turn can therefore leave a positive counter after the provider's
    finite completion signals. Phase 1 P1 Ad Hoc #1162 owns the durable fix and
    system regression. A daemon restart is recovery only; perform it at a safe
    checkpoint for the actively turning #1090 and #1103, then verify queued
    rework drains and #1162 is dispatched.
61. Two independent exact-head reviews returned Ad Hoc #1151/PR #1153 to
    rework despite green CI. The consolidated contract covers restart-stable
    origin persistence, post-mutation verification failures, top-level PR
    comments, atomic completed-runner replacement, pre-queue origin filtering,
    bootstrap filtering, and the binding reply→CI-wait→poller end-to-end test.
62. Phase 1 P1 #1162 reproduced the logs-only workspace race on first pickup:
    `before_run` failed, the transient workspace contained only agent logs, and
    the directory then disappeared. This is a new production occurrence of
    existing Ad Hoc #1161, not a new ticket. #1161 was promoted to Phase 1 and
    `agent:todo`; after the safe daemon restart both #1161 and #1162 provisioned
    complete git workspaces and began Codex Terra/Sol turns successfully.
63. At 03:21 PDT the Executor restarted Aiur from the repository root in
    background debug mode after #1090 and #1103 had committed and pushed all
    source changes. The non-loopback dashboard correctly refused to bind until
    local gitignored basic-auth credentials were restored; never copy those
    credentials into this handoff, issues, commits, or logs. The authenticated
    dashboard is live on the configured Tailscale address and the debug run now
    preserves `aiur.log` plus telemetry evidence.
64. Unrelated deferred reliability issue #855 still carried stale
    `agent:in-progress`, so startup restored it as a reserved paused row. The
    Executor moved it to `agent:human-review`; it is deactivated, consumes no
    worker or reserved capacity, and must not re-enter the Build Order run.
65. At 03:43 PDT the nine-worker fleet crossed into a duplicate-build cascade:
    host load reached 65, the control RPC timed out, #1161 had three copies of
    the same focused tests, #1162 had two, #1096 had overlapping Dialyzer/PLT
    jobs, and paused #1123 still had compilers alive. The Executor terminated
    only redundant Mix children, then stopped Aiur cleanly when workers
    immediately respawned them. All workspaces and uncommitted ticket work were
    preserved. Aiur restarted from the repository root with dashboard auth
    intact and a temporary `--max-agents 8` ceiling. Treat eight as the current
    measured-safe envelope, not a permanent product limit; raise it again only
    after the load/build-gate evidence supports doing so.
66. The restart reproduced Ad Hoc #1148: startup stripped `agent:paused` from
    #1103, #1108, and #1123. The fresh #1103 generation sees its valid preserved
    checkout and is productively handling its existing CI contract, so it may
    continue. The Executor restored the suppressing label on #1108 (still a
    logs-only workspace) and #1123 (GATE-003 still unratified). Reapply those
    holds after every restart until #1148 lands; do not create another ticket.
67. Two independent exact-head reviews rejected #1090/PR #1141 at green head
    `01a084fc`. The bounded five-part contract is recorded on issue comment
    `4968360572`: quarantine only a matching late sensitive response, sanitize
    account payload/method handling end to end, prevent cross-process stale
    session resurrection, bound generation retention, and restore the
    repository module-size contract. #1090 is unpaused and implementing that
    exact scope; it needs fresh CI and two new exact-head reviews after push.
68. Preview percentages at 03:58 PDT use each worker's latest durable
    `progress.checkin` claim rather than Executor intuition. This intentionally
    preserves stale or optimistic claims (for example #1090 still reports 80%
    from the pre-review lifecycle) for the end-of-phase estimate-calibration
    analysis. Current claims are #1088 70%, #1089 60%, #1090 80%, #1091 20%,
    #1096 60%, #1103 70%, #1161 20%, and #1162 30%.
69. #1091 independently filed #1164 for sandbox-local PID reuse leaving stale
    shared build-gate leases. The evidence is valid but is already contained by
    Ad Hoc P1 #1154's namespace-safe ownership, stale-metadata reclamation, and
    real turn-sandbox coverage criteria. The Executor retitled and labeled
    #1164 into the Ad Hoc ledger, then closed it as a duplicate without a phase
    because it was never picked up. Keep the reproduction as evidence; never
    dispatch #1164 or count it as additional executable scope.
70. DASH-017/#1089 passed two independent exact-head reviews and fresh full CI,
    then squash-merged to `main` as `4f49e0a1d3c88054905b2edbaa6a3a1ffa2b7a10`.
    It directly unlocked no new ticket because DASH-007 still needs DASH-001
    and DASH-006.
71. Aiur's configured `GITHUB_TOKEN` exhausted its REST budget at 04:49 PDT and
    reset at 04:51:46. The daemon recovered on its first post-reset tracker poll
    without a restart. Do not confuse this condition with agent-slot starvation:
    correlate the auth preflight log before changing capacity.
72. The preview exposed three genuinely unassigned dependency-ready tickets,
    not five: #1093/BO-005, #1109/DASH-002, and #1130/DASH-026. #1093 and #1109
    are live; #1130 is queued at the eight-worker ceiling. Cards already in
    review or recovery may look available at a glance but are not new work.
73. P1 #1161/PR #1166 recovered from its finalization wedge without restarting
    Aiur by terminating only the stale finalized provider process group. Its
    first CI head failed the protected-regression guard, four owned workspace
    lifecycle tests, and Credo complexity. The Executor refused regression-test
    approval, routed the bounded production-behavior rework, and unpaused the
    existing worker. This P1 retains priority over queued #1130.
74. The 05:06 PDT hourly retrospective found an action-dense hour: #1089 merged,
    three dependency-ready tickets were dispatched, GitHub rate-limit recovery
    was verified, reviews were routed, and workspaces were recovered. The only
    clear low-value polling was repeating `aiurdev agents` after its control RPC
    had timed out or returned blank. Use 60–90 second quiet waits, then prefer
    daemon/GitHub evidence after one control timeout; record each wake outcome
    so the next hourly sample has quantitative counts.
75. #1109 and #1093 reproduced P1 #1161 while the unfixed daemon was still live:
    competing generations replaced their checkouts during agent use or clone.
    #1109 recovered through one guarded retry and is productive. #1093 failed a
    second clean clone because its pack directory vanished mid-write, so the
    Executor applied `agent:paused` until #1161 lands. This is existing P1
    evidence, not authority for another ticket.
76. Two independent reviews of #1162/PR #1165 converged on one P1: Codex emits
    idle before the paired interrupted completion, but the branch exited on idle
    and bypassed pause/operator interruption routing. #1162 is implementing the
    single contained ordering fix plus sequence regressions.
77. Two independent reviews of #1103/PR #1163 found two BO-016 P1s: the default
    request function accidentally selected the literal test token instead of
    configured GitHub auth, and generic Authorization Bearer/Basic values could
    survive snapshot/PubSub sanitization. #1103 is active on that bounded rework.
78. Two independent reviews of #1091/PR #1157 returned a six-part BO-002
    fail-closed contract: effective portable GitHub config, nullable GraphQL
    nodes, missing-identity classification, label diagnostics, external endpoint
    identity, and duplicate external endpoints. #1091 is rework-queued at the
    measured capacity ceiling; no separate follow-up issues were created.
79. #1130/DASH-026 recovered from an initial provider port exit, completed the
    guarded bootstrap, and started a Terra session. It is now productive rather
    than merely dependency-ready.
80. The operator reaffirmed the Ad Hoc display contract: every issue created or
    promoted during the active Build Order run belongs to the derived
    `build-lane:adhoc` epic, and receives the phase closest to first pickup.
    Deferred and never-picked tickets stay in the visible TBD row; closed and
    duplicate tickets remain historical members. BO-020/#1107 now carries the
    durable implementation clarification in issue comment `4969151682`; the
    real page must derive this overlay from GitHub plus Aiur while keeping it
    outside the fixed 54-member denominator, complexity total, critical path,
    and ETA. After decision 79, #1130's live checkout was replaced by
    scaffolding-only contents, so the Executor paused it as another occurrence
    of P1 #1161 and recycled only its stranded provider process.
81. The applekid tracker token exhausted its REST window through 05:51:47 PDT.
    Local Codex turns, Executor GitHub reads, and exact-head reviews continued;
    the Executor recycled only two confirmed finalization wedges and did not
    restart the daemon. The inherited token was healthy by the reset, tracker
    polling recovered naturally, and #1096, #1151, and top-priority #1161 all
    received fresh Sol/Terra generations.
82. BO-009/#1096 reached full green CI on current `main`, but two independent
    exact-head reviews found eight contained protocol/platform defects: lane
    order still depended on request order, self-loop coverage was missing,
    authenticated assets were publicly cacheable, main-thread size bounds ran
    after serialization, request IDs were not generation-bound, sparse arrays
    bypassed validation, reply geometry/diagnostics were under-validated, and
    audited asset bytes lacked an EOL contract. All eight were returned to the
    existing worker in issue comment `4969297192`; no new ticket was created.
83. BO-002/#1091 pushed current-main rework head `c039eba3` and BO-016/#1103
    pushed current-main security rework head `4b6e5221`; both are in fresh CI.
    BO-016 is fully green and has entered a new dual exact-head review. The
    first DASH-006/#1088 re-review is clean at green head `b96c32ac`; its second
    independent review is still running.
84. DASH-004/#1111 completed a broad contained rework but left the validated
    source/test tree uncommitted after mistaking an earlier protected-regression
    branch delta for immutable baseline content. The Executor directed a
    byte-for-byte restore from current `origin/main`, then added
    `agent:paused` to protect the large dirty checkout from P1 #1161. Resume
    only after #1161 lands; do not reprovision or discard this workspace.
85. Ad Hoc #1162 pushed green current-main interruption-ordering head
    `99732697`. Its attempted CI-wait transition was immediately displaced by
    the still-unfixed self-comment wake path owned by active #1151, so the
    Executor applied `agent:ci-wait + agent:paused`, removed the redundant
    generic `model:codex` label, and started the first exact-head re-review.
86. Both exact-head #1162 reviews converged on the remaining no-active-turn
    pause race: `Interrupts.handle_interrupt_error/2` still cleared the original
    `:pause` action after deferred idle and returned ordinary completion. The
    Executor routed the single contained receive-loop regression packet at
    issue comment `4969528392`, removed the review hold, and dispatched the
    existing Terra worker. No new ticket was created.
87. BO-016/#1103 dual review of green head `4b6e5221` found six contained
    contract defects: structured credential redaction, omitted-body schema
    handling, eviction notification, hung-refresh timeout, URL-safe repository
    identity, and bounded retry-after values. The consolidated rework packet is
    issue comment `4969611318`; all fixes remain on #1103.
88. BO-002/#1091 had one clean exact-head review, while the independent second
    review found that HTTP-200 GraphQL `RATE_LIMITED` errors bypass reset-aware
    handling and become generic partial data. The Executor verified the branch
    behavior and returned only that P1 (plus its promised `FORBIDDEN` taxonomy
    regression) in issue comment `4969623352`.
89. Workspace-safety P1 #1161 pushed current-main head `e612dbd9`, and fresh CI
    is fully green. Two independent exact-head reviews are active; keep the four
    workspace-race holds in place until this head is reviewed and merged. The
    06:13 hourly monitoring retrospective was action-dense (four of five wakes
    produced work); retain event-driven wakes and the 60-second quiet ceiling,
    and avoid polling while exact-head reviewers are the only outstanding work.
90. Both #1161 reviews rejected `e612dbd9`: partial/unborn Git workspaces were
    accepted as ready, logs-only reconstruction was incompatible with generated
    hooks and concurrent log writes, Registry ownership could disappear while
    reparented Codex descendants still used the cwd, and contention became a
    one-second retry/thrash loop with unbalanced setup telemetry. The contained
    packet is issue comment `4969737562`. At the same time, seven slots remained
    falsely `running` at completed turns and queued Executor messages could not
    start a new turn; pause/resume also hit #1162's no-active-turn race. The
    Executor made deliberate holds restart-safe by temporarily removing their
    active-state labels while retaining `agent:paused` (#1090=rework,
    #1093=todo, #1108=in-progress, #1111=rework, #1123=rework,
    #1130=in-progress), restarted Aiur from the repository root, and explicitly
    resumed #1088, #1091, #1096, #1103, #1109, and #1151 after #1161/#1162
    started. All eight intended Codex workers now have fresh generations. Restore
    the recorded active-state labels only after #1161 merges; never restore them
    merely because the daemon restarted cleanly.
91. A host-capacity audit found three `agent-browser` daemon/browser trees
    orphaned to PID 1 for 8–12 hours, including renderers consuming roughly
    48–66% CPU each. The Executor terminated only those proven orphan parent
    daemons, recovered roughly 2.5–3 GB of RAM, preserved every current worker,
    and recorded sanitized evidence on deferred Ad Hoc #1142 in comment
    `4969926684`. This is capacity evidence for the existing deferred ticket,
    not authority to dispatch it or create another issue.
92. DASH-006/#1088 reached fully green current-main head `20c5f74b`. One exact-
    head reviewer was clean; the independent reviewer found that a same-ID
    bounded-overview row could render an older Decision while answer/revision
    commands targeted the newer retained version. The contained P1 and two
    version-collision regressions are routed in issue comment `4970048063`.
    The old worker had already consumed all 12 continuation turns waiting for a
    terminal CI event that GitHub had completed but Aiur never delivered, so
    the Executor cycled only #1088's active-state label to force a replaceable
    fresh generation. #1151 already owns the self-comment/CI-wake lifecycle;
    do not file a duplicate.
93. Ad Hoc #1162 pushed exact head `86e979e1`, but fresh CI disproved the
    worker's load-only classification: lint found six nested-module alias
    violations, and full coverage left queued rework `:delivered` instead of
    `:consumed` in the ticket's core completed-runner replacement regression.
    The bounded fix packet is issue comment `4970116310`. The Executor is
    cycling only #1162's completed generation before returning it to rework;
    preserve both the new pause path and the pre-existing exactly-once drain
    contract, and create no additional ticket.
94. The operator clarified the Build Order card-state contract for both this
    preview and BO-020: reserve a green background plus green border for a
    ticket with an explicitly live Aiur agent; render merged or closed work as
    a solid grey card with grey text and borders while keeping the card fully
    selectable for historical detail; and distinguish dependency-ready but
    unstaffed work with a dashed blue border. The static preview demonstrates
    this with explicit `agent_live` evidence. The shipped page must derive live
    state from authoritative Aiur runtime identity and completion from GitHub,
    never infer either from free-form status text.
95. PR #1144 is a required case study for deferred Executor optimization issue
    #1142. It has spent roughly 11.5 hours across 17 commits and repeated
    exact-head review/rework/CI cycles, including late discovery of cursor,
    boundedness, property-coverage, performance, and same-ID selection defects
    plus a missing terminal-CI event that exhausted one worker generation.
    Analyze its timeline after the feature phase for duplicated reviewer
    discovery, feedback batching, review timing, CI/event latency, and whether
    acceptance evidence could have been front-loaded. This analysis must not
    delay DASH-006 or promote a new in-boundary ticket.
96. BO-002/#1091 reached green current-main head `f0ea7fbc`, but dual exact-
    head review found that malformed HTTP-200 GraphQL envelopes could still
    escape the controlled provider-schema taxonomy through transport clauses
    and unvalidated `get_in/2` boundaries, and that the selected root could be
    accepted as its own executable member. Both findings were returned to the
    existing ticket in issue comment `4970344090`; #1091 is back in rework and
    no follow-up ticket was created.
97. BO-009/#1096 reached green current-main head `f703f85f`, but dual exact-
    head review found a missing EPL source-availability notice, a reproducible
    sparse-array validation bypass in both the worker and client, unchecked
    duplicate/extra engine-result identities, and incomplete U3/U4 boundary and
    denied-subresource coverage. Both reviewers reproduced the sparse-array
    defect, including a normal worker result for the malformed input. The
    consolidated contained packet is issue comment `4970450763`; #1096 is back
    in rework and no follow-up ticket was created.
98. DASH-006/#1088 reached green current-main head `d434a293`, but dual exact-
    head review found four remaining P1s: capability-bearing artifact URLs
    escaped presentation, canonical safe DASH-017 provenance was truncated, an
    authoritative selected detail disappeared under a stale lifecycle filter,
    and answer/revision draft state survived same-ID version changes. The
    contained packet is issue comment `4970590437`; #1088 is back in rework.
99. The first #1088 replacement consumed its older CI handoff instead of the
    newer review comment, then left conflicting `agent:human-review` and
    `agent:in-progress` labels. The Executor restored a single `agent:rework`
    state and started a fresh generation. Treat this ordering failure as more
    evidence for active Ad Hoc #1151, not authority for another issue.
100. BO-016/#1103 reached green current-main head `f4a7679d`, but dual exact-
    head review found incomplete assignment/JSON-header credential redaction,
    cache exit and LKG loss when refresh task startup is unavailable, uncovered
    common local-path roots, and acceptance of noncanonical repository URLs.
    All four are routed in issue comment `4970663636`; #1103 is back in rework.
101. Workspace-safety #1161's replacement reconciled against a stale CI-wait
    workpad even though head `eebea883` had terminal red CI: fourteen common-
    path lifecycle/reconstruction failures and seven owned lint findings. The
    Executor made the failure packet durable in issue comment `4970685110`,
    recycled only the completed provider generation, and preserved the daemon,
    branch, and protected regression tests.
102. Dual review of Ad Hoc #1151 found seven merge-blocking provenance and
    lifecycle defects, including atom/string origin mismatch, post-hoc or
    ignored comment receipts, missing Claude split-call provenance, lossy
    thread deduplication, origin-blind publisher replay, GraphQL partial-
    success identity loss, and latest-comment substitution. The packet is in
    issue comment `4970767103`. A replacement then consumed a stale workpad
    instead of that newer comment; the Executor promoted the packet into the
    workpad and restored one authoritative `agent:rework` state. Keep every
    finding on #1151.
103. BO-002's real-provider probe initially rejected the live graph because
    closed external gate #1139 still appeared as a native blocker of #1086 and
    #1087 even though it is not one of root #1084's 54 members. The Executor
    removed only those two obsolete `blockedBy` edges; root membership did not
    change. The repeated probe is complete with 54 members, 105 unique
    normalized edges, 210 source endpoints, zero diagnostics, and three
    calls/pages.
104. BO-002/#1091 dual exact-head review found two contained pagination and
    error-taxonomy blockers: accepting `hasNextPage: true` at the advertised
    total before an empty terminal page, and misclassifying invalid caller
    input as provider schema failure without a provider call. Both are routed
    in issue comment `4970887555`; #1091 is in rework.
105. BO-009/#1096 dual exact-head review found three contained platform-boundary
    blockers: a rejected engine-start promise that never recovers for the same
    client, a roughly 15.5 MB aggregate response admitted by per-section caps,
    and a 64-point contract that permits 66 total points with endpoints. The
    packet is in issue comment `4970900330`; #1096 is in rework.
106. At 08:25 PDT Codex reported account-wide `usageLimitExceeded` with
    `willRetry: false`; Aiur correctly paused every Codex worker without retry
    churn. After the operator reset the quota at 08:31, the Executor resumed
    only the six intended paused Build Order/Ad Hoc workers and confirmed all
    six turning. Unrelated #855 remains paused, and no Claude fallback was
    used. A reset does not currently wake these paused workers automatically;
    retain explicit targeted resume as the recovery step for this run.
107. Ad Hoc #1162 reached green exact head `9b69a5b3`, but two independent
    reviews reproduced the reverse-order pause race: when the `-32600` no-
    active-turn response arrives before idle, the accepted pause is cleared
    and later reported as ordinary completion. The consolidated packet is in
    issue comment `4970988944`; preserve pause across both response/idle event
    orders and prove the Adapter plus real AgentRunner boundaries on #1162.
108. DASH-002/#1109 reached green exact head `027218cb`, but both independent
    reviewers reproduced two P1s: corrupt-journal quarantine loses its
    validated prefix after a second same-run restart, and normal PR-merged plus
    retry-terminal teardown bypasses terminal persistence. One review also
    found that nested checkpoint members accept content-bearing extra keys,
    violating this ticket's exact content-free security contract. The
    consolidated three-finding packet is in issue comment `4971048783`; #1109
    is in rework and no follow-up ticket was created.
109. #1109 exposed the known self-comment/stale-resume lifecycle owned by
    active Ad Hoc #1151: after the Executor's rework comment and label change,
    a resumed provider received an older CI-rewake handoff, restored human
    review without changing the head, and never observed the new review comment.
    Exact label/event timestamps and provider-log evidence are attached to
    #1151 in comment `4971112197`. The Executor promoted the rework packet into
    #1109's authoritative Workpad, restored `agent:rework`, sent a direct
    control message, and confirmed the replacement generation working. Do not
    file a duplicate lifecycle ticket.
110. Workspace-safety #1161 pushed exact head `36a0d0b2`; terminal CI found two
    owned failures: the existing-checkout lifecycle regression returned
    `created?: true`, and `Aiur.Orchestrator.State` crossed Credo's 31-field
    limit. The packet is in issue comment `4971161717` and the authoritative
    Workpad. Because the completed provider did not consume the direct message,
    the Executor used targeted pause/fallback reap/resume rather than a daemon
    restart; the new Terra generation started at 08:54 PDT and is actively
    repairing both failures. This recovery preserved all other workers and the
    dirty #1161 workspace.
111. BO-002/#1091 reached all-green exact head `93179654`. One independent
    review was clean; the second reproduced one P2 acceptance blocker:
    `parent_identity/2` used `Map.get/2`, making a missing required root
    `parent` key indistinguishable from an explicit `null`. The contained
    `Map.fetch/2` plus selected-root/catalog-sibling regression packet is in
    issue comment `4971378655`. #1091 is back in a fresh Terra rework turn; no
    follow-up ticket was created.
112. Three fresh heads terminated with contained owned CI repairs. DASH-006
    #1088/`10c24530` has one unreachable-pattern Dialyzer finding
    (`4971361862`); BO-016 #1103/`a80691a1` has one implicit-`try` Credo finding
    and one opaque-bitstring Dialyzer finding (`4971268463`); Ad Hoc
    #1151/`7f09a44c` has alias ordering, two impossible message-handler branches,
    and one GitHub-client error-contract assertion (`4971327769`). All three
    packets stayed on their existing tickets. #1088 and #1151 required
    ticket-scoped stale-generation recycling; #1103 resumed from its preserved
    local repair commit. #1088 has since pushed `959a7bc5` and #1103 has pushed
    `416161c4`; both are in fresh CI while #1151 remains actively repairing.
113. DASH-002/#1109 pushed `18bd791f`, workspace-safety #1161 pushed
    `abd8e040`, and interruption accounting #1162 pushed `374c1bae`. Each is in
    event-driven CI wait. Their paused control rows are intentional resource
    release, not quota exhaustion or stuck agents.
114. BO-009/#1096 reached all-green exact head `2e01fb0f`. Its completed
    generation still retained an effective slot while two background reviewers
    ran, starving #1088's retry. The Executor removed the stale active-state
    label and retained `agent:paused` as an explicit external-review hold. This
    supplies review parallelism without spending a provider slot; restore an
    active state only if review returns contained rework.
115. #1088's first recycled generation attempted to return a successful
    `progress.checkin` tool result through an already-closed app-server port,
    raised `port_command` `:badarg`, and entered retry. This is directly within
    active #1162's completed-worker replacement contract, so production evidence
    was attached there in comment `4971444982` rather than spawning another
    reliability issue. The replacement #1088 generation is productive.
116. The 09:16 hourly retrospective measured four Executor wakes in the prior
    hour: three produced concrete recovery/routing actions and one was a known
    scheduler-saturation RPC timeout. No no-action pattern repeated, so the
    adaptive 2–20 minute event-first cadence remains unchanged.
117. After the operator reset the Codex allowance at 09:28 PDT, the daemon
    immediately resumed account/token notifications at 8% of the weekly
    window. Every actionable provider wrote fresh events; all configured and
    replacement workers remain Codex Sol/Terra and no Claude worker was
    started. Completed rows were left quiet only when CI or Executor review was
    the real gate.
118. BO-009/#1096 dual review converged on one contained P2: no regression
    independently crossed the 256 KiB response ceiling without first crossing
    8,000 route points. The packet is in comment `4971590452`; a replacement
    pushed test-only head `2d77d064`, with worker/client byte-only assertions,
    and returned to fresh CI without a follow-up ticket.
119. Workspace-safety #1161 was green at `abd8e040`, but its two exact-head
    reviews plus one targeted falsification pass proved four P1 races: a
    release-before-contention lost wakeup, ambiguous invalid/non-Git workspace
    handling that can skip bootstrap or delete WIP, process-group containment
    registered after startup can block, and cold fallback deletion outside the
    log lock. The bounded packets are comments `4971636979` and `4971683201`.
    The stale completed generation did not consume the first message, so the
    Executor deactivated only that ticket, then started a fresh Terra rework
    generation; the daemon and every sibling worker remained live.
120. BO-016/#1103 reached green head `416161c4`, but dual review reproduced
    common password/private-key forms and absolute `/etc`/`/opt` paths escaping
    the ticket-detail snapshot/PubSub sanitizer. Both P1 sanitizer regressions
    remain inside #1103 via comment `4971685901`; its completed generation was
    deactivated and a fresh Terra rework generation is active.
121. DASH-002/#1109 disproved its single queue test failure as owned, repaired
    it, and pushed `9aa45db0`; completed-worker recovery #1162 incorporated the
    observed closed-port tool-reply failure and pushed `f3e0d32b`. Both are in
    fresh event-driven CI. BO-002/#1091 pushed `5f75e8b7` and is repairing the
    fresh lint result without widening scope.
122. Ad Hoc #1151's long local coverage run reproduced its terminal CI exactly:
    one GitHub-client assertion still expected the pre-repair GraphQL error
    shape, while Credo found one alias-order and one line-length issue. Coverage
    otherwise completed at 85.78%. Comment `4971733840` and a direct operator
    message returned those three contained repairs to the existing worker.
123. DASH-006/#1088 reached all-green `959a7bc5`. One exact-head reviewer was
    clean; the other reproduced ticket URL userinfo/query/fragment capability
    fields and raw source `agent_id` crossing the provider boundary. Executor
    inspection confirmed the ticket's explicit credential/account-identity
    exclusion was unmet. The single contained P1 packet is comment
    `4971763118`; #1088 is active on the bounded presenter regressions.
124. BO-009/#1096 pushed byte-cap regression head `2d77d064`, passed fresh CI,
    and passed two exact-head reviews clean. The Executor verified `main` as
    base and ancestor, zero unresolved review comments, then squash-merged PR
    #1158 as `b5061465`. The prewarmed base refreshed to that exact commit.
    This moved the fixed core graph to 6/54 and unlocked BO-010/#1097; the
    Executor added its dispatch label and a fresh Terra worker started.
125. Four completed turns retained active tracker labels after claiming they
    had entered CI wait, starving the newly ready ticket. The Executor moved
    #1091 and #1109 to external-review holds and #1162 to CI wait, which released
    capacity for #1097. #1151 twice consumed its stale green-CI Workpad instead
    of the newer terminal packet, so comment `4965195685` was updated to make
    the three owned repairs authoritative before a ticket-scoped recycle. This
    is additional evidence for active #1162, not a new issue.
126. BO-010/#1097 initially started without a Git checkout. The Executor paused
    only that ticket, materialized its canonical workspace from the prewarmed
    base at exact current `main`, preserved its logs, and created branch
    `aiur/1097-bo-bo-010-build`. Resuming the old provider generation then
    failed with `invalid cwd` because it retained the removed inode; comment
    `4971941425` records that direct recurrence for #1161. A fresh Terra
    generation now owns the repaired workspace and is implementing normally.
127. Both independent reviews of DASH-002/#1109 head `9aa45db0` confirmed two
    P1s: corrupt-checkpoint quarantine can precede durable degraded-state
    persistence, and the initial zero-delay poll can still escape the queue
    test's freeze helper. They also recorded stale-base and idle-terminal
    persistence gaps. The consolidated contained packet is comment
    `4971925799`; a fresh worker is repairing those findings without a new
    ticket.
128. BO-002/#1091 merged current `main`, pushed `d384f538`, and passed every
    required CI job. `origin/main` is its ancestor and two independent
    exact-head reviews are running. BO-016/#1103 merged current `main`, pushed
    `cd0fec80`, and entered fresh CI after its sanitizer repairs. Neither
    completed generation consumes an implementation slot while those external
    gates run.
129. The operator reset the Codex quota at 10:15 PDT. Aiur observed Codex
    available again (weekly usage 13% at 10:23), but completed generations for
    #1088, #1151, and #1162 did not consume direct messages. The Executor
    deactivated and restarted only those ticket generations on their preserved
    workspaces; all six actionable workers are now live on Sol/Terra and Claude
    remains unused. #1091 is intentionally in a non-active human-review state
    while external review owns its gate.
130. The live daemon twice crashed and restarted `Aiur.IssueLog` while
    formatting an attention-event source map through `String.Chars` at
    `issue_log.ex:390`. Agents continued and durable ticket logs remained
    available. This is a reproducible P2/P3 observability defect under the
    current evidence, so scope freeze records it here rather than filing or
    dispatching another Build Order blocker; promote only if it loses evidence
    or blocks dashboard acceptance.
131. The 10:26 hourly Executor retrospective found an action-dense interval:
    BO-009 merged, BO-010 was recovered, dual-review findings were routed, and
    the quota-reset fleet was restored. No repeated monitoring-only period was
    observed. Keep the adaptive 2–20 minute event-first cadence, record every
    wake outcome, and reserve forced checks for five-minute reporting
    boundaries.
132. Six concurrent Elixir gates briefly drove load to 62 on the 12-core host.
    The Executor removed one orphaned read-only diagnostic process and lowered
    the runtime ceiling to six without interrupting any worker. When load fell
    to 14 with 20 GiB available, the operator clarified that future Executors
    must continuously target 10–15+ useful agents and saturate CPU or the next
    measured bottleneck. The ceiling was restored to 15. Any future reduction
    is temporary, must name a restoration threshold, and must be reversed as
    soon as it clears; do not let a defensive cap become the steady state.
133. BO-016/#1103 passed current-main CI at `cd0fec80`, then both exact-head
    reviews reproduced three P1s: timeout cleanup can crash the cache and lose
    LKG when `Aiur.TaskSupervisor` restarts, PEM/URI-userinfo credentials still
    cross Snapshot/PubSub, and structural local paths including `file://` and
    `/nix/store` survive redaction. One reviewer also confirmed the raw-input
    limit is checked only after redaction. Comment `4972295749` consolidates
    the bounded rework; return #1103 to a fresh worker immediately.
134. Dual exact-head review rejected green DASH-006/#1088 head `5e85d814`:
    the public Decision API still bypasses retained cursor/bounded reads,
    basic-auth-shaped agent identity remains exposable, and corrupt-prefix
    partial pages prescribe an ineffective filter refinement. Comment
    `4972363725` consolidates the contained rework; #1088 is actively turning.
135. DASH-002/#1109 reached terminal red CI at `2594b0d2` with two owned Credo
    rejects and two membership-store process-death failures. Its completed
    runner ignored the direct packet and replayed stale CI-wait guidance. The
    Executor used the proven ticket-scoped pause/fallback-reap recovery and
    resent comment `4972375941`; do not treat the unchanged red head as CI wait.
136. The shared build gate exposed a second P1 mode under Codex PID namespaces:
    sandbox clients publish `pid=2, pgid=1`, collide on `queue/2`, and produce
    unreclaimable slots because the corresponding host identities are always
    alive. Host correlation proved slot 1 stale while slot 2 still belonged to
    #1161, so only slot 1 was reclaimed and #1103 acquired it immediately.
    Existing #1154 now owns namespace-stable lease identity in addition to its
    writable-root/fail-closed contract and is dispatched in Phase 1.
137. Dual review rejected self-comment fix #1151 at `454a07df`: provenance is
    acquired only after a top-level `gh` mutation may have started, origin
    persistence failures are discarded by TurnLoop, newer trusted rework does
    not supersede stale `ci.rewake`, and quoted `gh api` paths evade detection.
    Comment `4972454499` contains the bounded repair; #1151 is actively turning.
138. Dual review rejected completed-turn fix #1162 at `376cc03e`: accepted
    steering response IDs remain outstanding without idle, interrupt success
    plus idle-only never settles, and late start frames can resurrect completed
    IDs. Comment `4972451049` contains the bounded lifecycle matrix; #1162 is
    actively turning. These findings directly match #1109's live wedge.
139. The binding maximum-useful-concurrency rule landed on accepted `main` as
    `69a53b99`: every Executor now starts from the recorded safe maximum,
    continuously fills dependency-ready implementation and review lanes,
    lowers the runtime ceiling only for a measured bottleneck with an explicit
    restoration condition, and immediately restores it when that condition
    clears. Do not confuse blocked/CI-wait tickets with useful utilization, but
    also do not let a defensive cap silently become the steady state.
140. #1151 reproduced the exact review/CI ordering defect it is repairing: its
    worker pushed a current-main-only refresh and changed its Workpad to CI wait
    seconds before comment `4972454499` delivered the later dual-review packet.
    The Executor repaired the authoritative Workpad, returned the issue to
    rework, and confirmed a fresh Terra turn is applying all four findings.
    This is production evidence for #1151/#1162, not authority for a duplicate.
141. BO-002/#1091 finished all-green CI at `35bec1cd`, but
    `git merge-base --is-ancestor origin/main HEAD` failed against accepted
    `main` `69a53b99`. The Executor withheld dual review, posted durable comment
    `4972541722`, returned the ticket to rework, and messaged the live worker to
    merge current main and produce a new exact-head CI result. Green stale-base
    CI never consumes review capacity or merge authority.
142. The same current-main ancestry gate rejected BO-016/#1103 head
    `f09ff6b9` after green CI and completed-turn #1162 head `3bafcf31` while its
    final test job was still running. Both received durable issue comments,
    direct messages, and fresh rework turns to merge `69a53b99`; no reviewers
    were spent on stale heads. With those turns active, every one of the nine
    dependency-ready lanes is staffed.
143. The 11:26 hourly Executor retrospective found an action-dense hour: review
    and red-CI packets were routed, stale-base gates prevented wasted reviews,
    completed workers were recovered, the maximum-useful-concurrency rule was
    made binding, and the handoff/preview were refreshed. Its durable history
    contains two action wakes and no no-action wakes, so retain the event-first
    adaptive 2–20 minute cadence, five-minute reporting boundary, and separate
    hourly audit unchanged.

144. At 11:46 PDT the daemon service token exhausted its GitHub REST quota
    while reprovisioning BO-002/#1091. This was not a Codex usage limit and did
    not justify a fleet restart: existing workers and reviews continued, the
    Executor waited for the recorded reset, then confirmed 4,286 requests
    remaining and #1091 immediately resumed on its preserved workspace.
145. Dual exact-head review rejected green Ad Hoc #1162 head `eab7abde`: both
    reviewers independently reproduced accepted-but-unstarted steering IDs,
    interrupt-acknowledgement plus idle deadlock, response-only no-active-turn
    operator-message delay, late lifecycle resurrection, and duplicate
    ID-less completion retirement. Comment `4972852380` contains the single
    five-finding repair packet; #1162 is actively reworking it.
146. Dual exact-head review rejected green BO-016/#1103 head `cef18861`: a
    repository switch could publish stale detail, structural credentials and
    private keys still escaped redaction, UNC/singleton sensitive paths were
    public, oversized identifiers bypassed an early bound, and one regression
    violated the repository receive-timeout minimum. Comment `4972872096`
    contains the single six-finding repair packet; the stale `agent:ci-wait`
    label was removed and #1103 is actively reworking it.
147. BO-010/#1097 head `67c058ed` received a narrowly approved regression-guard
    override because its protected-file diff only added the new DOM/SVG
    adapter paths required by the ticket. Fresh CI then found a real owned
    browser failure: a denied/malformed layout-engine response rendered as a
    normal result instead of `engine_failed`. Comment `4972778850` routes the
    repair to #1097; an empty terminal turn required a ticket-scoped active-
    state recycle, which successfully reprovisioned the preserved workspace.
148. Ad Hoc #1151 moved new stale-CI-rewake coverage into the protected
    lifecycle regression suite and therefore failed the immutable regression
    guard. The Executor refused an override because this coverage can live in
    an ordinary comment-wake test, and comment `4972802896` directs the worker
    to restore the protected file exactly and move the additive test. This is
    contained rework, not a new issue.
149. At 12:01 PDT the run has seven live Aiur workers plus three live external
    reviewers, with the runtime ceiling still 15. Every dependency-ready core
    implementation/rework lane is staffed; review capacity is saturated on
    #1088 and #1109, while six additional core tickets remain intentionally
    held behind #1161. Deferred P2 #1171 is not valid filler. Recompute and
    dispatch the six-ticket fan-out immediately after #1161 merges.
150. Fresh dual exact-head review packets remain contained on their owning
    tickets: seven findings on workspace-safety #1161 (`4973059824`), five on
    BO-010/#1097 (`4973109191`), four on BO-016/#1103 (`4973175264`), and three
    on completed-turn recovery #1162 (`4973245148`). #1162's packet includes
    two P1 cross-turn lifecycle defects plus the 355-line TurnState
    decomposition gate; it was moved directly from human review to active
    rework without creating a follow-up.
151. Fresh CI on BO-002/#1091 head `8820e379` found three branch-owned Credo
    findings and four Dialyzer opaque/type findings; comment `4973230664`
    routed the exact packet. DASH-002/#1109 head `25e30ce0` found nine
    overlong lines, two alias-order findings, a redundant `with` clause, and
    one nesting finding; comment `4973231235` routed that packet. Both
    workers were returned to rework immediately rather than wasting capacity
    waiting for the other jobs on already-failed heads.
152. The 12:26 PDT hourly monitoring retrospective recorded one action wake
    and one isolated no-action review poll, with no repeated waste pattern.
    The next wake routed review/CI packets, recovered completed workers, and
    refreshed the preview, so the adaptive cadence remained unchanged.
153. At 12:40 PDT an exact utilization audit corrected completed/CI-wait rows
    out of the live count. Seven Aiur workers are genuinely active, #1088 and
    #1151 are correctly slot-free in CI wait, and external reviewer slots are
    free after #1162 convergence because no other exact head is green yet.
    This is the maximum useful width of the present dependency graph: six more
    core tickets remain protected behind #1161 and must be dispatched
    immediately when it merges; never keep completed or CI-wait agents alive
    merely to make the count appear larger.
154. The operator required a hard ten-minute maximum-concurrency reminder.
    The durable aiur-run contract landed on `main` as `0f8a3e13`; the current
    user timer is `aiur-executor-capacity-audit.timer`, and its latest/history
    evidence lives under `~/.aiur/executor-capacity-audit/`. The first timer
    exposed the cwd-keyed control identity and then a scheduler-saturated RPC;
    the local audit now runs from the repository root and reports control-RPC
    unavailability as unknown rather than falsely recording zero workers.
155. Claude's token-reduction sequencing was read and acknowledged in
    `AGENT-CHAT.md` (`aca28fc0`): #1171 ccusage baseline/ledger first, then a
    multi-hour measurement window, then #1169 Serena, another measurement
    window, then #1170 context-mode. #1171 used a genuine spare slot briefly
    and was paused again when core/P1 work needed capacity; #1169/#1170 remain
    undispatched.
156. Repeated P1s #1146 and #1148 were promoted from the deferred Ad Hoc
    ledger when useful concurrency was below target. When sustained host load
    reached 49/41/37 on 12 CPUs, the Executor temporarily lowered the ceiling
    from 15 to 10 (`11 active, draining`) with an explicit restore condition:
    two consecutive ten-minute audits below load 18. Memory remained healthy
    at roughly 19–20 GiB available. #1146 is now paused/preserved so actively
    recurring #1151 rework takes priority.
157. Dual exact-head review rejected green Ad Hoc #1151 head `6c5ee79f` with
    five P1 provenance/crash-window failures plus the 479-line global-storage
    architecture gate. The consolidated packet is issue comment `4973409783`;
    #1151 is queued for rework and must merge current `main` before fresh CI.
158. A read-only preflight of workspace-safety #1161's dirty WIP found six
    still-open blockers: generation-bound waiter release, fail-closed provider
    registration, descendant/tmux containment, real DOWN-first retry envelope
    and host pinning, guardian-authoritative telemetry, and destination-log
    symlink containment. Comment `4973411674` routed these before push; no new
    issue was created.
159. Current-main and fresh-CI packets remain contained: #1103 lint plus base
    gate (`4973449689`), green-but-stale #1091 (`4973454872`), #1109
    (`4973455500`), and #1154 (`4973456502`). The cap queues these transitions
    by priority rather than adding more simultaneous builds under CPU pressure.
160. The 13:33 hard capacity audit recorded load 26.96 on 12 CPUs with roughly
    21.5 GiB available and correctly skipped the saturated control RPC. Load
    fell to 17.54 at 13:40, but this is only the first below-18 observation;
    keep the ceiling at 10 until the next hard audit also satisfies the recorded
    two-consecutive-audit restore condition.
161. Both independent exact-head reviews rejected BO-002/#1091 head
    `8a94c846` despite green current-main CI. Comment `4973750725` routed five
    contained fixes: configured repository/bounds authority, logical identity
    collisions, fail-closed duplicate status propagation, total GraphQL
    response validation, and the two 200-line module violations. The event path
    woke its Terra worker for rework; no new ticket or scope was added.
162. Fresh green current-main heads are DASH-006/#1088 `b6a8adfe`,
    BO-016/#1103 `bd26e982`, build-gate #1154 `7d283949`, workspace-safety
    #1161 `f52329b4`, and DASH-002/#1109 `9938fd71`. Exact reviewers are active
    on DASH-002, #1154, and #1161; add the missing independent passes as lanes
    free, then route contained rework or merge under the normal policy.
163. The static progress preview was refreshed and published as `63b6ab28`.
    It uses the latest emitted percentages, attributes #1146/#1148/#1171 to the
    Phase 1 Ad Hoc pickup wave, and includes gated token experiments #1169 and
    #1170 without dispatching them. The Tailscale-served page was verified to
    expose the 13:37 PDT snapshot.
164. The prewarmed checkout was reverified at exact `0f8a3e13`, matching its
    fetched `origin/main`; its only dirt is the expected generated Hex cache and
    untracked build marker. Do not rebuild it merely because those generated
    artifacts exist.
165. The 13:43 and 13:53 hard capacity audits both measured load below the
    recorded restoration threshold, so the Executor restored the live ceiling
    from 10 to 15. The later 14:03 spike to load 41 was allowed to drain without
    killing useful workers; by 14:13 load was 10.89 with about 21.6 GiB
    available. Keep the ceiling at 15 and let the load/build gates regulate
    admission unless a new measured bottleneck names a different temporary
    restoration condition.
166. Dual exact-head review rejected green DASH-002/#1109 head `9938fd71` with
    five contained persistence, crash-safety, corruption-redaction, bounded-
    record, and bounded-idle-sweep failures. Comment `4973838136` returned the
    single packet to the existing ticket, and its Terra worker is actively
    repairing it; no follow-up ticket was created.
167. BO-010/#1097 exact head `216e0503` retained exactly two additive protected
    compile-time resource allowlist lines. The Executor inspected that patch,
    recorded exact-head approval in comment `4974008003`, and re-applied
    `regression-suite-change`; the worker still owns the independent lint
    failure, and any later push invalidates the approval.
168. Token baseline #1171 completed at 14:14 PDT without consuming another
    model turn. Comment `4974061960` records non-empty daily, session, per-agent,
    per-model, and cache split values for Claude and Codex. The ticket is closed;
    #1169 and #1170 remain undispatched, with the earliest Serena delta decision
    at 18:14 PDT after four hours of unchanged fleet behavior.
169. The completed-turn handoff defect recurred on red-CI #1097/#1148/#1162:
    pause-overlay recovery alone left all three counted as working after their
    turns ended. The Executor removed their active state until Aiur deactivated
    the preserved generations, then re-added `agent:rework`; all three launched
    fresh Sol/Terra turns at 14:17–14:18. This is live evidence for existing
    #1162/#1151, not authority for another ticket.
170. Workspace-safety #1161 advanced from reviewed head `f52329b4` to
    `8951a2f1`, invalidating both old exact-head reviews. Its new test job passed,
    but Dialyzer found one impossible guard in
    `codex/app_server_port.ex:137`; comment `4974085019` routed that exact
    current-head repair. The old findings are evidence only until a fresh green
    head receives two new independent reviews.
171. At 14:34 PDT both exact-head review pairs converged. DASH-006/#1088 received
    one contained four-P1 packet in comment `4974202839`; shared build-gate
    #1154 received the confirmed Mix-descendant lease defect plus five bounded
    portability/recovery corrections in comment `4974203190`. Both moved from
    human review to rework on their existing tickets; no new scope was filed.
172. Paused-label startup fix #1148 reached green exact head `a259c616` and moved
    from a stale completed worker row into dual independent review. BO-016/#1103
    remains green at `bd26e982`; its first reviewer found four contained P1
    configuration, sanitization, hot-reload, and restart-notification failures,
    while the second exact-head review is still active. Do not route or merge
    BO-016 until that pair converges.
173. #1151 head `bb52e230` ended terminal red with two missing specs, one
    provenance-recovery assertion failure, and an `exact_compare` Dialyzer
    warning that crashes the formatter. Comment `4974227556` returned the exact
    packet; the worker is now in a fresh rework turn. #1091 and #1161 were also
    explicitly recycled after completed turns failed to consume their routed
    packets.
174. At 14:41 PDT seven Aiur workers were genuinely turning (#1088, #1091,
    #1109, #1146, #1151, #1154, #1161), #1162 was in fresh CI, and three
    independent review lanes were staffed. The one-minute load reached 35 on
    12 cores with about 21 GiB still available, so no further ticket was
    admitted even though the ceiling remained 15. This is the required
    measured-machine bottleneck, not an arbitrary agent cap.
175. Paused-label startup fix #1148/PR #1173 passed fresh CI and two clean
    independent exact-head reviews, then squash-merged at 14:55 PDT as current
    `main` `6be98db8`; the prewarm mirror was verified at the same head. At
    15:02 the Executor recycled completed-turn rows #1091/#1109/#1161/#1162,
    restoring ten genuine Aiur workers without raising the configured ceiling.
    A lifecycle audit of eight merged and eleven open run PRs showed that
    reviewer dwell is not the dominant long-tail delay: audited merged review
    turnaround had a 9m39s median, versus 34m59s from a failed CI episode to the
    next attempt, while open PRs accumulated repeated pushes, failed heads, and
    semantic rework. Only two of seven representative long PRs had a completed
    worker self-review on the current head versus four of five short controls.
    The measurement contract and a single next-phase exact-head/delta-review
    experiment are recorded in `progress-calibration.md`; do not rewrite active
    workers' guidance mid-phase or create a new in-scope ticket yet.
176. The Executor diagnosed another live comment-driven wake failure without
    filing a duplicate. Existing P1 #1151 owns the end-to-end defect; #1162 is
    its lower-level completed-turn accounting companion. Trusted review
    comments `4974791267` on BO-010/#1097 and `4974846435` on DASH-002/#1109
    were accepted by GitHub and followed by `agent:rework` transitions, but
    neither comment ID reached the durable agent log and both rows remained
    `working / turn completed`. Direct Executor messages and rework-to-rework
    label recycling also failed to start a new provider turn. Older comment
    events are present in both logs, bounding this to stale completed-runner
    replacement rather than a blanket GitHub listener outage. Comment
    `4974965328` records the normalized diagnosis and binding post-merge proof
    on #1151. Until that fix lands, recover only the affected ticket by
    reaching a truly paused/deactivated runtime state before restoring its
    preserved rework state; scheduler saturation can delay the control RPC, so
    confirm daemon health and avoid restarting the healthy fleet merely for a
    transient timeout.
177. BO-002/#1091 passed fresh current-main CI and two clean independent
    exact-head reviews, then squash-merged at 16:47 PDT as current `main`
    `af941452`. The core graph is now 7/54 merged with 47 remaining. BO-003 is
    dependency-ready but cannot dispatch until the current build/load gate
    clears and its new workspace is proven to include this merge.
178. A controlled 16:31 restart replaced stale completed runners without
    losing branch or worktree state. Eight Codex worker sessions are now live
    (#1088, #1090, #1097, #1109, #1146, #1154, #1161, #1162); memory remains
    healthy, but the 12-core host is build/daemon saturated, so #1151 and #1103
    stay priority-queued despite a configured ceiling of 15. A lingering
    `aiurdev watch --full --interval 1` observer and eleven 8–22-hour-old
    `opencode serve` children rooted in deleted test directories were
    terminated without touching the daemon or ticket workers. Do not use the
    full watcher as a one-shot status command, and recheck deleted-test process
    leakage at the next capacity audit rather than filing optimization work
    during this phase.
179. Dual exact-head review returned DASH-018/#1090 to contained rework in
    comment `4975225617`: durable superseded-binding revocation, live
    rate-limit ingestion, issued-entry leases, malformed-diagnostic privacy,
    and module-size cleanup. Dual review also returned BO-016/#1103 to contained
    rework in comment `4975315545`: CLI/CDATA credential redaction, singleton
    path redaction, the shared strict repository validator, fleet-safe receive
    timeouts, public config docs, and the exact PR template. Both heads also
    require current-main refresh and fresh CI/re-review; no follow-up issues
    were created.
180. #1151 reproduced its own bug again. Operator comment `4975200402` was
    accepted at 23:53:56Z but did not enter the durable ticket log for several
    tracker intervals, while deploy/CI events did. A targeted pause-to-rework
    transition finally emitted and consumed both missing trusted comments, but
    the delayed pause addition overtook its earlier removal and left runtime
    state paused even though GitHub showed only `agent:rework`. Use a confirmed
    two-stage pause barrier for pre-fix recovery and keep #1151 first in the
    admission queue; after it merges, the binding proof is trusted comment ID
    -> durable event -> fresh provider turn -> repair activity with no label
    recycling, message injection, or Executor restart.
181. The warm prebuild checkout has not eagerly advanced from `6be98db8` to
    `af941452`, so do not report that the prebuild itself updates after every
    merge. This exact stale-base class was fixed by #567/PR #571 at the
    materialization boundary: a newly created workspace fetches the configured
    live remote tip before branching even when the warm clone is stale. Before
    admitting BO-003, verify both that materialization includes `af941452` and
    that the warm marker is rebuilt if the warm base refresh does run; reopen
    #567 only if a newly materialized workspace actually branches from the
    stale commit.
182. The operator is merging a bounded set of token-optimization changes and
    will explicitly signal when that merge window is complete. Keep the current
    daemon and durable worker fleet running until that signal; do not rebuild or
    restart speculatively. After the signal, fetch the new accepted `main`,
    refresh every stale active head, rebuild the real `aiurdev` release, restart
    from the repository root, and prove each preserved worker resumes before
    admitting newly ready work.
183. #1151 could not consume its own current-main directive because it is the
    live reproduction of the wake bug, so the Executor used the authorized
    isolated-worktree last-mile fallback. Current `main` was merged, the
    GraphQL transport overlap was resolved without losing strict response
    validation, and focused gates passed (120 tests before push; then 40
    provenance/wake tests and 87 transport/reply/client tests). The pushed head
    is `c52a50c0`. Two independent reviews still rejected merge: normal Claude
    tickets are disabled, the Claude hook fails behind dashboard auth, Codex's
    no-approval path lacks an acknowledged pre-execution barrier, unresolved
    pending writes can expire open, stale approval aliases survive completion,
    and common/silent wrappers bypass durable identity. The deduplicated rework
    contract is issue comment `4975623171`; no duplicate issue was filed.
184. Two other P1 repairs are green and clean on current main but remain behind
    the exact-head review gate: build-gate #1154 at `273a5059` has two
    independent reviews in flight, and completed-turn accounting #1162 at
    `24f0c80c` has its first independent review in flight. Do not merge either
    merely because CI is green; start #1162's second review as soon as one
    #1154 reviewer frees a lane.
185. At the 17:51 audit, accepted `main` was still `af941452`; eight Sol/Terra
    app-server sessions remained alive. The host had about 21 GiB available but
    load near 38 on 12 cores, with the daemon and several Mix gates consuming
    the usable CPU. Keep `max-agents` at 15 but do not force another worker into
    active compilation while CPU is saturated; BO-003 stays the one genuinely
    dependency-ready core ticket and should be admitted immediately after the
    restart/review pressure clears.
186. The 17:58 hard hourly retrospective recorded three action-producing wakes
    (#1151 repair/rework routing, green-P1 review staffing, and handoff/preview
    refresh) and three no-action checks. Two consecutive reviewer waits repeated
    the known `reviewers-still-running` token-burn class; one localhost preview
    probe was invalid because the static server intentionally binds only to the
    declared Tailscale address. Permit at most one 60-second reviewer wait per
    five-minute reporting boundary, never back-to-back, and probe the declared
    Tailscale preview URL rather than localhost.
187. Quota-waste reduction PR #1176 passed two independent exact-head reviews,
    fresh full CI, and squash-merged as `2522bcda`. DASH-002/#1109 then merged
    current `main`, passed three contained recovery repair rounds, 45 focused
    tests, two final exact-head reviews with no P0–P2, and fresh full CI before
    squash-merging as `d112b355` at 19:39 PDT. The core graph is now 8/54 with
    46 remaining. The live daemon remains intentionally on the pre-optimization
    release until the operator declares the bounded optimization merge window
    complete; do not restart early. At this snapshot only #1090 and #1162 are
    visibly executing provider work, #1088 reports a completed turn, #1097,
    #1146, and #1151 are paused, and #1161 is deactivated. Host CPU is fully
    occupied despite roughly 22 GiB available, so do not admit BO-003 merely to
    inflate the row count; repair useful paused/completed work after the
    authorized rebuild/restart.
188. Workspace-safety #1161 was refreshed onto `d112b355` by an isolated
    Executor merge and pushed as exact head `388fce7e`; fresh build, lint,
    Dialyzer, browser, layout, and guard checks passed before dual review found
    three contained gaps: an expected but unidentified live provider could be
    explicitly released, a streamed write exception could bypass workspace
    promotion rollback, and later signaling did not bind numeric PID/PGID reuse
    to process birth identity. The consolidated packet is issue comment
    `4976385385`. The Executor changed the ticket from CI wait to rework and
    sent the packet directly; the same Terra worker began a fresh provider turn
    at 19:53 PDT. This assisted label-plus-message recovery is not evidence that
    #1151's comment-only wake defect is fixed, and all findings remain on #1161.
189. The 19:59 preview refresh is grounded in provider logs plus GitHub because
    the daemon control RPC is timing out under scheduler saturation. #1090 is
    genuinely live and self-reported 50% while repairing its five-item review
    packet; #1161 is genuinely live with source edits underway on the three
    exact-head findings; #1088 completed its turn but its unchanged PR head is
    still red only on the known branch-owned lint findings; #1162 moved itself
    to human review after its old exact head remained green, so its worker is
    idle and the Executor still owes fresh dual exact-head adjudication. The
    static preview now distinguishes those two live green cards from completed
    or review-pending work. Do not restart the daemon until the operator closes
    the optimization merge window.
190. At the 20:05 capacity boundary CPU briefly fell to roughly 50% with 24 GiB
    available. BO-003/#1092 is the next serial critical-path member, BO-002 is
    merged, and its supervision serialization set is not active, so the
    Executor added `agent:todo`; Aiur picked it up at 20:09 without a restart.
    Dual review of #1162 exact head `24f0c80c` independently rejected it with
    four unique P1 defects: real `{:port_exit, status}` loses queued rework,
    cancel/quota pauses fail to retire old provider IDs, generic JSON-RPC
    `-32600` is over-classified as no-active-turn, and closed-port dynamic-tool
    recovery can replay a side effect. The same head also conflicts with
    accepted `main` `d112b355`. The consolidated packet is issue comment
    `4976480407`; the Executor moved the ticket back to rework and sent it
    directly, and the existing Sol worker resumed at 20:09. Four useful Codex
    workers are now live: #1090, #1092, #1161, and #1162. The hourly monitoring
    retrospective also tightened saturation handling: after one control-RPC
    timeout, use provider logs plus GitHub for the rest of that five-minute
    window instead of burning another RPC.
191. Workspace-safety #1161 pushed current-main head `c519401b`. Build,
    Dialyzer, browser, layout, and guards passed; CI lint found one long line
    plus four bounded complexity/nesting findings in the repaired
    `RemoteControl` and workspace guardian paths. The durable packet is issue
    comment `4976510041`; a corrected direct message woke the same worker at
    20:14 and it is mechanically repairing only those five findings. A direct
    message and pause-preserving label cycle on DASH-006/#1088 did not create a
    new provider turn even though both operations succeeded and the workspace
    has no source WIP. That is additional production evidence for the existing
    #1151 wake defect, not a new ticket; keep #1088's exact lint tail preserved
    for the authorized restart.
192. BO-003/#1092's initial Terra provider ended unretryably at 20:18 with
    `Selected model is at capacity`; its plan/workpad and workspace were
    preserved. The Executor changed the issue's model label to Sol, transitioned
    the completed generation from in-progress to rework, and sent one explicit
    continuation. Aiur began a new turn at 20:19. The old daemon instantiated
    that immediate replacement with its prior Terra routing snapshot, which is
    still operator-compliant but may encounter the same capacity gate; retain
    the Sol label for the next clean generation and do not discard BO-003 WIP.
193. BO-003's inherited Terra replacement also hit capacity. A full completed-
    generation deallocation exposed `agent:error`; the Executor removed that
    terminal marker, restored the ticket through `agent:todo`, and Aiur started
    a verified Sol app-server at 20:24 with the plan/workpad intact. DASH-006
    was then cleanly recycled because its completed generation would not wake;
    the old daemon removed and began reprovisioning its workspace, which had no
    source WIP but had not restored a valid git checkout after twenty seconds.
    The Executor immediately applied `agent:paused` while preserving
    `agent:rework`. Do not resume #1088 until #1161 lands and the authorized
    restart runs the repaired workspace lifecycle. #1161's lint repair head
    `b5c14d71` has every fresh CI gate green except the still-running full test.
194. #1161 head `b5c14d71` finished CI with every functional/static gate green;
    the sole failure was total coverage 84.95% against 85.00%. This directly
    blocks the workspace fix, so the Executor kept it contained in #1161 and
    routed issue comment `4976581861` for narrow deterministic coverage of the
    newly extracted identity/guardian branches. The worker resumed at 20:30.
195. BO-003's first verified Sol startup raced the old daemon's workspace
    replacement and terminated with `invalid cwd: No such file or directory`.
    The guarded hook rebuilt a valid checkout, but cleanup removed that checkout
    again before the resumed worker could start; the uncommitted plan file was
    lost while the durable workpad/provider transcript remained. After one
    attempted valid-checkout resume exposed the second removal, the Executor
    stopped cycling the ticket and applied `agent:paused` while preserving
    `agent:rework` and the Sol label. This is direct #1161 evidence. Do not
    resume BO-003 or DASH-006 again until #1161 is merged and the authorized
    daemon restart applies the fix.
196. #1161's targeted-coverage worktree accidentally launched the identical
    full coverage command twice, 69 seconds apart, and both commands reported
    acquiring build-gate slot 2. The Executor terminated only the younger
    duplicate process group, told the worker to retain the older authoritative
    run, and did not promote this optimization evidence into feature scope.
    The authoritative suite finished at 84.93%, still 0.07 points below the
    floor, so #1161 remains live on a narrow coverage tail. Freed CPU made a
    safe same-workspace continuation possible for BO-010/#1097 and
    BO-016/#1103 without restart or reprovisioning. Direct decisions told
    BO-010 to validate and push its current-main merge and BO-016 to preserve
    both sides of its existing `catalog_test.exs` conflict. Both workers woke;
    BO-010's latest check-in is 90%, BO-016 restarted its rework estimate at
    20%, and five useful Codex workers are now visibly executing. The daemon
    restart remains held until the operator closes the optimization merge
    window.

197. At 21:18 PDT the operator required explicit finish-line compression for
    long-running tickets. The Executor applied four binding tactics rather
    than adding code or scope: (a) when the scoped repair is committed and the
    only dirt is generated workspace output, run the one reproducing test and
    push immediately—central CI owns the full suite; (b) when a current-main
    merge has no unresolved paths, finish only the focused conflict suite,
    commit the coherent merge/repair head, and push without another local full
    gate; (c) extract terminal lint/Dialyzer/browser failures into one exact
    packet and return it immediately instead of waiting on unrelated jobs for
    an already-invalid head; and (d) batch all converged review findings into
    one repair head, then run dual exact-head review in parallel only after
    fresh CI. Never overlap duplicate full-suite commands in one workspace;
    keep the older authoritative process and stop only the younger duplicate.
    Apply the stale-base ancestry check once at the final review/merge boundary
    rather than repeatedly rebasing a branch during implementation. The
    Executor sent this finish-line contract to BO-010/#1097 (committed browser
    repair `38066c09`), BO-016/#1103 (resolved merge plus focused catalog/config
    gate), and the two direct blockers #1161/#1162 (focused reproduction and
    one coherent repair head). These tactics shorten validation/review tails;
    they do not weaken acceptance, protected tests, full centralized CI, or
    dual review.

198. Claude is independently researching the late-wave consolidation through
    `docs/build-order/AGENT-CHAT.md`. The Executor must check and message that
    channel at least every 15 minutes while the joint run-through work is
    active. This host uses the local user
    timer `aiur-agent-chat-poll.timer`: it fetches only
    `build-order-research`, hashes the chat file, and writes a pending snapshot
    under the private Executor state directory when content changes. At the
    next ordinary Executor wake, read and respond to the pending Claude append;
    do not wake a model merely because an unchanged 15-minute interval elapsed.
    Continue active ticket orchestration between checks, and keep the earlier
    rule that Claude's proposal cannot mutate issues, dispatch labels, or the
    canonical graph before review/approval.

199. At 21:37 PDT BO-010/#1097 completed two independent reviews at exact head
    `38066c09`: the adversarial/reliability review passed, while the
    correctness review reproduced one contained P2 contract failure. Valid
    semantic phases `>= 100` are accepted by the Build Order domain but are
    rejected by the adapter's worker-index bound, forcing
    `measurement_invalid` fallback. The Executor returned one packet on the
    owning issue: dense-rank semantic phase/lane values for worker input while
    retaining original DOM/display truth, with phase-100 and sparse-large-phase
    coverage. The GitHub issue comment did not appear in the completed
    worker's log or start a new turn within two minutes despite the ticket
    already carrying `agent:rework`; an explicit `aiurdev message 1097` was
    required. Preserve this timestamped reproduction as evidence for the
    existing comment-wake/self-comment work in #1151 rather than filing a new
    Build Order ticket. The hourly monitoring retrospective was also recorded:
    the measured wake produced concrete review, CI, capacity, and routing
    action, so event-driven/ten-minute/30-minute cadences remain unchanged.

200. At 21:50 PDT the Executor's bounded attempt to recover BO-010 from the
    completed-turn/message-delivery wedge reproduced #1161. Two provider
    recycles delivered stale queued status events but not the durable review
    packet; a clean `rework -> todo` ticket recycle then deleted the canonical
    #1097 workspace while Aiur still reported the worker active. The remote
    branch/head `38066c09` was clean before the recycle, so no source work was
    lost. The Executor immediately stopped further cycling, cleared the
    resulting terminal error, and preserved `agent:rework + agent:paused`.
    Do not resume BO-010 until #1161 lands and the operator-authorized daemon
    restart applies it; the phase-100 repair packet remains durable on #1097.
    In the same snapshot BO-016 head `03a51d24` is fully green and in dual
    exact-head review, DASH-018 head `87e56177` is invalid only for one Credo
    single-clause-`with` finding already returned to #1090, #1161's two reviews
    converged on the same no-provider and identity-to-signal repairs, and #1162
    remains in final diff audit before its repair push.

201. At 22:03 PDT the operator accepted Claude's fast-win recommendation and
    made anti-thrash convergence the top run priority. Freeze every
    not-yet-started Build Order ticket and wave until the existing in-flight
    heads and finite churn-fix set are merged and proven: #1039, #1046, #1009,
    #1012, #1036, #1153, #1161, and #1162, plus already-active Build Order
    heads and the immediate stale-base/lint candidates. #1082 was closed as a
    wrong-base sandbox stub. PRs #1055, #1057, and #1046 were `CLEAN` in the
    GitHub mergeability sense but did not contain current `main`; the Executor
    merged `d112b355` without conflicts in isolated worktrees and pushed fresh
    heads `809841fd`, `017be438`, and `2c1a283c` for new CI. #1046 remains draft
    pending dual review and its required real multi-ticket proof. #1144 is in
    an isolated current-main worktree for its eight bounded Credo findings.
    After the finite set lands, rebuild/restart Aiur and prove comment wake,
    rework continuation, workspace preservation, CI handoff, and PR-to-merge
    ownership before resuming new Build Order scope. The late-wave five-lane
    ownership overlay is accepted as the next-stage direction but cannot be
    materialized or dispatched before this anti-thrash gate passes.

202. At 22:10 PDT the operator made branch freshness an owning-worker
    responsibility and prohibited spending Executor or reviewer effort on
    substantially stale code. A ticket's agent must keep its branch current,
    including adapting or re-cutting its implementation when main has changed
    semantically. The Executor routes that work back to the owning ticket and
    does not merge main, repair stale conflicts, or modernize old code on the
    worker's behalf. Exact-head review begins only after the worker presents a
    head containing current main with fresh CI. The manual refreshes recorded
    in decision 201 predate this directive and are not precedent.

203. At 22:26 PDT the anti-thrash audit promoted two existing defects from
    deferred/hygiene status because live evidence made them direct recovery
    blockers. #1140 now owns the tracked `.aiur-hex/cache.ets` bootstrap loop:
    #781 and #855 each resumed, immediately failed `before_run` on the mutated
    tracked cache, and re-paused; both remain `agent:rework + agent:paused`
    until #1140 lands and the daemon is rebuilt. Claude's #1091 forensic pass
    also found the shared build gate held by the impossible host identity
    `pid=2/pgid=1` and showed that the `kill -0 -- -1` broadcast check prevents
    lease reclamation; preserve and verify the slot evidence, clear only the
    proven stale lease, and reopen existing #1164 rather than filing a
    duplicate. Finally, re-scope #1151 away from its large stale self-comment
    branch: measured partial-CI early failure is the dominant CI-wait eviction
    cause, so its owning agent must re-cut current main and make the poller wait
    for every check to become terminal before emitting one aggregate failure;
    cancelled/stale workflow conclusions are not code failures. Do not review
    the old #1151 head.

204. At 22:46 PDT Claude's recovery PR #1179 was explicitly not
    review-ready. Its head `ce6f83aa` did not contain current `main`, and the
    required test job failed on the exact CI-handoff wording contract changed
    by decision 202's skill update. The Executor repaired that self-introduced
    `main` regression in `b9c8e140` and proved the focused
    `aiur_agent_skill_test.exs` suite 17/17 green. PR #1179's owning Claude
    agent must integrate current main, run focused verification, and present a
    fresh green exact head before class-complete review; do not review or merge
    `ce6f83aa`. The same stale wording caused the first failure on #1161's
    otherwise improved head; #1161 received the current-main sync packet, and
    its second failure was an unrelated 100 ms checkpoint timing flake rather
    than owned workspace-lifecycle behavior.

205. The re-scoped #1151 failure reproduced live on DASH-018/#1090. PR #1141
    reached terminal failed CI at 05:23Z, but Aiur delivered no terminal
    packet and scheduled continuation turns 4 through 7. Every turn performed
    no work and reported a variant of "still awaiting CI"; the worker also
    emitted 90% progress claiming the already-terminal run was pending. At
    22:42 PDT the Executor injected the actual failure and current-main repair
    packet with `aiurdev message`. Preserve this as the negative proof for
    #1151: incomplete runs stay pending, but one complete terminal result must
    arrive promptly and must suppress no-op continuation dispatches. The raw
    progress dataset now retains 1,130 normalized samples including this
    inaccurate 90% interval.

206. At 00:27 PDT anti-thrash PR #1179 reached exact current-main head
    `5ce42f3ea91e59768e0a58e2660abe8e7c31863b` after the Executor closed the
    full class-complete review set. Redispatch admission now
    returns and retains a newly tripped lifetime-budget state through completed
    runner replacement, a failed Remote Control replacement removes its
    torn-down running-map entry before scheduling retry so it cannot consume
    its own slot, and crash retry continuation is derived from actual runner
    provenance rather than the global enable flag so a fresh zero-turn startup
    failure remains a cold start. Completed Hook turns now carry explicit
    provenance; an all-models-limited active retry retains a non-exhausting
    bounded wait instead of losing its only retry; lifetime spend persists in
    stable instance/repository state across run-log and BEAM restarts; and
    missing, corrupt, or unreadable durable state fails closed. Three
    independent exact-head reviews are merge-ready with no P1 findings and the
    focused/lint gates are clean; fresh CI is the sole remaining merge gate.

207. At 23:54 PDT the Executor found `/tmp` at 100% while the main filesystem
    still had roughly 3.2 TiB free. The saturation was accumulated temporary
    review/build worktrees, not live ticket workspaces. The Executor preserved
    every active or dirty tree, removed 40 clean stale review/land worktrees,
    and recovered about 2.5 GB (`/tmp` 100% -> 85%). Treat recurrence as an
    Executor-capacity signal because it can break reviews, builds, and agent
    subprocesses; clean only positively identified stale/clean temporary
    artifacts and record repeated evidence before promoting a new reliability
    issue.

208. The 00:26 hard hourly monitoring retrospective found that material
    recovery work dominated, but repeated short reviewer waits and CI-only
    checks returned no new decision. Retain immediate event-driven wakes for
    worker, alert, capacity, chat, and user changes; when review or CI is the
    sole remaining gate, never run consecutive checks and wait at least 120
    seconds unless a real event arrives. This is a small evidence-based cadence
    adjustment, not a reduction in Executor duties.

209. #1140 pushed current-main head `09fe03bf` after the Executor rejected its
    first merge-only cache repair for deleting the rewritten warm caches. The
    new hook backs up both package-manager cache trees outside the worktree,
    resets only the legacy tracked paths, merges the base deletion, and restores
    ignored warm contents on success and conflict; fresh CI is running. #1032
    pushed current-main head `03b291a1` with functional CI green after reverting
    its prohibited protected-regression test edit. Both remain behind #1179:
    once #1179 merges, their owning agents must update to the new `main` and
    obtain fresh CI before review.

210. The first full CI run for #1179 head `5ce42f3e` found one owned defect and
    one independently reproducing test-suite flake. The owned failure was a
    `WithClauseError`: `admit_redispatch/4` did not normalize the valid
    `{:all_limited, candidates}` backend-selection result into its documented
    state-carrying error tuple. Exact head `c180be93` adds the one missing arm,
    preserving the completed runner and claim while all models are limited;
    focused validation is 31/31 green and exact-head delta review is
    merge-ready. The tracked-set restart assertion passes alone at the CI seed
    and remains under independent flake diagnosis. Fresh full CI and a second
    exact-head delta review remain the only #1179 merge gates.

211. #1179 cleared fresh full CI plus two independent exact-head delta reviews
    and squash-merged to `main` as `200a82d3` at 00:48 PDT. The warm base
    independently refreshed to that exact commit. The unrelated tracked-set
    restart flake reproduced on both the PR and prior `main`; it is the
    incompletely fixed existing #780, so the Executor reopened #780 as a P1 Ad
    Hoc recovery item instead of multiplying tickets. Its old `aiur/780`
    branch had already merged through PR #785 but could not merge modern main;
    after verifying that history, the Executor deleted the stale remote branch,
    archived the old workspace intact, resumed the paused worker, and proved a
    fresh current-main branch `aiur/780-fix-remaining-concurrent-flaky` is now
    active.

212. #1180's completed pre-#1179 worker session accepted an operator message
    but did not consume it, which is the recycle gap the still-unloaded #1179
    binary fixes. Rather than restart twice, the Executor performed only the
    bounded ownership fallback: merged exact `200a82d3` into the otherwise
    clean branch, ran all 12 focused hook regressions green, and pushed fresh
    head `281f138e` to centralized CI. After #1180 passes exact-head review and
    merges, rebuild/restart once with both recovery fixes, enable the opt-in
    continuation and lifetime budget settings, and prove live recovery before
    lifting the feature-scope freeze. A comment-only wake probe on #1032 became
    observable only after the Executor also injected a manual message, so it
    is inconclusive and must not be recorded as positive or negative proof.

213. The `aiurdev agents` control helper can print a complete roster and the
    internal success marker, then fail to exit before the outer ten-second
    timeout; the launcher kills that helper and falsely warns that the daemon
    may be scheduler-saturated. A direct CPU sample showed the daemon mostly
    idle after the transient spike. Record the repeated false timeout as
    deferred DF-012; use logs/process evidence between state changes and do
    not restart a healthy daemon from this warning alone.

214. Reopened #780 reproduced the tracked-set restart race at the exact CI
    seed, then fixed it without sleeps or retries by starting only the shared
    test-suite Orchestrator with `initial_poll?: false`; production and named
    Orchestrators retain the immediate-poll default. Exact head `3ac3f191`
    passed the coverage-instrumented reproduction 20/20 plus 37 focused tests
    and opened draft PR #1181 on current `main`. When the worker moved the
    issue to `agent:ci-wait`, the old daemon instead exposed `agent:error` even
    though the turn completed cleanly and CI started. Preserve this as
    deferred recovery evidence: the checked-in `using-aiur` skill requires
    `agent:ci-wait`, but this dogfood workflow's `active_states` omits
    `ci-wait`. Manually shepherd #1181; do not expand the recovery gate to fix
    that lifecycle mismatch tonight.

215. #1180 exact head `281f138e` remains functionally clean, but two
    consecutive full-suite test jobs failed in different unrelated lifecycle
    tests: the first was the known 100 ms DecisionAttention startup race; the
    failed-job rerun then returned `{:error, :dispatch_failed}` from the
    queued-idle `OrchestratorLifecycleTest`. That branch touches only cache
    hook behavior. The latter focused test passed 13 consecutive exact-head
    runs before ExUnit's repeat harness itself hit a separate named-process
    cleanup race. A third failed-job-only CI rerun is in flight; do not request
    speculative product edits for changing unrelated flakes.

216. Dual review of #1046 disagreed on whether final-unblock acknowledgement
    must wait for durable queue settlement. A focused third adjudicator traced
    exact head `1c6161a3` and rejected the blocker at 92% confidence: the
    branch's contract is successful live-worker resume for consumers relevant
    when readiness arrives; durable generic queue settlement is explicitly
    out of scope, the cursor/queue restart gap predates the PR, and late
    subscribers intentionally exclude historical events. The Executor
    restored #1046 to ready-for-review with no rework. Record generic
    SubscriptionStore cursor/AgentQueue restart durability as deferred DF-013;
    it cannot delay this bounded coordination recovery fix.

217. #1161's current-main recovery head `f324fc18` is green on every CI gate
    except Credo's 31-field struct limit. The owning worker received the exact
    packet and is extracting the cohesive dispatch/recovery fields into nested
    state rather than disabling or raising the rule; its worktree has active
    scoped edits. Keep repair ownership with that worker and review only its
    next pushed current-main green head.

218. The 01:27 hourly retrospective counted seven prior-hour monitoring wakes:
    four produced concrete recovery action and three produced none, including
    two repeated reviewer waits. The last 60-second CI watch also changed no
    decision. Raise the CI/review-only polling floor from 120 to 180 seconds
    unless a worker, alert, completed check, user message, or agent-chat event
    arrives; preserve immediate event-driven action and the ten-minute capacity
    audit. This supersedes only decision 208's 120-second floor.

219. #1180 exact head `281f138e` cleared fresh CI after two changing unrelated
    suite flakes plus two independent exact-head reviews with no blocking
    findings, then squash-merged to `main` as `03153ebf` at 01:34 PDT. The
    Executor stopped the old daemon only after #1161 had pushed and completed
    its active turn, fast-forwarded the root checkout, enabled
    `prior_work_continuation: true` and `max_dispatches_per_ticket: 10` in the
    dogfood config, rebuilt the release, and restarted once with the dashboard
    retained on the configured Tailscale host and the 16-agent ceiling. The
    dashboard returned the expected authenticated response, the warm base
    refreshed to exact `03153ebf`, and the roster survived the restart.

220. Live post-restart proof is positive but the recovery freeze remains. The
    rebuilt daemon automatically relaunched #780 and #1161 from their preserved
    workspaces, then resumed already-started #1162 as capacity ramped. #780
    consumed the Executor's new issue comment through the GitHub event path
    within one second and began integrating current main with its workpad and
    branch intact; no manual message or label cycle was needed. #1032 is queued
    in rework for its owner to refresh next. This proves startup continuation,
    workspace preservation, Codex-only routing, and live issue-comment delivery
    for active workers; it does not yet prove a completed idle worker wakes from
    a new comment.

221. #1181's first green CI and correctness review were valid at `3ac3f191`,
    but #1180 advanced main before its adversarial review finished. The
    Executor interrupted the stale review immediately to avoid token waste,
    returned #780 to its owning worker with exact `03153ebf`, and requires a
    fresh current-main head, CI, and dual review. Apply the same rule to #1161,
    #1046, and every other recovery head: do not analyze an obsolete CI failure
    or review code that no longer contains main.

222. Supersede decision 214's initial `agent:ci-wait` mismatch inference. On
    the rebuilt #1179 runtime, both #780 and #1032 completed cleanly into
    `agent:ci-wait`, remained out of the active worker set as intended, and
    retained their centralized CI state without becoming `agent:error`.
    Omitting `ci-wait` from tracker `active_states` is intentional because it
    parks the worker while CI owns the gate. The old #780 error transition was
    therefore old-runtime completion/recovery evidence, not proof of a workflow
    configuration defect; remove that mismatch from the deferred ledger.

223. #1181 exact current-main head `b2798b68` cleared every fresh CI gate and
    two independent exact-head reviews with no blocking findings, then
    squash-merged as `920fca88` at 02:00 PDT. The warm base and Executor root
    independently refreshed to that exact commit without a daemon restart;
    this change is test-infrastructure-only. #780 is closed and labeled done.
    Because main moved, the Executor immediately stopped treating #1032,
    #1161, and #1162's prior heads or CI as actionable and returned the small
    current-main integration to their owning workers.

224. #1032 owner-integrated `920fca88`, ran 261 focused event/push-routing
    tests plus strict lint green, and pushed fresh head `70b6bc08`; centralized
    CI is running. Its prior-main CI had failed only on an InstanceIdentity
    timeout and global auth-log capture contamination; neither stale failure is
    being diagnosed or patched. #1161 and #1162 consumed the same main-advance
    comments automatically and remain active on bounded focused validation.

225. #1161's self-review began editing protected
    `src/test/aiur/regression/workspace_lifecycle_test.exs`, violating the
    run's immutable-regression contract. The Executor caught it before commit
    or push, posted a durable hard gate, and injected an immediate operator
    message: revert the entire regression-directory delta, retain valid source
    repairs, move any new proof to ordinary ticket-owned tests, and prove
    `git diff --quiet origin/main -- src/test/aiur/regression` before push.
    Do not review or merge any #1161 head that fails that check.

226. #1162 owner-integrated `920fca88`, narrowed validation to the owned
    provider/turn-lifecycle surface, and pushed exact head `80045e84`. Every
    centralized CI check is green. Hold exact-head review until the older
    #1032 recovery lane either merges or returns to rework, because reviewing
    #1162 immediately before an imminent main advance would spend reviewer
    tokens on a head the owning worker must refresh.

227. Dual exact-head review of #1046 at `70b6bc08` produced one
    correctness-ready verdict and one valid contained P1 HOLD. Agent tool
    events are flattened by `ToolExecutor` and `Publisher`, but
    `EventTopics.provisional_unblock?/1` checks `temporary_stub` only under a
    nested payload. A real top-level provisional unblock could therefore pass
    ref/SHA corroboration and resume consumers onto stub code. The Executor
    returned exactly that predicate plus flattened-production-shape regression
    to #1032 through an issue comment and `agent:rework`; use this completed
    idle-worker transition as the next automatic comment-wake proof and do not
    bypass it with a manual message unless the live event path fails.

228. #1161's focused workspace/session suites passed 136/136 and its protected
    regression delta remains clean, but the worker then reran the same Credo
    line-length failure three times without changing code. The Executor stopped
    the loop with one precise durable/direct packet: fix only
    `workspace/provisioner.ex:152`, run format/lint once, retain the clean
    regression boundary, commit, and push without another broad suite. Record
    this repeated unchanged diagnostic as concrete thrash evidence for the
    later executor/agent optimization analysis; it does not justify a new
    recovery ticket during the frozen gate.

229. The 02:27 hourly retrospective found three recorded wakes and three
    concrete actions with no repeated no-action polling. Keep the event-driven
    wake policy, 180-second CI/review-only floor, and ten-minute capacity audit
    unchanged for the next hour.

230. Supersede decision 227's optimistic automatic-wake proof. The trusted
    #1032 issue comment emitted at 02:29:32 and was consumed one second later,
    but the label-driven completed-idle turn started without that event body,
    inspected only PR review threads, and restored `agent:human-review`
    unchanged. The consumed comment was injected only at 02:34:10 after a
    direct-message fallback forced a later turn; a stale prior turn then won a
    label race and deactivated that delivery before work began. After the prior
    turn fully ended, the Executor reasserted `agent:rework` and sent one final
    bounded message; #1032 is now acting on the contained finding. Event
    publication/consumption is healthy, but comment consumption is not atomic
    with the wake turn or lifecycle transition.

231. This failure matches existing issue #619's acceptance contract—consumed
    comments must wake an idle agent into a turn that reads and acts on them—so
    the Executor reopened #619 instead of filing a duplicate. It now carries
    the exact 02:29–02:34 evidence, priority 1, Terra routing, and
    `agent:paused`. Keep it paused until #1162 lands because both fixes may
    touch completed-worker/turn delivery; then dispatch it as recovery work
    before reopening the Build Order product graph.

232. #1032 completed the contained top-level/nested provisional-unblock repair,
    kept the protected regression directory clean, passed 80 narrowly owned
    tests plus strict lint, and pushed fresh head `351a796e`. Full centralized
    CI is running. The earlier 227 review verdicts are stale; after fresh green
    CI, run two new exact-head delta reviews before merging #1046.

233. #1161 pushed exact-current-main head `58e5f51f` with its protected
    regression delta clean, but its centralized test job failed while #1032 is
    about to move main. Preserve the branch and workspace under
    `agent:paused`; do not diagnose the soon-stale failure. After #1046 merges,
    return the new main SHA and failing-check evidence to the owning worker in
    one packet, require owner-led integration and fresh CI, then review only
    the replacement exact head. #1162 is likewise parked in human review at
    green head `80045e84` until #1046 moves main; it must be owner-refreshed
    before any review tokens are spent.

234. #1046 head `351a796e` passed fresh full project CI and two new independent
    exact-head reviews at 98% confidence, then squash-merged as current main
    `83a5a11e`. The root checkout and warm base are exact. #1032 is closed with
    `agent:done`. The Executor returned one exact-main refresh packet each to
    #1161 and #1162; their owners, not reviewers, are integrating the new main
    before fresh CI.

235. #1161 remained a completed-worker row after its comment, rework label,
    and direct message, reproducing the lifecycle wedge owned by active #1162.
    A single controlled rebuild/restart activated #1046's production runtime,
    preserved both workspaces, and relaunched #1161/#1162 successfully. #1146
    also relaunched because its earlier operator pause was process-local rather
    than a durable `agent:paused` label. It is an already-active priority-1
    base-branch recovery fix, so let it converge inside the frozen recovery
    set; use the label override for any hold that must survive a restart.

236. #1161 owner-integrated `83a5a11e`, passed 171 focused
    workspace/provider/session tests plus compile/format/strict lint, retained
    a zero-diff protected regression tree, and pushed coherent head `28154c5a`.
    Fresh centralized CI is running. #1162 has integrated the same main locally
    and is completing its owned provider/turn validation before one push.

237. A low-frequency `aiurdev watch --changes --interval 60` call timed out
    while the three recovery owners saturated CPU. The main daemon and workers
    remained healthy, but the supposedly terminated hidden RPC BEAM survived
    and consumed about 69% CPU until manually reaped. Existing priority-1 issue
    #1031 owns synchronous control-RPC timeouts; its evidence now also requires
    descendant/process-group cleanup. Do not dispatch #1031 while the current
    validation jobs are using all CPU, and do not restart a healthy daemon for
    this known control-helper failure.

238. The 03:28 hourly retrospective found two recorded wakes and two material
    actions with no no-action repeats. The one avoidable burn was the
    continuous control-RPC watcher under CPU saturation: it added load, timed
    out, and left a helper to reap. Stop continuous control-RPC watches under
    saturation; use local Git-head/log monitors plus GitHub/agent events, while
    retaining the 180-second CI/review floor and ten-minute capacity audit.

239. #1161 exact head `28154c5a` passed full CI, but its two fresh reviews
    split MERGE_READY/HOLD. The HOLD is a valid P1: when the recorded
    process-group leader identity becomes `:gone` while group liveness remains
    true because descendants survive, the group clause resolves `:unknown` and
    schedules retries forever; root/descendant fallback is unreachable while
    `process_group_id` exists. The Executor returned one contained packet:
    converge through identity-safe descendant evidence without signaling a
    reused group, add an ordinary ownership test, and retain the immutable
    regression tree. The trusted comment, rework label, and direct message did
    not wake the completed worker, reproducing #619/#1162 again. Do not restart
    mid-validation; wait for #1146/#1162 to reach a durable checkpoint, then
    recycle once if #1161 remains wedged.

240. #1161 finally began the queued rework about eleven minutes after the
    direct fallback, without a daemon restart. It added the contained
    identity-safe descendant path and ordinary ownership regression, passed
    the 21-test ownership suite plus format/strict lint, retained exact-main
    ancestry and the protected-test boundary, and pushed `bb2fbef4`. Fresh CI
    is running; all earlier reviews are stale.

241. #1146 completed its current-main base-branch cleanup and pushed
    `ce19c298`; fresh CI is running. #1162 published current-main head
    `bfad0336` after 199 focused tests plus compile/format/spec checks, but its
    fresh centralized test job failed while every other gate passed. The
    runtime automatically restored `agent:rework` and woke its owner; let that
    worker diagnose the delivered failure rather than spending Executor or
    reviewer tokens on the red head.

242. The #1146/#1162 validation turns both lost time to sandbox-local stale
    build-gate ownership. Closed duplicate #1164 already points to open P1
    #1154/PR #1172, so the Executor added the new recurrence evidence there
    instead of filing another ticket. #1154 remains in the finite recovery set,
    but do not wake its stale branch until the current validation load releases
    CPU; its owner must refresh onto exact main before any review.

243. #1161 exact head `bb2fbef4` passed full CI and correctness review, but
    adversarial review found a second valid P1: the new fallback can release
    solely from a one-time recorded PID snapshot while an unrecorded late
    child still keeps the original process group alive, and the
    `:gone/:reused` branch can release while a recorded descendant that escaped
    the group survives. The Executor returned one contained packet requiring
    fail-closed ownership until group disappearance is authoritative (or safe
    current-member discovery), plus ordinary late-child and reused-group
    regressions. #1161 is rework; no result from `bb2fbef4` carries forward.

244. #1162 exact head `bfad0336` passed build, lint, Dialyzer, browser, release,
    and guards, but full coverage failed its changed operator-interrupt
    lifecycle test: the barrier-controlled queued task completed within 100 ms
    instead of staying pending. This is branch-owned ordering/accounting
    behavior, not a blind-retry flake. The Executor routed the exact failure to
    the owner through both the durable issue comment and direct agent message;
    do not review until a coherent replacement head passes centralized CI.

245. #1146 exact head `ce19c298` passed full CI, but both fresh reviews held it.
    Retarget invalidation must be durably journaled before the external GitHub
    PATCH, must invalidate the confirmed response head when a concurrent push
    races the repair, and the recovery pull skill must merge
    `origin/$AIUR_BASE_BRANCH` rather than hard-coded `origin/main`. These are
    one bounded configured-base acceptance packet on #1146. The owning worker
    is active; no result from `ce19c298` carries forward.

246. The 04:29 hourly retrospective found one recorded actionable remote-head
    wake and no recorded no-action wakes. The event-silent head monitor itself
    avoided unchanged output and correctly surfaced #1161's new push, but the
    structured history undercounted material review/CI wakes because the
    Executor had not called `observe` consistently. Keep the current silent
    watcher and 180-second CI/review floor; record every material head, CI,
    review, or intervention wake so the next hourly sample measures the true
    action/no-action ratio.

247. #1161 owner-pushed exact current-main head `85b6e630` with the bounded
    fail-closed descendant repair. Full centralized CI is green, the protected
    regression tree remains unchanged, and two fresh exact-head correctness
    and adversarial reviews are running in parallel. No earlier review verdict
    carries forward.

248. #1161 correctness review returned MERGE_READY, but adversarial review held
    exact head `85b6e630` on one remaining P1: local providers without a
    process-group boundary still release from a static descendant snapshot,
    and repeated tracking can replace rather than union previously observed
    descendants. A late or reparented unrecorded child can therefore survive
    abrupt cleanup while ownership releases. The owner received one bounded
    packet to make no-group cleanup authoritative or fail-closed, preserve the
    descendant union, and add both ordinary regressions. No manual patch and no
    new ticket; no result from `85b6e630` carries forward.

249. The scheduled 05:00 preview snapshot is published at
    `http://100.81.109.51:4180/docs/build-order/plan-preview.html` and committed
    on the planning branch. It reconciles durable GitHub state, newly merged
    Ad Hoc #780/#1140, deferred #1178, and the latest emitted recovery
    check-ins. #1162's effective resource queue released at the boundary, so a
    05:02 correction marks it live at its emitted 90%; #1146 and #1161 remain
    live at emitted 80%. All three recovery owners are now genuinely turning
    at zero CPU idle; do not add a fourth worker until capacity releases.

250. #1161 owner-pushed exact current-main replacement head `0fbd6264`. The
    scheduled 05:30 preview marks its emitted 80% as fresh CI rather than live
    work. Every centralized gate then passed, the protected regression tree is
    unchanged, and two fresh exact-head reviews are running in parallel; no
    verdict from an earlier head carries forward.

251. #1161 correctness review returned MERGE_READY, but adversarial review held
    `0fbd6264` on the explicit-release side of the same no-group contract:
    failed/unknown Claude REPL readiness cleanup can call release while the
    owner is alive, bypassing the owner-dead fail-closed path and admitting
    reprovisioning beneath an unrecorded late child. The owner received one
    bounded existing-ticket packet and a successful direct wake after the
    first saturated RPC attempt failed. No result from `0fbd6264` carries
    forward.

252. #1162 owner-pushed exact current-main head `95b5c1c7` for the routed
    provider-lifecycle CI failure. Build, lint, Dialyzer, browser, release, and
    guards are green; the full test job is still running. Wait for terminal CI
    before starting its two exact-head reviews.

253. #1162 `95b5c1c7` repeated the identical centralized failure: its changed
    provider-lifecycle test still lets the queued task complete within 100 ms.
    The entire replacement delta only moved marker/release files into a
    per-test directory; production code did not change, so barrier-path
    reshaping did not repair the cause. The Executor returned that unchanged
    diagnostic, prohibited weakening the assertion, and started one
    independent read-only root-cause diagnosis in parallel with owner rework.

254. #1146's stale completed turn returned old head `ce19c298` to CI wait and
    claimed a push despite a clean workspace, unchanged local/remote SHA, and
    no new CI. It did not consume the durable dual-review packet. The Executor
    restored `agent:rework`; two direct-message attempts failed while the
    control plane was saturated, reproducing #619/#1162 rather than creating a
    new issue. Leave the packet durable and let effective capacity wake its
    owner; old green CI remains invalid.

At 04:03 PDT the core graph remains 8/54 accepted while the recovery gate is
frozen. #780/#1181 and #1032/#1046 are merged. Current main and the warm base
are exact `83a5a11e`; the rebuilt daemon is running the new coordination
runtime with the authenticated Tailscale dashboard and 16-agent ceiling.
#1161 `bb2fbef4` is back in owner-led rework after a valid adversarial P1;
#1146 `ce19c298` has green centralized CI and is in two fresh exact-head
reviews; #1162 `bfad0336` is owner-led rework on one exact CI failure. Reopened
#619 remains paused behind #1162. Existing #1154 owns the recurrent build-gate
delay and is next when CPU permits. The host remains CPU-constrained by owned
validation and review, so these recovery lanes are the measured safe maximum
at this instant rather than an arbitrary agent cap.
No new
Build Order scope is dispatching. BO-010 and the preserved paused/deactivated
rows remain held; #1151 stays paused with preserved rework.
#1093, #1108, #1111, #1123, and #1130 stay on workspace-race holds until #1161
lands. The 21:50 phase preview preserves the latest successfully emitted core
percentages and advances only review/CI states backed by GitHub evidence;
do not replace those estimates with guesses during review/rework. Host load
remains volatile; current memory has roughly 23 GiB available and the build
gate is again active as the five workers converge. Prefer logs/GitHub evidence
after a control-RPC timeout. BO-003 remains preserved on the serial critical
path behind #1161. Treat completed turns, stale bases, and green builds with unmet acceptance
criteria as pending Executor work, not merge-ready truth.

**Read-first map for this run:** `README.md` (pack index) →
`08-implementation-pointers.md` (verified per-ticket file/module/function
anchors for all 54 tickets — workers start here, and every published issue
links its own section) → `07-graph-parallelism-review.md` (waves, critical
path, serialization cliques) → `09-plan-review-synthesis.md` (review verdict
and accepted recommendations). Day-one width is 5 tickets (BO-004, BO-008,
DASH-006, DASH-017, DASH-018 have no blockers); staff the top fan-out spine
first — DASH-003 (8 dependents), BO-008 (6), BO-004 (5), BO-017 (5), BO-005,
DASH-001, DASH-008 — a stall there starves more of the fleet than anything
else. The serial critical path is BO-004→001→002→003→007→011→012→013→014→015
(amber in the committed plan preview, `docs/build-order/plan-preview.html`);
keep it staffed continuously.

## Start gate (historical contract; explicitly overridden for this run)

The operator-authorized override and live execution state above are now the
authority for this run. Do not attempt to recreate a fresh pre-execution OPEN
snapshot after runtime labels and lifecycle transitions have begun. The
remaining text in this section records the intended immutable ceremony and is
useful for fixing the publisher, but it is not a reason to pause the authorized
Phase 1 workers.

This handoff becomes executable only after the live Build Order root contains a
uniquely marked immutable pending `aiur-build-order-reconciliation` comment and
one distinct canonical successful comment linking a post-publication receipt
whose exact commit contains both valid
reconciliations, both external gates below are recorded as resolved, and the
operator's current conditional run authorization remains in force. No second
approval prompt is required after those conditions pass. Re-run the trusted
final-comment verifier;
neither caller-supplied identity or query JSON, Git object substitution,
imported foreign history, nor a merely local/API-visible commit is a start
gate. The verifier anchors the repository to the configured GitHub origin,
fetches the exact receipt-recorded pending comment ID, rejects malformed or
duplicate reconciliation evidence, and proves approval plus receipt
remain ancestors of the unchanged tip of the frozen branch while separately
proving approval is an ancestor of receipt. It rejects legacy graft entries in
both the worktree and common Git directories, and all authority API reads pin
`github.com` with finite timeouts. The frozen branch ref is
`refs/heads/build-order-research`. Deletion or a force-push that removes
either commit revokes this gate; never substitute `main`, a pull ref, or a tag.
Planning publication does not queue work. Until then, do not run Aiur,
implement tickets, or add `agent:todo`.

The finite authorized boundary is the one consolidated 54-member BO+DASH
graph. Publish and dispatch only those members after the verifier and gates;
every member retains the exact `model:codex-gpt-5.6-terra` label, with no model
substitution.

The immutable receipt and final verifier attest the publication-finalization
snapshot: all 56 issues are open and unlocked, have their receipt-bound
titles/bodies/full labels, the root has exactly 54 children, every
non-root has no children, and all 107 blockers are exact. Run that full verifier
immediately before the first execution mutation. Once the authorized run
begins, later lifecycle changes are legitimate runtime truth and do not rewrite
the receipt: gate resolution may update live issues, the skill-delivery issue
may close, and member issues may acquire `agent:*` labels. Record and resolve both
external gates while the skill issue is still open; only after both gates are
proven may the Executor close the skill issue and dispatch member work. Never close
the skill issue or add dispatch labels first and then attempt to use the now
historical OPEN receipt as though it were a fresh publication snapshot.

## Identity and objective

- Build Order: `its-everdred/aiur:build-order-dashboard`
- Plan version: 1
- Repository: `its-everdred/aiur`
- Researched commit: `9849f32963c2a65367bce565b3f5ede3777c218f`
- Approved planning commit: `4d8de9508206e08e314f2730cd916501a3b4cafd`
- GitHub root: marker-resolved #1084 at pending publication; always re-resolve
  live by the hidden Build Order root marker rather than trusting a copied
  number

Deliver the consolidated 54-ticket program: the authenticated,
GitHub-planning-read-only Build Order feature plus the dashboard companion
members, all direct children of one root (operator decision 2026-07-13).
GitHub owns current plan facts; Aiur owns runtime facts. Linear #1067,
skill-delivery work and deferred findings remain outside the root and cannot
change this run's 54-member denominator or ETA.

## Required startup

1. Read these repository-relative paths in order:
   - `docs/build-order/README.md`
   - `docs/brainstorms/2026-07-12-build-order-requirements.md`
   - `docs/build-order/05-technical-decisions.md`
   - `docs/build-order/build-order.json`
   - every `tickets[].document` path in
     `docs/build-order/build-order.json` (BO-001 through BO-020 under
     `tickets/` and DASH-001 through DASH-034 under `companion-tickets/`)
   - `docs/build-order/validation-report.md`
   - `docs/build-order/github-publication.md`
2. Use `/aiur-run`, not the retired `/aiur-loop` workflow. Require reviewed
   PR #1065 source head `6447f9c193d2322d63f54a58b9c54e0a72d3e98f` and
   squash-merged `main` commit `ed1846c4bc76d4657095da57951a0dbf3e914c3d`
   to be recorded, and verify the landed skills preserve multi-prefix
   validation, finite-boundary, review/rework, circuit-breaker, and publication
   rules. A matching skill name without the recorded authority is insufficient.
3. Write a three-to-five-sentence `/goal` stating that you are the Executor,
   the finite acceptance boundary, granted issue/merge authority, critical-path
   priority and terminal condition.
4. The receipt-bound full live verifier was superseded for this run by the
   explicit root override recorded in the live-state section. The Executor
   re-queried repository instructions, set the isolated operator config to
   `tracker.base_branch: main`, and verified current integration truth before
   dispatch. Never use planning JSON as fresher live GitHub truth.
5. Queue only approved members of the consolidated root under explicit user
   authority. The shared
   predecessor baseline is recorded as resolved (`origin/main` at
   `9849f32963c2a65367bce565b3f5ede3777c218f`), and any ticket-specific
   provider gate (GATE-003 on DASH-019, GATE-004 on DASH-013) must still be
   resolved before those tickets are pickable.

## External pre-dispatch gates

- **GATE-001 — integration baseline (RESOLVED):** the predecessor OCC run is
  complete and the baseline is resolved — `origin/main` at
  `9849f32963c2a65367bce565b3f5ede3777c218f` contains closed #1034 plus every
  accepted OCC successor. Record that resolved branch and SHA on the live
  root; do not silently implement against any earlier snapshot.
- **GATE-002 — Executor skill:** record reviewed source head
  `6447f9c193d2322d63f54a58b9c54e0a72d3e98f` and landed `main` commit
  `ed1846c4bc76d4657095da57951a0dbf3e914c3d`, then confirm `/aiur-build`,
  `/aiur-run`, and `/aiur-monitor` are discoverable. The separate human
  skill-delivery issue remains outside the Build Order denominator.

GATE-001 and GATE-002 are resolved for execution; the skill-delivery issue was
closed under the operator's explicit receipt override before Phase 1 dispatch.
BO-004 and BO-008 are the independent initial nodes. BO-001 follows BO-004.

Record GATE-001's resolution and resolve GATE-002 before changing the skill
issue from its publication-finalization OPEN state. Close that issue only after the
installed bounded skill is proven, and only afterward add dispatch state to
ready BO issues under the user's execution authority.

## Authority map

- GitHub: root/member identity, title/body, planning labels, lifecycle/state
  reason and native blockers.
- Aiur: running/queued/retry/paused state, progress, active agent stage, alerts,
  events and latest evidence.
- Planning pack: approved requirements, technical decisions, ticket contracts,
  initial scheduling/conflict metadata, validation and finite boundary.
- Executor: current readiness/capacity, review/rework routing, merge policy
  under authority, recovery, status and final proof.

Unknown/stale provider data never becomes empty, ready, successful or zero.
Aiur progress, including 100%, never clears a GitHub blocker.

## Initial graph and capacity

After both external gates resolve, start BO-004, BO-008, DASH-006, DASH-017,
and DASH-018 in parallel. BO-001
and BO-017 follow BO-004. BO-002 follows BO-001; BO-003 follows BO-002; BO-005
follows BO-017. BO-003, BO-005, BO-016, and BO-019 serialize on the
application-supervision seam wherever hard dependencies do not already order
them; BO-005 also serializes with DASH-029 on observation-envelope
consumption. BO-006 follows BO-005. BO-007 follows BO-001, BO-003, and BO-005.
BO-009 follows BO-001 and BO-008; BO-010 follows BO-008 and BO-009. BO-016
follows BO-004 and owns configured-repository ticket detail. BO-019 follows
BO-005 and owns bounded sanitized recent history. BO-018 follows BO-008,
BO-016, and BO-019 and owns accessible base context. BO-011 follows BO-007 and
BO-018 and adds Build Order relationships and truthful destination links.
BO-012 follows BO-003, BO-007, BO-010, and BO-011; BO-013 follows BO-008 and
BO-012; BO-014 follows BO-008 and BO-013. BO-020 follows BO-003 and BO-012 and
serializes with BO-013/BO-014 on the shared Build Order route surface. BO-015
follows BO-006, BO-014, BO-020, DASH-023, and DASH-033.

The DASH members carry the same in-graph serialization: DASH-001 with BO-012
on the OCC route/navigation shell, DASH-023 with BO-013/014 on the Build
Order route surface, and
DASH-029 with BO-005. DASH-018/019 serialize on the Claude process-lifecycle
adapter. DASH-004/019 depend on BO-004's configured-repository identity. The
eight supervised member services—DASH-002/009/012/018/019/024/025/026—also
declare every independently ready serialization pair
against BO-003/005/016/019 on the central application supervision tree. Hard
dependencies already order the omitted pairs.

Derive current readiness from GitHub native blockers, ticket lifecycle,
declared serialization and real capacity. Phase is only a rollout/display hint.
Maximize progress against ready critical-path work, not raw active count. Do not
activate deferred findings to keep slots busy.

## Review, rework and convergence

- Review each PR against its issue contract, decisions and current base. Use
  parallel independent code review where useful.
- Return a contained finding to the same ticket/worker through rework and the
  event bus. Do not multiply tickets to preserve PR momentum.
- Promote a new issue only for an independent P0/P1 acceptance blocker. Record
  P2/P3 and optimization evidence in the deferred ledger.
- At each status interval compare completed versus created/promoted work. If
  promotion exceeds completion, freeze further promotion until the original
  feature lands.
- Keep branches current, CI green and shared-write work sequenced. Merge only
  under the user's current authority and repository policy.

Report two tracks separately: bounded Build Order critical path/count/ETA, and
reliability/optimization findings as active only when separately authorized or
otherwise deferred. Deferred work cannot consume critical-path capacity or
prevent completion.

## Operational playbook (field-proven in the OCC run)

These patterns come from the predecessor dashboard run that shipped the OCC
wave; the full version lives at
`docs/operator-control-center/EXECUTOR-HANDOFF.md` on branch `occ-planning`.

- **Merge gates, every time:** verify the PR's `baseRefName` is the
  configured integration branch before merging (agents build stacked PRs — a
  mis-based squash lands in the wrong branch silently), and run
  `git merge-base --is-ancestor origin/<base> origin/<branch>` (a green PR
  can be green against a stale base). Merge with `--squash --admin`; the
  known seed-dependent SlotPolicy flake (#506) is mergeable-past when
  build/lint/dialyzer are green. Closing merged issues is manual.
- **Unstick with a message, not resume:** a paused/idle worker that is not
  converging (frozen HEAD, no file edits, not load-throttled, not
  attention-flagged) needs `scripts/aiurdev message <id> "<directive>"` to
  inject a real turn; resume alone re-pauses. Post durable directives as
  issue comments — message-queue text is lost on restart.
- **Finalization wedge:** a worker that committed but never pushes gets its
  work pushed by you from its workspace once the tree is clean; its own later
  push becomes a no-op.
- **Compress the finish line:** identify the single authoritative failure per
  head and send one exact packet. A branch with committed scoped source and
  only generated dirt should push after the reproducing test; the owning
  worker must resolve a current-main merge or re-cut, run its focused conflict
  suite, and push; an
  already-invalid CI head should not wait for unrelated jobs. Centralized CI
  owns the full gate, and two independent exact-head reviews start together
  only after the worker's head contains current main and that gate passes. Do
  not run duplicate local full suites, do not
  repeatedly merge a moving `main` during implementation, and do not split a
  converged review packet into serial mini-heads. The final ancestry check,
  fresh CI, and dual review remain mandatory.
- **Escalate ownership when convergence fails:** return the first lint,
  Dialyzer, stale-base, conflict, or review repair to the owning worker as one
  bounded packet. Then inspect long-running tickets, repeated cold dispatches
  or restarts, ownerless open PRs, frozen heads, repeated review/rework cycles,
  recurring base/conflict repair, and non-shrinking CI failures. If one bounded
  recovery cycle does not produce material progress, the owner disappears, or
  direct completion is reasonably faster and safer, stop duplicate writers and
  take over under the recorded authority. Catastrophic Aiur failure is not
  required. Use an isolated worktree, preserve the worker branch/workspace and
  acceptance boundary, defer nits, and record the evidence and outcome.
- **Restarts are branch-safe:** the checkout logic re-fetches an existing
  remote ticket branch, so recycling a wedged worker (bloated thread,
  CI-poll loop) loses only the unproductive turn, never committed work.
- **Old-branch skill-path collisions:** an older ticket branch can collide
  with turn-injected skill paths when merging the newly landed skill commit.
  Pause that worker, clean only artifacts verified as injected, merge current
  `main`, restore the tracked tree, and only then resume it.
- **Capacity:** track real CPU (`vmstat` id%), not 1-minute load; the
  observed thrash ceiling is ~8–11 concurrent agents on a 12-core box with
  `max_concurrent_builds: 2` as the true protector. Ramp `set max-agents`
  into measured idle, not optimism.
- **Review discipline:** dual review (correctness + adversarial) on every
  substantive PR, front-loaded in parallel; only `must_fix_before_merge`
  findings block a merge — downgrade the rest to the deferred ledger. Drive
  rework with `gh issue comment` (issue_comment), not `gh pr review`.
- **Hygiene:** commit subjects 3–7 word imperative, no AI/model mentions or
  attribution trailers anywhere; never edit `src/test/aiur/regression/`;
  patch labels via the REST API when `gh issue edit` hits the
  classic-Projects GraphQL error; never paste credentials into files,
  commands, or issues.

## Recovery and Aiur defects

Monitor workers, alerts, Commands, PRs, reviews, CI and machine capacity. First
message/retry or return the owning worker one consolidated recovery packet.
Take over a critical ticket when that bounded recovery does not restore
material progress, the PR loses its live owner, the same cycle repeats, or an
evidence-backed Executor judgment finds takeover to be the economical path.

Later-phase Ad Hoc issue #1182 adds advisory configuration for this watch:
`executor_takeover_first_alert_hours: 8` followed by recurring
`executor_takeover_continuous_alert_hours: 1` prompts. It has no `agent:todo`
and cannot delay the current started-PR drain or Build Order acceptance.

With debug authorization, file a sanitized Aiur issue for a reproducible Aiur
failure. Without it, ask the user first. Always remove credentials, tokens,
private content, account identifiers, environment values, local paths/hosts and
irrelevant source context.

## Terminal condition

Stop only when all 54 members — BO-001 through BO-020 and DASH-001 through
DASH-034 — are implemented, reviewed, green on the
current configured integration branch, merged, documented, cleaned up and
proven after merge.

BO-015 owns the acceptance matrix, real published-root dogfood, synthetic
cycle/invalid/degraded/20/50/100 fixtures and post-merge smoke, and closes the
root only after DASH-033's dashboard-parity proof and the Build Order
acceptance evidence both land. The Executor
runs the canonical real CLI/TUI flow from the Executor repository root because
issue workspaces cannot bypass the `--test` guard. Proof also covers the
authenticated browser, selection/deep links, LKG degradation, live activity,
context/dependency navigation, keyboard/touch/pan/zoom, light/dark/reduced
motion, mobile safe area, 200% zoom and preservation of Units, Commands and
Analytics.

After proof, BO-015 closes the GitHub root with state reason `COMPLETED`. The
loop ends there; it does not continue until every discovered reliability or
optimization opportunity is exhausted.

## Adjacent delivery that must not be lost

PR #1065 delivered the isolated `/aiur-build` and bounded Executor skill
rewrite. Its final reviewed source head is
`6447f9c193d2322d63f54a58b9c54e0a72d3e98f`; it was squash-merged to `main`
as `ed1846c4bc76d4657095da57951a0dbf3e914c3d`. Record both commits and verify
the landed skills before dispatch. Never merge mixed research PR #1064 merely
to recover skill files already present on `main`.
