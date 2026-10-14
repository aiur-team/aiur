# Live Executor state (part 4 of 6)

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
