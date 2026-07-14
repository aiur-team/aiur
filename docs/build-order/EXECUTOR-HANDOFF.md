# Build Order Executor Handoff

## Live Executor state (updated 2026-07-14 10:52 PDT)

You are the **Executor**: you run Aiur to implement this feature, make every
PR merge-ready via review, do the merging, keep agents genuinely working, and
act as the fallback when an agent cannot finish its last mile. Everything
below this section is the binding contract; this section is the current live
truth and supersedes stale pre-run wording later in the document.

**State right now:** planning approval remains frozen at
`4d8de9508206e08e314f2730cd916501a3b4cafd`; the complete graph is live at root
#1084 with 54 members #1085–#1138 and 107 exact blocker relations. The historical
receipt gate remains operator-overridden for this run. Aiur is running from the
repository root against `main`; current accepted `main` is
`b506146534f1ea1c9be5ee5b2a683683e8e2bf04`, including BO-009/#1096. The core
program is 6/54 merged with 48 remaining.

The runtime session ceiling is 15 workers, governed by Aiur's effective-slot
controller and shared build gates. The operator target is 10–15+ useful agents
whenever dependency width and measured CPU/memory/provider/review capacity
permit. Four implementation/rework workers are live on #1091, #1097, #1109,
and #1161; #1103 is returning immediately from completed dual review to rework.
Green #1088 and green reliability heads #1151/#1162 are consuming independent
background review lanes rather than implementation slots. #1090,
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
    members are #1139, #1140, #1142, #1146, #1148, #1149, #1151, #1152,
    #1154, #1161, #1162, and closed duplicate #1164; all carry
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

At 10:52 PDT the core graph is 6/54 accepted. Four Aiur workers are actively
turning, #1103 is re-entering rework as the fifth, and all available background
review slots are assigned to green heads. The configured ceiling is 15; the
shortfall is the finite ready graph plus the #1161 workspace gate, not an
intentional low cap.
#1090, #1093, #1108, #1111, #1123, and #1130 stay on workspace-race holds
until #1161 lands.
The latest agent-emitted progress evidence is 1088=80, 1091=60, 1096=100
(merged), 1097=50, 1103=80, 1109=70, 1151=70, 1161=60, and 1162=80.
Concurrent test and Dialyzer work briefly raised host load to 62 while memory
remained healthy; the burst has drained and the session ceiling is restored to
15. Prefer logs/GitHub evidence after a control-RPC timeout. No additional core ticket is safely
dependency-ready outside the held/gated set. Treat completed turns, stale
bases, and green builds with unmet acceptance criteria as pending Executor
work, not merge-ready truth.

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
