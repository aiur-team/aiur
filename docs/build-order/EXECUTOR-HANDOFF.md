# Build Order Executor Handoff

## Live Executor state (updated 2026-07-13 23:51 PDT)

You are the **Executor**: you run Aiur to implement this feature, make every
PR merge-ready via review, do the merging, keep agents genuinely working, and
act as the fallback when an agent cannot finish its last mile. Everything
below this section is the binding contract; this section is the current live
truth and supersedes stale pre-run wording later in the document.

**State right now:** planning approval remains frozen at
`4d8de9508206e08e314f2730cd916501a3b4cafd`; the complete graph is live at root
#1084 with 54 members #1085–#1138 and 107 exact blocker relations. Skills PR
#1065 was reviewed at `6447f9c193d2322d63f54a58b9c54e0a72d3e98f` and
squash-merged to `main` as `ed1846c4bc76d4657095da57951a0dbf3e914c3d`.
Receipt finalization exposed a contained authority-loader defect after the
successful idempotent publication; the operator explicitly overrode that gate
for this run on root comment
`https://github.com/its-everdred/aiur/issues/1084#issuecomment-4964521448`.
Because execution has now legitimately mutated issue lifecycle state, the old
OPEN publication snapshot is historical evidence and must not be presented as
a fresh executable receipt.

Aiur is running against `main` from the repository root. Current `main` is
`a83a7e7230ffdc7b266baa287f2abd7b9dee39eb`, which includes the independently
re-reviewed hourly Executor-retrospective helper from PR #1150 and the merged
dogfood workspace-bootstrap fix from PR #1060. Phase 1 has
two merged tickets (#1086/BO-004 and #1087/BO-008), three original rework tickets
(#1088/DASH-006, #1089/DASH-017, and #1090/DASH-018), and three recovered
post-BO-004 workers (#1085/BO-001, #1104/BO-017, and #1111/DASH-004). #1103 is
paused on a deleted-inode workspace generation; #1123 is paused on both the
same workspace class and unresolved GATE-003. Direct P1 #1151 is in CI wait
outside the approved 54-ticket denominator. The runtime ceiling was reduced
from 16 to 6 after simultaneous cold bootstrap drove load to 43 against the
configured 5.5 ceiling; this is temporary containment, not a program cap. Raise
it toward the full ready width only after load and bootstrap contention return
to a safe range.

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
6. The prewarm base currently equals live `origin/main` at `97518e96`. Although
   `prewarm.poll_seconds` is zero, each tracker dispatch cycle calls
   `RepoBase.refresh_async/0`; after every merge verify the base fetches,
   rebuilds, and reaches the new `main` before newly-ready dispatch begins.
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
    members are #1139, #1140, #1142, #1146, #1148, #1149, #1151, #1152, and #1154;
    all carry `build-lane:adhoc`. Assign `phase:N` only when an ad hoc ticket is
    actually picked up, using the closest active phase; #1139 and #1151 are
    Phase 1, while deferred/untriaged tickets remain phase-unassigned and render
    in the preview's TBD row. Repeat this labeling and preview update for every
    new run-created ticket.
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

At 00:05 PDT the core graph is 3/54 merged. Core
#1088/#1089/#1090/#1091/#1096 and direct blocker #1030 occupy the six measured
slots; #1104 is requeued with its complete review packet. #1111 plus direct P1
#1151 await later measured slots, and newly-ready #1108 remains queued behind
that bounded rework. #1103/#1123 remain paused. Treat
completed turns, stale bases, and green builds with unmet acceptance criteria
as pending Executor work, not merge-ready truth.

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
- **Hand-fix the last mile in a worktree:** when nudges fail on lint/dialyzer
  or a small must-fix, take over — always in a fresh `git worktree`, never
  the main working tree (it holds the live `.aiur/config`) and never a live
  agent's workspace mid-edit. Verify Elixir edits with
  `Code.string_to_quoted!/1` and run `make lint` before pushing.
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
message/retry or return the owning worker to rework. Take over a critical ticket
only when an Aiur defect or hard operational failure makes that the economical
backstop.

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
