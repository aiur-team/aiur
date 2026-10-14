# Live Executor state (part 3 of 6)

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
