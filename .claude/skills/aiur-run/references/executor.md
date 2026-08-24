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
- Merge mechanics
- Ticket close-out
- Hourly meta-analysis
- Aiur bug-report policy
- Decisions and handoff

## Establish the authority envelope

Before consulting repository documentation, read
`~/.aiur/repo/<owner>/<repo>/executor/handoff.md`. It is the current machine's
run-specific handoff; GitHub and Aiur still provide the authoritative live
ticket and runtime state. Keep this single living document current whenever the
operator gives a directive, frames the run's request, supplies context that
cannot be recovered from the repository/history, or changes the Executor's
role or authority. A directive not written into the handoff has not been
recorded. When replacing an Executor, rewrite it wholesale with the next
Executor's ranked work and hazards; never append another dated checkpoint.

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

When creation is authorized, encode that classification in the same creation
request. Executable work receives the configured lifecycle todo label
(`agent:todo` in the standard workflow); deferred work receives `needs-triage`
or `human:todo` and states why. Build Order roots carry `build-order`, while
explicitly named `Epic:` containers carry `epic`; both are hierarchy and remain
undispatched. Never split
issue creation and disposition across two requests: failure of the label edit
otherwise leaves an invisible ticket that looks complete to the findings
ledger but can never be claimed.

This is mechanical on both filing surfaces. Agent workspaces resolve `gh`
through Aiur's wrapper, while the repository `PreToolUse` hook checks Executor
Bash commands before they run. Both refuse an `issue create` with no disposition
and refuse direct REST or GraphQL issue creation that bypasses the checked label
flags. The aiur-build publication validator separately refuses a Build Order
whose executable members are projected undispatched. Use
`gh issue create --label ...`; keep `gh issue list --search 'no:label'` as the
independent safety-net audit before treating a queue as empty.

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

## Command decision loop

Launching the run with `--executor` arms the daemon-resident Executor listener
(`Aiur.ExecutorListener`) as part of launch; there is no separate subscription
step to forget. The run supervises and restarts it, it subscribes to
`executor.decision.requested` / `executor.decision.deferred`, and it replays
from its own durable watermark so a restart re-delivers only what was missed.
Each Command surfaces as a needs-attention alert in `aiur watch` / `aiur
alerts --needs-attention`; read the Command's payload with `aiur commands
<decision-id>`. This listener is the command inbox: do not discover new
Commands by polling or sweeping the decision store. Periodic monitoring remains
necessary for runtime health, but it is not a parallel decision-discovery
mechanism. The listener runs on every run, so `LISTENER absent` is always a fault, not a
mode. Verify it is live with `aiur status` (`LISTENER present (executor.#)`) and report the subscription to the human at launch ("Listening
for Executor events on `executor.#`."), and again if it is later confirmed dead
or restarted.

Evaluate each Command in its current run, ticket, and decision-history context.
This is a judgment call, not a rules engine: do not encode a table of command
types that may be answered automatically. A direct answer is appropriate when
it repeats a settled answer, follows from an established fact, or chooses an
obvious reversible operation already inside the authority envelope. Submit it
only through the `executor-answer` command so the durable answer actor is the
Executor, not the operator. The dashboard must expose that attribution and
history so the operator can find, revise, or supersede every Executor-made
decision later; explanatory prose is not a substitute for actor attribution.
Pass the event's current decision version, exactly one option or custom answer,
a rationale, and an idempotency key. Use a stable `--executor-id` for the run
when available (the CLI otherwise records `aiur-cli`), so replay stays
idempotent and stale events cannot overwrite a later answer.

If the Command is uncertain, irreversible, changes feature scope or product
direction, exceeds the authority envelope, or requires the Executor to guess,
do not answer it. Use the `executor-escalate` command to invoke the existing
operator-notification path with the concrete question and uncertainty, and
leave the decision open for the operator. Auto-answered Commands do not notify;
explicitly escalated Commands do. Escalation also carries the current decision
version and Executor identity, so stale escalation attempts are rejected and
the operator-facing alert remains attributable.

This judgement sits on top of a floor the store enforces, not in place of it.
`DecisionStore` refuses an Executor-attributed answer unless the Command itself
declares `authority: supervisor_allowed | supervisor_preferred` **and**
`reversibility: reversible`; anything else — `human_required`, irreversible or
partially reversible work — is rejected with
`{:executor_scope, …}` and must be escalated. (A request that omits those
fields is normalized to `supervisor_allowed` + `reversible`, so an omitted
declaration lands inside the floor rather than being refused; a genuinely
irreversible or operator-scoped Command carries its `human_required` /
non-reversible declaration explicitly.) Treat that rejection as the
Command telling you it was always the operator's. Escalations are appended to
the Decision's durable event log as an attributed `executor_escalated` event,
so "the Executor deferred to the human" is as recoverable later as "the
Executor decided".

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

A fleet-wide quiet board is a blockage, not idleness, and none of its causes
log anything. Clear the fleet-level gates before triaging any single agent: run
bare `aiurdev resume` first, because the global pause switch survives daemon
restarts and reboots while per-ticket `resume <id>` exits 0 with no effect;
check `agent.max_concurrent_agents` against the requested ceiling; confirm the
prewarm record `~/.aiur/repo/<owner>/<repo>/base-record.json` matches the
`latest` clone's HEAD and prewarm-script hash, since a failed base build holds
every dispatch tick silently (issue #1404); and allow for the post-restart
dispatch ramp.

Alerts persist across daemon restarts and tokens (#1231), so the actionable list
keeps naming long-merged tickets. Check alert timestamps and trust the live
state table over the alert list.

A `CHANGES_REQUESTED` review on an open PR moves its ticket to `agent:rework`
automatically — the `pull_request_review` webhook and the review-submission
poll route through `CommentWake`, so the manual `agent:human-review` to
`agent:rework` relabel is no longer required. After posting a review, verify
the ticket left `agent:human-review`; only relabel by hand when the automatic
transition did not fire, and check the delivery (review state, trusted author,
open PR) before doing so.

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
2. diff the pull request body's claims against the diff **first**. Any claim the
   diff does not support is a P1, never a nitpick; this is the most common
   defect class by a wide margin — a transport described as feature-complete
   whose `sendFeatureReport` unconditionally throws, a design document whose
   stated colour derivation is arithmetically impossible, a "fix" that never
   reads the config it claims to. Six of the nine pull requests rejected in the
   2026-07/08 run failed on exactly this, and every one of them would have
   merged on a skim. A body edited *down* toward a thinner diff is the same
   defect wearing a disguise: the capstone pull request was quietly retitled
   from "driven by live fleet state" to "runbook and evidence framework" and
   marked done while the page still rendered invented data;
3. answer two questions about every new test, in this order — **does this test
   execute at all**, and **would it still pass against a trivially wrong
   implementation?** The first is the one reviewers skip, and it is not cheap to
   skip: twenty tests sat outside the `vitest` include glob for 5.8 hours while
   their pull request read as fully tested, because a test the runner never
   collects reports no failure. Require the runner's own output naming the test
   file, not the file's existence in the tree. For the second, the real examples
   are `f(x) === f(x)` assertions, a test hand-poking the same
   `:persistent_term` the broken wiring should have set, and tests asserting
   against an inlined *copy* of the code under test that stayed green after the
   real code was deleted. On the same principle, the author-side rules that move
   these checks before review — the unknown-path, computed-age and collapsed-cause
   rules — live in the repo's `AGENTS.md` (`Tests must fail without the
   production change they guard` and `Computed ages and collapsed causes`);
   cross-reference those sections rather than restating them;
4. use `ce-code-review` when Compound Engineering is available, adding the
   relevant security, data, frontend, backend, or design lens for the change;
5. reconcile duplicates and contradictions, classifying each finding under the
   convergence policy before routing it;
6. return contained findings to the existing ticket as rework; create a new
   ticket only for an independent P0/P1 feature blocker;
7. confirm the event bus or tracker transition wakes the owning agent and that
   it acknowledges the rework. Submitting is not landing: re-read the observable
   state after every mutation — `reviewDecision` for the review itself, the
   label set for a transition, the thread's latest comment for a reply — because
   a verdict issued as a turn ends can be lost with the request still in flight
   and nothing reports the loss. Six review verdicts vanished this way in one
   run;
8. require the worker to restore the same branch-freshness and CI gate after
   fixes, rerun targeted review, then apply the recorded merge policy.

If tooling or an explicit resource limit prevents parallel review, record the
degraded review and compensate before merge. Do not equate green CI with
feature acceptance. The integration/capstone owner must still produce the
evidence named by the planning handoff.

## Merge mechanics

Branch protection measures the identity of the **pusher**, not the commit
author, and `require_last_push_approval` evaluates the last **reviewable** push.
The authenticating token determines the pusher; the URL username and commit
author do not. An inline helper is additive unless the helper list is reset, so
it can silently fall through to the Executor's cached `gh` credential. A
token-bearing URL is both unsafe and ineffective as an after-the-fact repair:
the #1401 experiment used the agent token, but pushed only tree-identical empty
commits, which did not replace the earlier human reviewable-push attribution.
Use the fail-closed recipe in `aiur-agent/dev-loop.md` from the first real push,
and open worker pull requests with the agent identity; GitHub counts the PR
**opener**, not the commit author, when deciding self-approval.

When required checks are green and a current CODEOWNER approval exists, but
GitHub still reports `mergeStateStatus: BLOCKED` and
`reviewDecision: REVIEW_REQUIRED`, do not spend another review or use
`--admin` as a diagnostic probe. After an ordinary merge/queue attempt produces
GitHub's generic policy error, fetch the read-only rule-suite evidence:

```bash
<loaded-aiur-run-skill>/scripts/diagnose-pr-merge-gate.sh <pr-number> <owner/repo>
```

The rule-suite endpoint requires repository Administration: read. The helper
uses `AIUR_CI_READINESS_TOKEN` when present, otherwise the operator's `gh`
keyring with `GITHUB_TOKEN`/`GH_TOKEN` overrides removed; it never gives that
authority to the daemon or worker token. It correlates the failed suite to the
pull request's generated merge commit and prints GitHub's exact active-rule
`details`. When it succeeds, immediately emit an Executor-facing alert with
that output verbatim:

```text
emit_alert(
  name: "merge.rule-violation",
  message: <exact diagnostic output>,
  reason: "PR #N is green and approved but GitHub still blocks the merge",
  needs_attention: true,
  severity: "critical"
)
```

If no suite matches, report that the exact diagnostic is unavailable; do not
invent a GitHub message. The normal attempt is what creates the failed suite,
so this path surfaces the reason immediately after the first refusal instead of
requiring a second `--admin` attempt.

The declaration requires every blocking CI job as required status checks,
including `build`, `test`, and `workflow security`, with strict status checks
enabled, and the gate is enforced once that declaration is applied to the live
ruleset. The CI `merge ruleset drift` check verifies the live ruleset against
that declaration on every PR and merge, so a regressed gate fails CI visibly.
The Executor must wait for the required checks and the review conditions before
merging; never merge a pending, failing, or stale head.

A solo operator cannot merge a branch they authored through the gate
(issue #1437). This used to bite hardest on the periodic `develop` -> `main`
promotion; that promotion is retired now that `main` is the single base branch,
but the rule still governs any Executor-authored branch.
With a two-owner CODEOWNERS entry plus `require_code_owner_review`
and `require_last_push_approval`, the only in-gate path is a bot approval, which
defeats the gate; `--admin` does not bypass it. Any approved maintenance window
must change only the review-side rules while leaving the required-status-check
rule active. Back up and re-read the ruleset to confirm the review-side change
rather than trusting the write.

## Ticket close-out

Before closing a ticket, grep the codebase for deferred-work markers naming it:

```bash
git grep -n "Follow-up (#<N>)"
```

`Follow-up (#<N>)` is the house convention because `credo --strict` in
`make lint` forbids `TODO` tags — the codebase has zero of them, so these
markers are the only greppable record of work a ticket knowingly deferred. When
one still names the ticket being closed, resolve it first: either the deferred
work lands, or the marker is re-pointed at a successor ticket that is open.
**Never close a ticket while live markers still name it.**

The 2026-07/08 analytics-streamdeck run shows the cost. `streamdeck_live.ex`
carried `Follow-up (#1350)` on a hardcoded fixture, `preview_key_descriptors/0`,
which #1350's key-content model was meant to replace. #1350 closed; nobody wired
it. Two days later the build order's capstone proof (#1358) failed: it required
the emulator be "driven by live fleet state", and that was structurally
impossible because the page still rendered invented data with no PubSub
subscribe and no `handle_info/2`. The marker was correct, greppable, and named
the exact ticket — there was simply no check that read it.

The reviewer's tell arrived before the proof did: the capstone PR title had
drifted from "driven by live fleet state" to "runbook and evidence framework".
When a proof ticket's title slides from proving behavior to documenting it, the
behavior is usually still missing.

## Hourly meta-analysis

The wake/outcome retrospective tunes monitoring cadence; this practice tunes
the run. Every hour (established on the 2026-07 analytics-streamdeck run,
where it repeatedly paid for itself):

1. **Name THE single thing currently costing the most wall-clock**, quantified:
   minutes lost, CI cycles burned, agents idle. Breadth summaries are
   explicitly not the deliverable; the organizing question is "what is the
   latest thing taking the most time, and how do we shrink it?" There is
   always a next bottleneck — this check is never complete. When one falls,
   the next entry names its successor.
2. **Classify recurring problems, not incidents.** Ask what CLASS of failure
   recurred this hour. Known classes worth pattern-matching against:
   - silent failure with a misleading symptom — seven distinct faults in one
     run all presented as "the fleet is idle" and none logged a reason;
   - PR bodies claiming more than the diff delivers;
   - tests that cannot fail;
   - flaky-test families sharing one mechanism: shared globals, leaked
     persistent state, silently-failed cache invalidation;
   - identity/gate mechanics: pusher vs author, opener vs committer.
3. **Reflect the pattern into higher-level solution tickets.** When the same
   class recurs — rule of thumb: 3+ reproductions, or 2 with a shared root
   cause — file ONE systemic ticket attacking the class rather than continuing
   to patch instances: a consolidated test-isolation refactor instead of
   per-test fixes, a shared-helper hardening instead of per-file migrations,
   an alerting gap instead of another manual check. Record in the ticket the
   reproductions that justify it. File at most 1-2 evidence-backed systemic
   tickets per pattern, and never expand the active feature boundary with
   them — process/infra tickets ride alongside the build order; feature
   tickets need operator sign-off.
4. **Write and file the entry** in the repository state node. The narrative
   retrospective is `~/.aiur/repo/<owner>/<repo>/meta/retros/<boot-id>.md`;
   each actionable item is an append-only `meta/findings.ndjson` record with a
   reusable slug, evidence references, and its filed ticket (or `ticket: null`).
   Write it only through `aiurdev findings --record '<json>' --repo
   <owner>/<repo>` so schema validation and the atomic size cap cannot be
   bypassed.
   `aiur init` creates the tree and `aiurdev findings --unfiled` makes a missing
   ticket visible before a retrospective can be treated as complete. Raw records
   remain host-local; periodically run `mkdir -p docs/executor && aiurdev
   findings --digest > docs/executor/open-findings.md`, inspect the regenerated
   file, and commit it. That generated digest is the deliberate git channel
   between machines, not a sync of host paths or boot IDs.

   The ledger contains one JSON object per line, hard-capped at 4 KiB so
   `O_APPEND` remains atomic when two Executor instances share a host. Cite
   evidence by reference - an issue number or a log path plus line - never a
   pasted log dump.

   ```json
   {"slug":"vitest-glob-excludes-tests","observed_at":"2026-08-01T18:04:00Z","scope":"repo","observed_in":"aiur-team/aiur","instance":"executor-1","summary":"20 tests outside the configured vitest include glob never ran","evidence":["#1442","~/.aiur/logs/agent-1442.log:8812"],"cost":"5.8h","ticket":1451,"status":"filed"}
   ```

   `slug` is a reusable kebab join key, so repeated observations group into a
   recurrence count. `scope` is `aiur` when the finding reproduces on any
   repository and `repo` when it names this repository's tests, CI, or code.
   `status` moves `open` -> `filed` -> `resolved`. A record left at
   `ticket: null` remains visible to the unfiled gate; it is not an accepted
   completed finding.
5. **Daily**, review the accumulated hourly notes and ask whether any Aiur
   skill should change so the next run never rediscovers the lesson. Capture
   that as a concrete skill-doc edit and land it as a small PR.

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
