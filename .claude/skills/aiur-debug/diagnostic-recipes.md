# Bounded diagnostic recipes

Every recipe starts read-only. Use it to classify the owning layer, then hand
the evidence to `/debug`, optional `/ce-debug`, or a provider-native diagnostic
workflow. Do not keep expanding the search after a stopping condition is met.

## 1. Daemon down, startup failure, stale tmux/node, or RPC disagreement

**Read-only first**

```bash
scripts/aiurdev __identity
scripts/aiurdev status
tmux -L "$SOCKET" list-sessions
tmux -L "$SOCKET" list-panes -a -F '#{session_name} #{pane_id} #{pane_pid} #{pane_dead} #{pane_title}'
```

Read the instance record, `log/boot.out.log`, current run `log/aiur.log` (when
debug was enabled), crash marker/dump, launcher process, `epmd`/BEAM node, and
the exact control RPC error. Match instance key, node, socket, session, project
root, and log root.

**Classify / stop**

- No tmux, node, record, or status response plus a boot error: startup failure.
- Tmux exists but its recorded node is absent: stale tmux shell/session.
- Node answers at the recorded identity while `status` fails: control RPC or
  identity-adoption defect; preserve the raw RPC error.
- Current identity differs from the record: wrong checkout/config/root, not a
  daemon contradiction.
- `boot.out.log` shows dashboard refusal but `status` and agents answer: daemon
  is up; only the dashboard is down.

**Safest recovery escalation**

1. Correct the caller cwd/config/instance selection; retry read-only status.
2. Preserve boot/crash logs, instance record, pane capture, and process tree.
3. Stop only the matched instance with `scripts/aiurdev stop` (blast radius:
   its BEAM, tmux, agents, and sockets). Confirm the identity before doing so.
4. Relaunch only after the evidence bundle is durable. Host-wide kills or state
   directory deletion are last-resort operator actions, never initial triage.

## 2. Ticket not picked up

**Read-only first**

Read the detected config and tracker type, then fetch the issue's exact labels,
state, native blockers/parents, and workpad. Compare configured label prefix and
`tracker.active_states` **slugs** with the issue. Check `agent:paused`, base
branch/config discovery, tracker connectivity/poll timestamps, prewarm status,
slot capacity, per-state caps, CPU/load/memory/FD gates, and existing running or
queued entries through `scripts/aiurdev agents` or `watch --full`.

**Evidence needed**

- Config path + bytes relevant to tracker/base/active states.
- Current GitHub label slugs and dependency graph.
- Last successful candidate poll and any tracker error/backoff.
- Dispatch-policy reason: paused, blocked, non-active, at capacity, prewarming,
  load-held, model unavailable, already running, or terminal.

**Classify / stop**

- `agent:paused` coexists with an active label: expected suppressing override.
- Display name such as `In Progress` configured where GitHub emits
  `in-progress`: config/state drift.
- Non-terminal native blocker: expected dependency hold.
- Capacity/load/prewarm/poll backoff has not exceeded its bound: expected
  queueing.
- Tracker shows an eligible candidate and Aiur's successful post-change poll
  neither queues nor records an exclusion: orchestrator candidate/dispatch
  defect.

**Safest recovery escalation**

Wait one bounded poll when eventual consistency is plausible; correct config in
its owning ticket; remove only `agent:paused` when the operator intends resume;
resolve only the actual blocker; increase capacity only after resource evidence.
Relabeling can dispatch work and changing caps affects the fleet—preserve the
before-state and state that blast radius first.

## 3. Agent stuck, silent, retrying, duplicated, restarted, or wrongly routed

**Read-only first**

Join ticket -> worker generation -> backend/model -> workspace/branch/HEAD ->
thread/session -> turn -> item/tool-call -> app-server PID/process group. Read
`agents`, the ticket NDJSON/Markdown logs, runtime lifecycle/retry lines, pane
recording, queue state, provider session/resume state, and process tree.

**Evidence needed**

- Start/terminal/stall/retry records for every generation and retry budget.
- Provider model chosen and the config/label route that selected it.
- Separate tool-call IDs for commands; separate session/generation IDs for
  dispatches.
- Last safe checkpoint/activity and resource/build-gate state.

**Classify / stop**

- One session with distinct tool-call IDs: agent chose repeated work.
- Many children under one correlated process group: normal agent process tree
  until their command identities or generations prove otherwise.
- Same issue has overlapping generations/sessions without a terminal handoff:
  possible duplicate dispatch; require orchestrator dispatch records.
- A terminal generation followed by documented backoff/retry: expected retry.
- Backend/model/base matches route config but behavior is poor: agent/model
  choice, not routing.
- Correct provider events exist but pane is silent: transport/rendering layer.

**Safest recovery escalation**

Message or wait for a safe checkpoint first; pause the one ticket next; preserve
logs/transcript/process tree before interrupting; stop the matched process group
only when containment is required. Restarting an agent consumes retry budget and
may lose transient provider evidence. Restarting the daemon affects all agents.

## 4. Message, review, coordination event, attention, or decision not delivered

**Read-only first**

Identify source kind and immutable ID. Trace acceptance/publication -> persisted
record -> subscription/trust filter -> queue/dedupe key -> claim/delivery
attempt -> provider checkpoint/input -> acknowledgement/resolution. For review
comments, include PR/thread/comment IDs and CODEOWNER trust. For Decisions,
include `decision_id`, `action_id`, and `expected_version`.

**Evidence needed**

- Source event/comment/message ID and UTC timestamp.
- Full topic/source ticket/correlation, subscriber pattern, and trust result.
- Queue item status, delivery attempts, safe-checkpoint/immediate policy.
- Provider input or TUI evidence and durable acknowledgement lifecycle.

**Classify / stop**

- Accepted and queued but agent is mid-turn: expected queueing; `QUEUED` is not
  failed delivery.
- Published without a matching subscription: routing/config problem.
- Subscription and queue claim exist but provider input does not: delivery or
  app-server transport defect.
- Provider input exists but no reply: agent/provider behavior.
- Decision answer delivered but exact acknowledgement absent: incomplete
  lifecycle, not an unpublished decision.
- Same source/action replay returns duplicate without a second effect: expected
  idempotence.

**Safest recovery escalation**

Wait through the documented safe checkpoint; repair subscription/trust/config;
retry only with the same immutable correlation when the API is idempotent;
re-send a new operator message only after proving the first cannot deliver.
Do not resolve an attention or review thread merely to clear UI state; that
mutates audit/review truth.

## 5. PR missing, wrong-based, stale, conflicted, red, or green but unmergeable

**Read-only first**

Read workspace branch/HEAD, remote refs, `git merge-base`, workpad push/PR notes,
and GitHub PR `headRefName`, `headRefOid`, `baseRefName`, `baseRefOid`,
`mergeable`, `mergeStateStatus`, `reviewDecision`, and `statusCheckRollup`.
Match the PR head SHA to the pushed branch and the ticket.

**Classify / stop**

- No push/PR creation record and no remote head: agent workflow incomplete.
- Remote branch exists but no PR: push succeeded; PR creation/discovery failed.
- PR base name differs from requested base: PR metadata defect.
- Local merge-base predates current base: stale branch; green old checks do not
  prove current integration.
- Checks green but mergeable/conflict/review policy blocks: merge-policy state,
  not CI success.
- PR head differs from workspace HEAD: stale push or wrong workspace.

**Safest recovery escalation**

Preserve SHAs/check URLs; push the intended branch; create or retarget the PR
only with ticket authority; merge current base into the feature branch using
the repository workflow; resolve conflicts with focused tests; rerun CI.
Retargeting changes review/merge semantics, and force-pushing rewrites reviewer
context—avoid both when an ordinary merge/push suffices.

## 6. Duplicate commands/builds, Mix locks, fleet gates, or resource pressure

**Read-only first**

Read the current run's debug-only `log/telemetry.ndjson` before live process
sampling. Filter `resource`, `warning`, and `lifecycle` records for the matching
`boot_id`, UTC window, ticket/actor, attempt, and operation. Inspect sampled
CPU, RSS, I/O, process count, file descriptors/headroom, availability,
unavailable reasons, partial fields, root PIDs, lifecycle command class, and
resource-sampler warnings.

```bash
rg -n '"kind":"(resource|warning|lifecycle)"' "$LOGS_ROOT/log/telemetry.ndjson"
```

Telemetry is append-only and sanitized: it does not contain raw commands or
output, it can miss spikes between samples, and remote or unavailable roots are
not measured as zero. Its ticket trees come from registered process roots in
the daemon's visible process namespace, so require lifecycle/provider IDs
before attributing a sampled aggregate to an exact tool call.

Then correlate command lines to thread/turn/item IDs and worker generations.
Inspect the fleet `Aiur.BuildGate` status/owner PID/PGID and workspace lock
files. Only when telemetry is absent, unavailable, or too coarse, inspect live
parent process trees, per-process and system CPU, memory, file descriptors,
load gate, prewarm state, and external children. Use scoped `ps`, `pgrep`,
`lsof`, `/proc`, and `scripts/aiurdev agents`; do not start load generators.

Record the process observation scope.
An issue-agent sandbox can see only its own namespace and may hide sibling host
process groups, so a sandbox-local empty census does not rule out fleet
duplicates. Perform fleet-wide duplicate, build, CPU, and FD diagnosis from the
operator context or another host-level capability.

**Evidence needed**

- Distinct or identical tool-call IDs for each command.
- Telemetry `boot_id`/sequence/time window, actor availability, root PIDs,
  partial fields, warnings, and matching lifecycle attempt/operation IDs.
- Build-gate queue/owner and whether the owner PID/process group is alive.
- Lock path/owner, command cwd, and workspace.
- CPU headroom/load/memory/FD measurements over a short interval.
- Parent-child lineage and number of agent generations.
- Observation scope (`issue sandbox` or `host/operator`) for every process and
  resource census.

**Classify / stop**

- Distinct calls in one turn: repeated agent choice.
- Same call/event replayed: transport/replay/dedupe class.
- One tool call with several compiler/OS children: normal process fan-out.
- Different agents queued behind one live build-gate owner: expected fleet
  serialization.
- Dead owner with a persistent gate/lock: stale gate/lock defect.
- Admission held while host is above configured threshold: expected containment.
- Concurrent builds bypass a configured ready gate: build-gate integration
  defect.

**Safest recovery escalation**

Let a live owner finish; pause new dispatch; lower runtime agent capacity;
terminate only a proven runaway correlated process group; clear only a proven
stale lock after preserving owner metadata; restart the owning worker last.
Killing a process group affects all its child commands. Removing Mix/build-gate
locks can corrupt active work. Host-wide process kills are prohibited first-line
recovery.

## 7. Provider startup, resume, usage/rate limit, model route, or fallback

**Read-only first**

Identify backend adapter and configured/label-routed model. Trace app-server
spawn/PID/PGID, initialize handshake, thread create/resume result, turn ID,
provider terminal event, normalized usage/rate-limit event, model availability,
pause reason, retry decision, and fallback route. Use provider-native
diagnostics when advertised.

**Classify / stop**

- Spawn/handshake fails before a thread: provider startup/adapter layer.
- Requested resume ID rejected or absent: session-resume layer; do not call it a
  fresh Aiur dispatch without generation evidence.
- Provider reports usage exhaustion and Aiur pauses rather than retries:
  expected containment.
- Config route selected the observed model: routing is sound even if the model
  made a poor choice.
- Availability/fallback policy selects a different configured backend after a
  correlated provider limit: expected fallback.
- Provider says terminal success while Aiur retries the identical completed
  turn: possible lifecycle/retry defect.

**Safest recovery escalation**

Wait for a recorded reset; authenticate/repair the provider outside Aiur;
start a fresh session only after preserving resume IDs; change routing/fallback
only with scope authority. Repeated startup attempts can consume quota and
retry budget; deleting provider session state destroys resume evidence.

## 8. Dashboard/TUI disagreement, bind/auth/listener, LiveView, or API failure

**Read-only first**

Cross-check `status`/`watch`, configured host/port/writability, dashboard
credential **presence only**, runtime bind/refusal logs, listener ownership,
HTTP status/headers, LiveView connection/render, observability API response,
tmux pane state, and real user-visible TUI/browser evidence.

Never print credential values. A read-only non-loopback dashboard and every
writable dashboard require both auth variables; loopback read-only may start
without them. A busy port can disable only this instance's dashboard while
agents continue.

**Classify / stop**

- Control RPC works and log says credentials missing/non-loopback refusal: no
  listener by design; daemon is healthy.
- Control works and log says port in use: dashboard disabled for this instance.
- Listener accepts HTTP but LiveView fails: web/LiveView layer.
- API data is correct but TUI/browser rendering differs: presentation/transport
  layer.
- Logs say an event fired but the pane never renders it: not manually verified.

**Safest recovery escalation**

Use loopback; configure credentials without logging them; choose a free port;
restart only the affected instance after preserving logs/listeners; then verify
with the real browser or the canonical wrapper-tmux TUI recipe in `AGENTS.md`.
Changing bind widens network exposure; enabling writability expands mutation
authority; both require explicit operator intent.

## 9. Workspace bootstrap/reclone, `.git-writable`, remote/auth, or corruption

**Read-only first**

Resolve `workspace.root` and repository segment from config. Inspect workspace
existence, Git worktree validity, `.git` type/target, `.git-writable` only when
that workflow uses it, hook output, base marker/prewarm SHA, branch/HEAD/status,
remotes, fetch authentication, index/lock ownership, filesystem capacity, and
recent bootstrap/reclone logs.

**Classify / stop**

- Workspace is valid and hook guard skips reclone: expected reuse.
- Every retry reclones a valid worktree: `before_run` guard defect.
- Fetch cannot update metadata in a workflow that mounts `.git` read-only and
  expects `.git-writable`: bootstrap wiring defect.
- Remote URL/auth fails before checkout: repository/auth layer.
- Branch/HEAD differs from dispatch base after successful bootstrap: checkout
  or stale-base defect.
- Git reports corruption: repository evidence; do not call it an Aiur dispatch
  defect without bootstrap cause.

**Safest recovery escalation**

Preserve status, refs, reflog, remotes, hook output, and untracked work; repair
auth/remote; remove only a proven stale lock; repair `.git-writable` according
to the workflow; commit or copy irreplaceable work before reclone. Reclone
deletes the issue workspace and logs, so it is last resort. Never use a hard reset
as initial recovery.

## 10. Event publication, subscription, replay, dedupe, or state reconstruction

**Read-only first**

Load `/aiur-agent` for the current vocabulary. Trace event ID, source ticket,
topic, causation/correlation, source session/tool-call, publisher result,
persistent subscription pattern, exchange match, consumer intake, dedupe key,
queue state, delivery attempts, acknowledgement, and resolution. Read the
durable event/decision/subscription records and ticket NDJSON; treat UI feeds as
projections.

**Evidence needed**

- One immutable source event/action and every recorded boundary.
- Subscription version/pattern at publication time.
- Replay/dedup result and whether a side effect occurred twice.
- Queue delivery/ack state, including stale expected versions.

**Classify / stop**

- Publisher returned success but no matching subscription existed: expected no
  delivery or subscription configuration fault.
- Same immutable event is received twice and dedup suppresses the second side
  effect: expected replay handling.
- Same event/action causes two accepted queue items or side effects: genuine
  deduplication defect.
- Two different event IDs from distinct tool calls: agent published twice.
- Durable decision state rejects stale action/version: expected concurrency
  protection.
- Projection disagrees with durable audit: feed/reconstruction defect; rebuild
  truth from the audit, not the UI.

**Safest recovery escalation**

Repair the narrow subscription; retry idempotently with the original immutable
correlation; replay into a read-only reconstruction first; quarantine the one
consumer before fleet pause. Unsubscribing drops future delivery, replay can
duplicate side effects, deleting event/decision state destroys audit history,
and exchange-wide changes affect every ticket—state those blast radii before
mutation.
