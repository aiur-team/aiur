# Live Executor state (part 5 of 6)

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
    deferred recovery evidence: the checked-in `aiur-agent` skill requires
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
