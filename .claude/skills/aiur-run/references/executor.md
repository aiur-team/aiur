# The Aiur Executor

The Executor is the operator responsible for an Aiur run from launch through
the run's agreed terminal condition. A human who launches Aiur is the Executor
and may use an agent with `aiur-monitor` as an assistant. When an agent is told
to use `aiur-run`, that agent is the Executor.

This role owns the system of work. It receives the requirements, ticket
contracts, and feature collection from the Feature Planner using `aiur-build`. At
runtime, GitHub owns ticket facts and Aiur owns agent activity, progress,
alerts, and events; planning documents preserve approved intent.

Experiment wakes (`experiments:auto`): `system.experiment.<id>.preregister`
starts analyst pre-registration; `.report_due` starts the report flow (X6).
Read `report_reason`; report insufficient data honestly. Ignore `.cancelled`.
Topic IDs encode dots as `%2E`.

## Contents

- [Establish the authority envelope](#establish-the-authority-envelope)
- [Protect convergence](#protect-convergence)
- [Continuous-build intake](#continuous-build-intake)
- [Core responsibilities](#core-responsibilities)
- [Command decision loop](command-decisions.md)
- [Capacity policy](#capacity-policy)
- [Recovery ladder](#recovery-ladder)
- [Convergence escalation and takeover](driving.md#convergence-escalation-and-takeover)
- [Pull-request review loop](review-and-merge.md#pull-request-review-loop)
- [Merge mechanics](review-and-merge.md#merge-mechanics)
- [Ticket close-out](review-and-merge.md#ticket-close-out)
- [Hourly meta-analysis](meta-analysis.md)
- [Aiur bug-report policy](#aiur-bug-report-policy)
- [Decisions and handoff](#decisions-and-handoff)

## Establish the authority envelope

Before consulting repository documentation, read `~/.aiur/repo/<owner>/<repo>/executor/handoff.md`. It is the current machine's
run-specific handoff; GitHub and Aiur still provide the authoritative live ticket and runtime state. Keep this single living document current whenever the
operator gives a directive, frames the run's request, supplies context that cannot be recovered from the repository/history, or changes the Executor's
role or authority. A directive not written into the handoff has not been recorded. When replacing an Executor, rewrite it wholesale with the next
Executor's ranked work and hazards; never append another dated checkpoint.

Record these decisions before making the corresponding mutations. Reuse clear answers already present in the request or handoff instead of asking again.

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

Then act on that default. When a fix is reversible and its rollback is one line,
execute and report; asking is the more expensive option here, not the safer one.
Two instances in the 2026-07/08 run held a correct diagnosis while waiting for
permission that was never required — one accumulated 229 minutes of zero-commit
time, the other spent roughly eight hours issuing ~8 futile `resume` calls.
Escalation is for the decisions that are genuinely the operator's: irreversible
actions, spend, external publication, and product direction. It is not for the
Executor's own reversible operational choices.

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

## Continuous-build intake

Every authorized new feature, epic, bug batch, or experiment joins the repository's
single continuous build by default. Follow [the intake procedure](continuous-build-intake.md)
for feature collection and `feature:<slug>` labels,
native `blocked_by` links where real, queue membership, and placement read-back.
New features never create standalone Build Order roots; existing roots remain history.
Only an explicit operator exclusion leaves filed work outside the build: park it
with `needs-triage`/`human:todo` and the reason. Unfiled deferred findings remain
in the ledger under the convergence policy above.

“Prioritize” means place the work ahead of the previous next-up using priority labels and queue ordering, then report what it displaced. A label alone is not placement. Verify the collection, projected labels, prerequisites, membership, and effective start order before reporting intake complete.

Use `agent:queued` in the same creation request for executable members; the queue
promotes ready members to `agent:todo`. Never create first and label later.

**Give every new ticket a home-page epic.** After issue creation returns its number, run `aiur epic list` for the configured general keys, then `aiur epic set <epic> <ids…>` once per epic (up to 200 ids). Defaults are `bugs`, `design`, `infra`, `docs`; repositories can change them. An unknown key is refused with the list of valid keys; read it rather than guess. For feature members, use `aiur feature add <slug> <ids…>` instead. If unsure, set none: the ticket goes to the column its type label matches (defaults `bug`, `design`, `refactor`/`chore`, `documentation`), else Unsorted. **Never** express an epic as a label: `epic:<name>` parks the ticket and `epic` marks an undispatched container. Epic assignment is local Aiur state; if it fails, report the failure and continue filing. When promoting or retro-classifying many tickets, group ids by epic. If feature ownership conflicts, use `aiur feature add <slug> <ids…> --move` only when the ticket really changed feature.

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
   dependencies, conflicts, or the configured capacity limit, and checks before
   dispatch that a ticket's deliverable does not already exist — work shipped
   months earlier or sitting in an open draft PR turns into agent busywork or a
   worker that pauses repeatedly with nothing to do;
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
9. listens for newly created Commands, answers settled and reversible ones
   with explicit Executor attribution, and escalates uncertain or consequential
   ones to the operator without answering them.
Read now: [Command decision loop](command-decisions.md) when a Command arrives.

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
- Know the host's measured ceiling instead of inferring one. A 16-core/31 GB
  machine saturates at roughly 19-20 concurrent agents (load ~14, memory
  10/31 GB, GitHub budget 4668/5000); CPU is the binding resource and memory and
  API budget are not close at that concurrency. `max_load_average` is multiplied
  by the scheduler count, so `1.5` on 16 cores means "hold at load ~18", not a
  1.5 load cap.
- The daemon's adaptive dispatch envelope resets to one slot on every start and
  widens by `load_ramp_step` per below-target sample, so a restarted fleet takes
  tens of minutes to reach a high ceiling. Do not read that ramp as idleness or
  measure capacity immediately after a restart.
- Prefer runtime overrides to editing committed configuration during a run.
  Committed configuration can still win, though:
  `agent.max_concurrent_agents` silently floors `--max-agents`.
- Record material cap changes and their observed reason.

## Recovery ladder

Prefer `aiurdev restart --keep-agents` for fleet upgrades. Save `aiurdev agents --json` before; afterward compare `aiurdev status --handoff --json`: every issue is adopted with the same provider pid and session id, or has a fallback reason. Verify `aiurdev alerts` records `system.restart.handoff.completed`, adopted tickets have no startup-claim release, and a ready ticket dispatches within one poll interval. [Restart semantics](../../../../website/docs-app/reference/cli.md#restart-semantics) cover failed-build recovery.
A fleet-wide quiet board is a blockage, not idleness, and none of its causes
log anything. Clear the fleet-level gates before triaging any single agent: run
bare `aiurdev resume` first, because the global pause switch survives daemon
restarts and reboots while per-ticket `resume <id>` exits 0 with no effect;
check `agent.max_concurrent_agents` against the requested ceiling; confirm the
prewarm record `~/.aiur/repo/<owner>/<repo>/base-record.json` matches the
`latest` clone's HEAD and prewarm-script hash, since a failed base build holds
every dispatch tick silently (issue #1404); and allow for the post-restart
dispatch ramp.

Alerts persist across restarts (#1231). Check timestamps and trust the live table over stale alerts.

A trusted `CHANGES_REQUESTED` or explicitly blocking `COMMENTED` review on an open PR moves
its ticket from `agent:human-review` or `agent:ci-wait` to `agent:rework`
automatically — the `pull_request_review` webhook and the review-submission
poll route through `CommentWake`, so the manual `agent:human-review` to
`agent:rework` relabel is no longer required. After posting a review, verify
the ticket left `agent:human-review`; only relabel by hand when the automatic
transition did not fire, and check the delivery (review state, trusted author,
open PR) before doing so.

Body-only `COMMENTED` reviews need a line or heading starting with `Blocking:`,
`Blockers:`, `Must fix:`, or `Changes required:`, or an update, rebase, merge, or
fix requested “before merge”. Clean summaries such as “No blockers; waiting on
CI” or “All blockers resolved” do not route to rework.

Failed CI in `agent:human-review` routes to rework when that head already passed
CI or the head changed. An inherited failure on a dismissed head remains held;
the existing test-only one-poll retry still applies.

For an agent with stale activity, ignored feedback, repeated retries, or a
ticket it will not pick up:

1. inspect `aiurdev watch --full`, `aiurdev alerts --needs-attention`, the
   ticket/PR, and the agent workpad/log evidence;
2. send a concise, ticket-specific message with `aiurdev message <id> <text>`;
   exit 124 = outcome unknown: check the ticket log first, then retry only with the printed `--message-id` command, never a plain resend (a plain resend now queues a second copy).
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
Read now: [Convergence watch and takeover](driving.md#convergence-watch-and-takeover) when bounded recovery does not restore progress.

Read now: [Pull-request review loop](review-and-merge.md#pull-request-review-loop), [Merge mechanics](review-and-merge.md#merge-mechanics), and [Ticket close-out](review-and-merge.md#ticket-close-out) before review, merge, or closure.

Read now: [Hourly meta-analysis](meta-analysis.md) for the required hourly review.

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
- the deferred findings ledger and ticket-creation circuit-breaker state,
  including the path to `~/.aiur/repo/<owner>/<repo>/meta/findings.ndjson` and
  any record still sitting at `ticket: null`.
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
