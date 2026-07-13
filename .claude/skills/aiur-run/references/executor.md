# The Aiur Executor

The Executor is the operator responsible for an Aiur run from launch through
the run's agreed terminal condition. A human who launches Aiur is the Executor
and may use an agent with `aiur-monitor` as an assistant. When an agent is told
to use `aiur-run`, that agent is the Executor.

This role owns the system of work. It does not replace the Planning Executor
that used `aiur-build` to define requirements, ticket contracts, and the Build
Order. At runtime, GitHub owns ticket facts and Aiur owns agent activity,
progress, alerts, and events; planning documents preserve approved intent.

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

The objective is useful throughput, not the highest agent count.

- Start conservatively, then raise the cap with
  `aiurdev set max-agents <n>` while ready work and host headroom remain.
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
   source proves it is wrong and the authority envelope permits it;
4. pause/resume or restart the affected worker/run when delivery or process
   state is broken;
5. route a reproducible Aiur defect under the bug policy below;
6. take over the ticket or apply a small Aiur fix only when the fleet cannot
   make progress and self-fix authority was granted.

Prefer restoring workers over doing their work. The Executor is a backstop,
not the default implementation lane.

## Pull-request review loop

When a pull request reaches review-ready state:

1. launch multiple independent background reviewers when capacity permits;
2. use `ce-code-review` when Compound Engineering is available, adding the
   relevant security, data, frontend, backend, or design lens for the change;
3. reconcile duplicates and contradictions into actionable findings;
4. comment findings on the tracker/PR surface configured for the workflow;
5. confirm the event bus or tracker transition wakes the owning agent and that
   it acknowledges the rework;
6. rerun targeted review after fixes, then apply the recorded merge policy.

Do not equate green CI with feature acceptance. The integration/capstone owner
must still produce the evidence named by the planning handoff.

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

If the run was launched with `--debug`, the agent Executor is authorized to
open a sanitized Aiur bug ticket automatically. Debug never waives the privacy
and secret-removal rules; it only permits retaining non-sensitive technical
detail that helps reproduction.

Without `--debug`, prepare a sanitized bug draft and ask the human Executor for
permission before opening it. Diagnostic reads and the draft do not require
that permission.

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

The run is terminal only when the agreed scope and feature-level acceptance are
satisfied, or the human explicitly stops it. A quiet board, one empty poll, or
all child tickets closing without capstone evidence is not sufficient.
