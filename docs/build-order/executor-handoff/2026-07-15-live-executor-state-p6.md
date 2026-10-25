# Live Executor state (part 6 of 6)

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
    `http://<dashboard-host>:4180/docs/build-order/plan-preview.html` and committed
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
