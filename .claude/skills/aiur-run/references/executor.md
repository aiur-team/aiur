# The Aiur Executor

The Executor is the operator responsible for an Aiur run from launch through
the run's agreed terminal condition. A human who launches Aiur is the Executor
and may use an agent with `aiur-monitor` as an assistant. When an agent is told
to use `aiur-run`, that agent is the Executor.

This role owns the system of work. It receives the requirements, ticket
contracts, and Build Order from the Feature Planner that used `aiur-build`. At
runtime, GitHub owns ticket facts and Aiur owns agent activity, progress,
alerts, and events; planning documents preserve approved intent.

## Contents

- Establish the authority envelope
- Protect convergence
- Core responsibilities
- Capacity policy
- Recovery ladder
- Pull-request review loop
- Aiur bug-report policy
- Decisions and handoff

## Establish the authority envelope

Record these decisions before making the corresponding mutations. Reuse clear
answers already present in the request or handoff instead of asking again.

- ticket scope or the GitHub selector that defines it;
- whether the Executor may create newly discovered tickets;
- whether it may review and comment on pull requests;
- whether it may merge, and under which CI/approval conditions;
- whether it may self-fix or take over worker tickets;
- starting and maximum concurrency, resource limits, and reporting cadence;
- whether debug mode is authorized.

Default to reversible operational actions within the stated scope. Escalate
product changes, architecture changes, scope cuts, destructive actions, and
anything outside the recorded authority. Never infer merge or issue-creation
authority.

## Protect convergence

Before launch, pin the feature acceptance criteria, critical path, required
documentation/cleanup, end-to-end proof, and explicit terminal condition. The
Executor optimizes convergence on that boundary. Agent utilization is
secondary.

Classify every discovered finding before creating work:

- **P0/P1 feature blocker:** directly blocks required behavior, CI/merge,
  daemon operation, or mandatory proof; it may join the active scope.
- **Contained rework:** belongs to an existing ticket's acceptance; return that
  ticket to rework instead of multiplying tickets.
- **P2/P3 non-blocker:** preserve it in the deferred findings ledger; do not
  create or dispatch an individual feature-run ticket.
- **Optimization:** preserve evidence for a separately authorized run.

“Worth fixing” and “we know how” do not expand the active boundary. Each
deferred entry keeps description, severity, evidence/reproduction, affected
ticket/component, why acceptance is not blocked, and suggested disposition.

At the reporting interval, compare completed tickets with created/promoted
tickets. If creation exceeds completion, freeze new ticket creation. Continue
recording non-blocking findings in the deferred ledger until the bounded
feature is accepted or the human explicitly resets the circuit breaker.

Report the feature critical path/count/ETA separately from deferred reliability
and optimization work. Deferred work does not alter feature remaining count or
ETA, consume critical-path capacity, or prevent feature completion. A nearly
finished reliability PR may land when economical, but it cannot displace the
critical path.

## Core responsibilities

The Executor continuously:

1. keeps every ready, independent ticket moving without violating hard
   dependencies, conflicts, or the configured capacity limit;
2. watches agent state, activity age, alerts, host capacity, review state, and
   integration risk;
3. diagnoses stuck or misbehaving agents and attempts the least invasive
   recovery first, then assumes ownership when bounded recovery is not restoring
   material convergence and takeover authority exists;
4. verifies the owning worker has produced a current-base, fresh-CI head before
   arranging independent review, then returns actionable findings through the
   tracker/event path workers consume;
5. protects merge ordering, required checks, and feature-level acceptance;
6. captures newly discovered work and Aiur defects without losing provenance;
7. leaves a durable decision and incident trail that another Executor can
   resume.
8. reviews its own structured monitoring wake/outcome history once per hour,
   records avoidable no-action checks and small evidence-based cadence/trigger
   adjustments, and remains available without polling merely to appear active.

## Capacity policy

The objective is the fastest safe convergence on the bounded outcome. Achieve
that by continuously maximizing useful parallelism, not by chasing an agent
count detached from ready work.

- Treat `set max-agents` as a runtime admission ceiling, not a steady-state
  target below known capacity and not a fixed program-wide cap. Recompute it
  from dependency-ready width, serialization constraints, model capacity, CPU,
  memory, file descriptors, and build-gate pressure. When
  `agent.target_load_average` is enabled, let Aiur's AIMD controller adjust the
  effective slots beneath the recorded maximum ceiling. Keep that ceiling high
  enough to admit every ready independent lane — newly-ready Build Order work
  may use more than five agents when the graph and the machine allow it.
- Manually ramp the ceiling as the primary controller only when AIMD is
  disabled. Target sustained CPU utilization first, then memory, file
  descriptors, build serialization, model/provider capacity, review capacity,
  or dependency width as the next limiting resource.
- Measure live state before each recompute with the daemon plus host evidence:
  `aiurdev agents`/`aiurdev status`, CPU idle and run-queue depth, available
  memory, FD and build pressure, and occupied agent slots. Distinguish current
  worker-owned browser/test processes from stale PID-1 daemons with no live
  owner; count the latter as recoverable capacity, not scheduled load.
- Lower the cap only when measured CPU saturation reduces throughput, memory or
  file descriptors approach unsafe bounds, build contention stops useful
  progress, providers throttle, or review quality declines. Record the exact
  restoration threshold and re-raise the cap immediately when it clears; a
  temporary reduction must not silently become the new normal.
- Keep independent lanes occupied. Do not fill slots with tickets that are
  blocked, conflict on a contract/write surface, or cannot merge safely.
- Count independent background review/rework lanes in the utilization plan.
  CI-wait and human-review tickets do not consume implementation slots, but
  their available reviewer lanes must be staffed.
- At every observation, compare active useful work with the run's target and
  maximum. If below target, name the exact blocker—dependency width, held
  workspace, CI, review, quota, CPU, memory, or serialization—and work the
  highest-fan-out unblocker. After each merge or gate transition, recompute and
  dispatch the entire newly ready batch immediately.
- Independently of event wakes and adaptive polling, run a hard ten-minute
  capacity audit. Record useful implementation/review lanes separately from
  CI-wait, paused, deactivated, completed, and dependency-blocked rows, plus
  ceiling, CPU/load, available memory, build serialization, provider quota,
  and review capacity. A below-target audit must name the limiting gate and
  trigger the highest-leverage in-scope scheduling or recovery action.
- Prefer runtime overrides to editing committed configuration during a run.
- Record material cap changes and their observed reason.

## Recovery ladder

For an agent with stale activity, ignored feedback, repeated retries, or a
ticket it will not pick up:

1. inspect `aiurdev watch --full`, `aiurdev alerts --needs-attention`, the
   ticket/PR, and the agent workpad/log evidence;
2. send a concise, ticket-specific message with `aiurdev message <id> <text>`;
3. correct labels, dependency state, or queue state only when the authoritative
   source proves it is wrong and the authority envelope permits it; in a GitHub
   workflow, shelve an undispatched ticket with the `agent:paused` tracker
   overlay, not a runtime pause command;
4. pause/resume an existing worker; when process state is broken, stop and
   relaunch the run because there is no per-worker restart control;
5. route a reproducible Aiur defect under the bug policy below;
6. take over the affected ticket/lane when bounded recovery has not restored
   material progress, the PR has lost a live owner, the same failure cycle is
   repeating, or the Executor reasonably judges direct ownership to be the
   faster and safer route to the finite acceptance boundary, provided self-fix
   or takeover authority was granted.

Prefer restoring workers over doing their work. The Executor is a backstop,
not the default implementation lane. A catastrophic Aiur failure is sufficient
for takeover but is not required; sustained non-convergence is also sufficient.

## Convergence escalation and takeover

Do not measure progress solely by whether a worker process is alive. Inspect
long-running tickets and PRs for delivery progress, particularly when the code
was implemented quickly but review, rework, CI, or integration has consumed
most of the ticket lifetime.

Escalation signals include:

- multiple worker starts, cold dispatches, `max_turns` recycles, pause/resume
  loops, or a completed-but-claimed entry with no continuation;
- an open PR with no live owner, a frozen head, or repeated turns without a
  commit, test result, resolved finding, or reduced diff;
- repeated comment-triggered review-to-rework transitions, exact-head reviews
  that continually mint new blocking findings, or fragmented reviewer packets;
- repeated integrations of a moving base, recurring conflicts on the same hot
  files, or a branch that repeatedly becomes stale before review begins;
- recurring CI/lint/Dialyzer failures without a shrinking authoritative failure
  set, including a non-latching thrash alert or failed wake/continuation path;
- elapsed delivery time that is disproportionate to the observed implementation
  work and no evidence-backed completion trajectory.

When one or more signals appear:

1. inspect the issue and PR timelines, commits, checks, review comments, base
   ancestry, live agent state, restart count, workpad, and agent logs;
2. identify the single current blocker and send one consolidated P0/P1 failure
   or update/re-cut packet to the owner;
3. allow one bounded recovery cycle when the owner is live and the repair is
   economical, while defining the material progress that must occur;
4. if the worker repeats the same cycle, makes no material progress, becomes
   unowned, or direct completion is now reasonably safer/faster, stop duplicate
   writers and take over under the recorded authority;
5. use an isolated worktree, preserve the existing branch/workspace, retain the
   original acceptance boundary, defer non-blocking nits, establish one
   current-base head, run focused validation plus the required central gate,
   and merge under the recorded policy;
6. record the evidence, attempted recovery, takeover reason, and outcome in the
   durable handoff so future runs can improve their triggers.

This is a judgment rule, not a rigid elapsed-time gate. Do not wait for a
catastrophic crash or an arbitrary age threshold when the evidence already
shows that delegation is not converging. Conversely, do not take over merely
because the first ordinary repair is inconvenient.

## Pull-request review loop

Branch freshness is an owning-worker responsibility. A pull request reaches
review-ready state only when all of these are true:

- its `baseRefName` is the configured integration branch;
- the current remote base head is an ancestor of the exact PR head;
- fresh CI for that exact head has passed the required gate.

If any condition fails, send one bounded update/re-cut directive to the owning
ticket and let its agent fetch, integrate or re-cut, resolve semantic drift,
validate, and push. Do not assign reviewers against the stale head. If the
bounded attempt does not materially converge, apply the takeover rule above
instead of issuing the same directive indefinitely. Once all conditions hold:

1. reserve or rebalance capacity for multiple independent background reviewers;
2. use `ce-code-review` when Compound Engineering is available, adding the
   relevant security, data, frontend, backend, or design lens for the change;
3. reconcile duplicates and contradictions, classifying each finding under the
   convergence policy before routing it;
4. return contained findings to the existing ticket as rework; create a new
   ticket only for an independent P0/P1 feature blocker;
5. confirm the event bus or tracker transition wakes the owning agent and that
   it acknowledges the rework;
6. require the worker to restore the same branch-freshness and CI gate after
   fixes, rerun targeted review, then apply the recorded merge policy.

If tooling or an explicit resource limit prevents parallel review, record the
degraded review and compensate before merge. Do not equate green CI with
feature acceptance. The integration/capstone owner must still produce the
evidence named by the planning handoff.

## Aiur bug-report policy

An Aiur defect includes crashes, leaked background processes after stop,
workers ignoring delivered comments, ready tickets not being dispatched,
broken state transitions, or controls that report success without effect.

Always:

- reproduce or preserve evidence before changing the failing state when safe;
- include expected/actual behavior, minimal reproduction, timestamps, relevant
  versions, and sanitized logs;
- remove secrets, tokens, credentials, environment-variable values, personal
  data, private hostnames/addresses, and unnecessary proprietary code;
- generalize local absolute paths unless the remaining suffix is necessary;
- link the runtime incident to the source ticket without copying private
  ticket content.

`--debug` controls evidence capture only. It permits retaining additional
non-sensitive technical detail that helps reproduction, but never grants
authority to create or comment on an external issue. Debug never waives privacy
or secret-removal rules.

Creating or commenting on an Aiur-defect ticket requires separate, explicit
authority recorded in the run's authority envelope. Check for duplicates before
using that authority. Without it, prepare a sanitized bug draft and ask the
human controlling the run before creating or commenting. Diagnostic reads and
the draft do not require publication authority. Link only public/safe source
tickets; otherwise keep an opaque local correlation in the handoff.

Filing a reproducible defect and dispatching it are separate decisions.
Diagnose and file first; then decide whether to dispatch it now. Free capacity
is necessary but not sufficient — the ticket must also be explicitly
authorized/in-boundary or a direct P0/P1 acceptance blocker, and dispatching it
must not displace ready critical-path work. Incidental reliability findings
such as an orphaned-daemon cleanup stay in the deferred ledger even when a
capacity audit shows idle slots. Base the call on the measured live state from
the capacity policy and record the dispatch-or-defer outcome and its reason in
the decision ledger.

## Decisions and handoff

Record decisions that affect scheduling, recovery, ticket creation, review,
merge ordering, capacity, or acceptance. Distinguish reversible automatic
decisions from escalations awaiting a human answer.

A resumable handoff contains:

- the authority envelope and terminal condition;
- Build Order ID/plan version or the live GitHub selector;
- current queries to run, not a copied status table presented as live truth;
- unresolved decisions, incidents, and sanitized bug links;
- integration/acceptance owner and remaining evidence;
- the last deliberate capacity setting and why.
- the deferred findings ledger and ticket-creation circuit-breaker state.
- the stable monitoring run ID, hourly retrospective log location, last
  completed review, current adaptive cadence/trigger settings, and any repeated
  notification gap reserved for terminal synthesis. Preserve the ID only
  across handoffs of the same run; a later run receives a new ID.
- the ten-minute capacity timer identity, latest audit path/timestamp, current
  useful count versus target, and last below-target limiting gate/action.
- the adaptive quiet-audit wait state: the floor/ceiling/backoff bounds, the
  last wake reason, its audit outcome and intervention/no-action result, and the
  next planned interval, plus any dispatch-or-defer decision recorded for a
  discovered Aiur defect.

The one-hour retrospective is a hard cadence independent of ordinary wakeups.
Review the preceding hour, not merely the latest poll. Classify each wake as
useful/actionable or no-action/redundant, avoid overfitting isolated events, and
record either one small adjustment or an explicit unchanged decision. At the
run's capstone, convert only repeated, well-evidenced gaps into at most one or
two deferred Aiur optimization issues under the existing publication authority;
never let this instrumentation expand the active feature boundary.

A successful run is terminal only when the agreed scope is implemented,
independently reviewed, green against the current configured base, merged under
the recorded policy, documented/cleaned up, and proven through the named
end-to-end workflow. An explicit human stop ends operation but must be recorded
as stopped or incomplete rather than accepted. A quiet board, one empty poll,
or all child tickets closing without capstone evidence is not sufficient.
