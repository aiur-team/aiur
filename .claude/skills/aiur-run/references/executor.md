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
   recovery first;
4. arranges independent review for pull requests and returns actionable
   findings through the tracker/event path workers consume;
5. protects merge ordering, required checks, and feature-level acceptance;
6. captures newly discovered work and Aiur defects without losing provenance;
7. leaves a durable decision and incident trail that another Executor can
   resume.

## Capacity policy

The objective is progress against the bounded outcome, not the highest agent
or ticket count.

- Treat `set max-agents` as the session safety ceiling. When
  `agent.target_load_average` is enabled, let Aiur's AIMD controller adjust the
  effective slots beneath that ceiling; raise the ceiling deliberately only
  when ready critical-path work and host/review headroom remain.
- Manually ramp the ceiling as the primary controller only when AIMD is
  disabled. Lower it for pressure, provider throttling, or review backlog that
  load average does not capture.
- Lower the cap when CPU saturation, memory pressure, file-descriptor errors,
  repeated build contention, provider throttling, or declining review quality
  appears.
- Keep independent lanes occupied. Do not fill slots with tickets that are
  blocked, conflict on a contract/write surface, or cannot merge safely.
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
6. take over the affected ticket/lane when it remains blocked after recovery,
   takeover is the best option, and self-fix authority was granted.

Prefer restoring workers over doing their work. The Executor is a backstop,
not the default implementation lane.

## Pull-request review loop

When a pull request reaches review-ready state:

1. reserve or rebalance capacity for multiple independent background reviewers;
2. use `ce-code-review` when Compound Engineering is available, adding the
   relevant security, data, frontend, backend, or design lens for the change;
3. reconcile duplicates and contradictions, classifying each finding under the
   convergence policy before routing it;
4. return contained findings to the existing ticket as rework; create a new
   ticket only for an independent P0/P1 feature blocker;
5. confirm the event bus or tracker transition wakes the owning agent and that
   it acknowledges the rework;
6. rerun targeted review after fixes, then apply the recorded merge policy.

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

When a human requests a run with `--debug`, that is narrow standing consent for
the agent Executor—not the CLI flag itself—to open sanitized Aiur-defect tickets
in Aiur's tracker after checking for duplicates. This authority is independent
of permission to create product tickets. Debug never waives privacy and
secret-removal rules; it only permits retaining non-sensitive technical detail
that helps reproduction.

Without `--debug`, prepare a sanitized bug draft and ask the human controlling
the run before creating or commenting on an issue. Diagnostic reads and the
draft do not require that permission. Link only public/safe source tickets;
otherwise keep an opaque local correlation in the handoff.

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

A successful run is terminal only when the agreed scope is implemented,
independently reviewed, green against the current configured base, merged under
the recorded policy, documented/cleaned up, and proven through the named
end-to-end workflow. An explicit human stop ends operation but must be recorded
as stopped or incomplete rather than accepted. A quiet board, one empty poll,
or all child tickets closing without capstone evidence is not sufficient.
