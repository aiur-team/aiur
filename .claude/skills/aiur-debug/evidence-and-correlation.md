# Evidence and correlation

Start with the smallest preserved evidence bundle that can classify the
symptom. Paths below are repository-relative or derived from the active config,
launcher identity, and tracker; placeholders are values you record, not fixed
machine locations.

## Establish the investigation identity

From the operator checkout, capture these read-only facts before inspecting a
ticket workspace:

```bash
git rev-parse --show-toplevel
git branch --show-current
git rev-parse HEAD
git merge-base HEAD origin/main
git status --short
scripts/aiurdev __identity
scripts/aiurdev status
```

Then read config discovery in the documented order:
`./.aiur/config` -> `./.aiurconfig` -> the user config locations. Record the
path actually selected, its `tracker`, `tracker.base_branch`, label prefix,
active-state **slugs**, `workspace.root`, `server`, `agent`, and
`observability` values. Resolve relative `prompt_file` and `hooks_file` from
the config directory. Do not paste secrets or the full config into a report.

`scripts/aiurdev __identity` reports the project root, root source, instance
key, release directory, BEAM node, and state directory without starting Aiur.
The instance key is a short hash of the canonical project root. It is an
identity join key, not a secret and not a globally unique run ID.

### Release provenance caveat

`git rev-parse HEAD` proves the checkout SHA, not automatically the SHA from
which an already-built release was produced. Record the release directory,
binary/build timestamps, launcher rebuild decision, and checkout SHA. If no
release manifest records a source SHA, report release SHA as **unknown** rather
than equating it with the current checkout. A forced `aiurdev build` changes
evidence and belongs after classification, not initial triage.

## Evidence map

| Source | Portable location / read-only access | What it proves | What it does not prove |
|---|---|---|---|
| Operator checkout | repository root; Git commands above | current files, branch, HEAD, base relationship, dirty state | the running release uses this tree; the ticket workspace matches it |
| Active config/workflow | detected config path and resolved sibling prompt/hooks | intended tracker, base, labels, workspace, limits, bind/auth settings | the daemon loaded the latest bytes; external tracker state agrees |
| Launcher identity/state | `scripts/aiurdev __identity`, `status`, instance record under the reported state root | computed project root, instance key, node name, recorded tmux identity, control-plane observation | BEAM, tmux, and record all agree without cross-checks |
| Startup output | configured run root `log/boot.out.log`; foreground wrapper capture; `erl_crash.dump`; reported temporary startup/pid/workspace-root artifacts while present | launcher command path, boot output, crash marker/dump, registered child IDs | application supervision stayed healthy after boot |
| Runtime application log | configured session logs root `log/aiur.log`, only when debug is enabled | timestamped Aiur/OTP lifecycle and errors for that run | UI rendering, tracker truth, or provider intent by itself |
| Historical/rotated runtime logs | sibling `aiur.log*` files in older run roots or externally rotated archives | older evidence when its run identity/time matches | that Aiur currently performs internal rotation; current `Aiur.LogFile` does not |
| Per-ticket transcript/event log | configured log directory's repository/ticket-prefixed log from `Aiur.IssueLog` | transcript and alert stream projected to the OpenCode pane, plus recorded Aiur event markers, even without debug | complete raw child stdout/stderr, every provider/Aiur event, process resource use, or what rendered without matching pane evidence |
| Workspace transcript/event projection | `<workspace>/logs/agent.ndjson` with the human-readable `<workspace>/logs/agent.md` projection | agent transcript, alert, and Aiur-event records passed to `Aiur.AgentEventLog`, including usage/rate-limit or crash reasons when recorded | complete raw child stdout/stderr, events never passed to the writer, host process state, or what a human saw in a TUI pane |
| Workspace transcript | `<workspace>/logs/agent.md` | human-readable projection and resume/workpad-adjacent chronology | complete structured fields when projection omits them |
| Debug chat recording | run log root `log/record/chat.<ticket>.ansi` under `--debug` foreground recording | stitched rendered OpenCode chat viewport over time | hidden state outside the pane or events that never rendered |
| Debug run telemetry | configured run root `log/telemetry.ndjson`, beside `log/aiur.log`; written only when debug is enabled | append-only, boot/sequence-keyed daemon restarts, sanitized lifecycle boundaries, external anchors, and periodic mutually exclusive daemon/ticket/operator process-tree samples with resource warnings | prompts, command text/output, raw child stdout/stderr, unsampled spikes, remote-worker resources, or correct ticket attribution when roots/fields are unavailable |
| tmux | socket/session from launcher/instance record; `tmux -L "$SOCKET" list-panes -a`, `capture-pane` | actual session/pane existence, pane PID/title, rendered bytes | BEAM control state or tracker truth |
| BEAM/control RPC | `scripts/aiurdev status`, `agents`, `watch --full`; node from identity/record | whether the targeted control plane answers and its in-memory snapshot | that a stale tmux pane or external tracker agrees |
| Tracker issue | `gh issue view "$TICKET" --json labels,comments,state,url` plus dependency APIs when relevant | current labels/comments/state returned by GitHub | what a prior poll observed or whether delivery reached an agent |
| Native blockers/parents | GitHub issue dependency/parent relationships, not prose alone | authoritative dependency graph | that a similarly worded workpad note created a native blocker |
| Workpad | the single `## Agent Workpad` issue comment | agent-recorded plan, validation, decisions, and handoff | runtime truth without matching logs/SHAs |
| Pull request | `gh pr view ... --json headRefName,headRefOid,baseRefName,baseRefOid,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup` | current refs, SHAs, review/check and mergeability snapshot | future mergeability or local workspace contents |
| Provider lifecycle | correlated records in `agent.ndjson`, runtime log, provider transcript/session store, and provider-native diagnostics | start/resume/thread/turn/result/rate-limit lifecycle for that provider | Aiur dispatch duplication unless joined to worker generation/session |
| Process tree | recorded app-server PID/process-group ID plus `ps`/`pgrep`/`lsof` scoped to it and workspace; record whether observation is from the issue sandbox or host/operator context | lineage, children, and FD/resource ownership visible in that process namespace | sibling host processes hidden from an issue-agent sandbox; fleet-wide duplication; duplicate dispatch merely because there are multiple children |
| Alerts/decisions/events | workspace NDJSON, alert feed/control snapshot, decision audit, queue/delivery records, subscriptions and event IDs | publication, persistence, queue claim, attempt, acknowledgement, or resolution at each recorded boundary | an unrecorded next boundary; publication is not delivery |

Search the current and any externally rotated runtime logs together, after
deriving `LOGS_ROOT` from the active session/config:

```bash
rg -n --glob 'aiur.log*' '<ticket|session|event|error>' "$LOGS_ROOT"
```

Keep the run-root/instance join in the result; a matching line in an older
archive does not describe the current run merely because the ticket matches.

For debug telemetry, join records by `boot_id`, `sequence`, `timestamp`, actor,
ticket, and lifecycle `attempt_id`/`operation_id` where present. Check
`availability`, `unavailable_reason`, `partial_fields`, `root_pids`, and warning
records before trusting an aggregate. Samples are derived from the daemon's
visible `/proc` namespace and registered process roots: an unavailable or
remote actor is not a zero, and a sampled ticket aggregate does not identify an
exact command without the matching lifecycle/provider IDs.

## Reading ANSI chat recordings

Keep the original file intact. Produce a disposable plain view with:

```bash
sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$CHAT_RECORD"
rg -n '@@|→ tool_call|\$ ' "$CHAT_RECORD"
```

Glamour consumes a literal fenced `diff` marker during rendering. A rendered
edit is evidenced by `@@` hunk headers and ANSI-colored `+`/`-` lines, not by a
literal fence. A chat recording proves user-visible rendering; use the real TUI
recipe in `AGENTS.md` when acceptance depends on user interaction. Logs or SSE
events are not substitutes.

## Correlation hierarchy

Join from broad identity to narrow invocation. Never skip directly from a PID
or error string to an Aiur defect classification.

Process evidence is namespace-scoped. An issue-agent sandbox may see only its
own process namespace and falsely report that no sibling host processes exist.
Record the observation scope on every process census. Fleet-wide duplicate,
build, CPU, and FD diagnosis requires the operator context or another explicit
host-level capability; absence in a sandbox-local `ps` is not counter-evidence.

1. **Repository + ticket:** tracker repository/project identity and canonical
   issue ID/number. The displayed title or branch suffix is not sufficient.
2. **Run/session + instance:** configured log root/session directory,
   `AIUR_INSTANCE_KEY`, `AIUR_RELEASE_NODE`, tmux socket/session, config path,
   and launcher start timestamp.
3. **Worker/agent:** issue worker generation/restart count, backend/model,
   workspace, worker host, branch, HEAD, app-server PID and process-group ID.
4. **Provider execution:** provider thread/session ID -> turn ID -> item or
   tool-call ID. Preserve native IDs rather than synthesizing one ambiguous
   `session_id` when finer fields exist.
5. **Repository delivery:** workspace branch/commit -> PR number -> PR head SHA,
   base branch/base SHA -> review/check results.
6. **Event delivery:** event ID, source ticket, full topic, source session and
   invocation/tool-call ID, causation/correlation metadata, publication result,
   subscription match, queue item/dedupe key, delivery attempt, acknowledgement,
   and terminal resolution.

Useful Codex payload fields include `threadId`, `turnId`, and `itemId` (or a
tool-call ID inside the item). Claude/provider adapters may use different field
names; retain both raw provider IDs and Aiur's normalized ticket/session fields.
Join a process with `agent_process_group_id` plus the app-server PID and
workspace before attributing children.

### Duplicate-command proof

Within one provider thread and turn:

```text
thread=T1 turn=R1 item=call-A command="mix test ..."
thread=T1 turn=R1 item=call-B command="mix test ..."
```

Distinct `item`/tool-call IDs prove the agent invoked the command twice. Aiur
delivered one turn; the model or agent workflow chose two calls.

By contrast:

```text
thread=T1 turn=R1 item=call-A event=E9 delivery_attempt=1
thread=T1 turn=R1 item=call-A event=E9 delivery_attempt=2
```

An identical item or event identity replayed at a later delivery boundary is a
different failure class: transport retry, queue reclaim, event replay, or
deduplication failure. Two different worker generations or two simultaneous
sessions for the same issue may indicate duplicate dispatch, but only after
the tracker candidate and orchestrator dispatch records are joined.

## Build one normalized timeline

1. Copy minimal relevant records to a scratch note without editing originals.
2. Record every source's clock basis. Durable JSON timestamps are UTC ISO-8601;
   launcher, tmux, `ps`, shell, and GitHub displays may use local time or only a
   relative age.
3. Convert local wall-clock observations to UTC using the recorded timezone and
   include the original value. Do not infer timezone from a hostname.
4. Sort by normalized UTC timestamp, then retain per-source sequence and IDs as
   tie-breakers. Millisecond ordering across hosts is not guaranteed.
5. Mark clock skew, buffering, logger flush, polling interval, GitHub eventual
   consistency, queueing, and retry backoff as uncertainty bands.
6. Annotate each row with repository/ticket, run/instance, session/turn/item,
   event/delivery, process, and SHA keys that are actually present.
7. Use causal boundaries, not timestamp proximity alone. A publish must precede
   its matching queue/delivery record by identity; two nearby unjoined lines do
   not establish causation.

Minimal shape:

| UTC | Source | Correlation | Observation | Authority / caveat |
|---|---|---|---|---|
| `...Z` | launcher | instance + node | boot command started | local output converted to UTC |
| `...Z` | runtime | ticket + generation | worker dispatched | authoritative Aiur dispatch record |
| `...Z` | agent NDJSON | thread + turn + item | provider tool call | authoritative provider invocation ID |
| `...Z` | GitHub | PR + head SHA | check completed | tracker snapshot; may trail webhook/poll |
