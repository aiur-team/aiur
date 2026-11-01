# Operating Aiur

## Operator surfaces

| Surface | Best for |
| --- | --- |
| [TUI](/guide/tui) | Foreground fleet board and live agent chat. |
| [GUI](/guide/gui) | Browser fleet, Commands, Build Orders, analytics, and meters. |
| [CLI](/reference/cli) | Agent-driven operation and terminal automation. |
| [Stream Deck](/guide/stream-deck) | Physical or browser fleet controls and event logs. |

[Capabilities](/concepts/capabilities) describes how clients discover available instance features.

## Listener modes

Listener modes control when a conversation message reaches an agent's session.

| Mode | Meaning |
| --- | --- |
| **Steer · interrupts** (`steer`) | Deliver at the earliest supported safe boundary inside the active turn; if idle, start a turn. |
| **Sync · next turn** (`sync`) | Hold during active work, then deliver at the turn boundary; if idle, start a turn unless an agent sent the input unaddressed. |
| **Async · pings only** (`async`) | Hold the body for agent pull; an addressed message sends a content-free nudge. |
| **Mute · silent** (`mute`) | Hold input silently, without waking the agent. |

Workers default to `sync`. Dashboard, Stream Deck, CLI, HTTP, voice, and TUI
conversation sends follow the effective mode. In Sync, dictation during active
work waits until the turn ends. Use the separate interrupt control for stuck
work; changing a mode does not change admission, trust, approval, or capacity.

Operator-paused workers stay paused until resumed. Sync and Steer input can
resume a worker that paused itself for input. In Sync, unaddressed agent
broadcasts wait for the next turn; actionable signals from declared blockers
still wake the agent.

Read or change a worker's preference with
[`aiur listen-mode`](/reference/cli-operations#inspect-and-operate-a-running-daemon):

```sh
aiur listen-mode 142 --json
aiur listen-mode 142 async --expected-version 0
```

Use the version returned by the read. A stale write returns the current record
and exits 3. Humans and the Executor may change worker modes; changes record
the actor. The preference belongs to the ticket run and survives respawn and
daemon restart. There is no global default-mode configuration key in v1.

The [dashboard drawer](/guide/gui) shows the selector and both requested and
effective modes when they differ. The [TUI](/guide/tui) has a read-only listener
column with the unread count; use the CLI to change its mode.

### Requested and effective mode

`requested` is the stored preference. `effective` follows the running harness
and installed tools: use the requested mode when supported, otherwise try
`sync`, then `async`, or report no effective mode. Mute remains mute.
An unusable listener specification refuses conversation sends.

Current harness support determines the projection.

| Running harness | Sync | Steer | Async |
| --- | --- | --- | --- |
| `codex` | Proven | Experimental native `turn/steer` | Proven with read tool installed |
| `claude` (headless) | Proven | Unsupported (`steer_not_wired`); falls back to Sync | Proven with read tool installed |
| `claude-repl` | Experimental | Experimental native pane input | Unsupported (`pull_tool_unavailable`); falls back to Sync |
| `muse` | Proven | Experimental native MSP steering | Proven with read tool installed |
| `kimi`, `deepseek`, `openrouter` | Proven | Unsupported (`no_interrupt`); falls back to Sync | Proven with read tool installed |

Support follows the running transport, including fallback from `claude-repl`
to headless `claude`. An older resumed Codex session can lack the read tool
even when a fresh session supports it.

`effective_reason` explains a downgrade. `not_running` or `harness_unknown`
means no effective mode is known; `pending_session_start` marks a projection
from dispatch facts before session startup. A native steer rejection can defer
the message to the next turn rather than cancel the active turn.

The interrupt carrier, when enabled, is labelled
**steer (interrupts current turn)**: it cancels the active turn and starts a new
one with the message. Current worker mode projection does not enable that
carrier. Explicit interrupt controls, including chat `Ctrl+C`, remain separate.

### Message scope and async reads

Conversation messages obey the mode. Command answers, orchestrator event
digests (reviews, CI, blockers), and pause, resume, interrupt, and stop controls
keep their own delivery policies.

With async effective, call `aiur_read_messages` after a nudge, at natural pauses,
and before yielding or finishing. It **consumes and acknowledges** held messages,
oldest first; it is not a preview. Check `remaining` and read further batches.
A lost reply after acknowledgement cannot be replayed.

See [held async and mute messages](/concepts/message-bus#held-async-and-mute-messages) for limits
and queue-lifetime details. Leaving Async or Mute for Sync or Steer sends a
notice while earlier bodies stay pull-only if async support remains usable.
If the pull tool becomes unavailable, held bodies follow the effective mode.

[`aiur executor-attach`](/reference/cli-decisions#decisions-executor-events-and-findings)
adds delivery hooks at prompt, tool, and Stop boundaries for the external
Executor session.

Claude installs them while preserving user hooks; Codex
prints configuration for an explicit merge and trust review, as described in
[generated hook settings](/concepts/executor#generated-hook-settings).

## Hosted execution safety

Set `instance.mode: hosted` only when every dispatchable backend has explicit,
safe permission, network, and credential boundaries. Aiur statically checks the
complete backend set and every registered agent-environment contributor before
starting supervision and again before dispatch after a config reload. Missing
or unknown declarations are unsafe.

Hosted mode also rejects Remote Control (`agent.remote_control`, `+remote`
routes, and `model:remote` labels), foreground tmux panes, tmux-backed REPL
agents, and the test harness's `--allow-remote` bypass.

Hosted mode requires bounded agent permissions, network access denied by
default, and credentials kept in trusted daemon-side components. Codex must
use an approval policy other than `never`, a bounded thread sandbox, and a
bounded per-turn sandbox with network access disabled.

Static startup, reload, and dispatch validation includes the effective fallback,
but does not inspect the current authentication of primary routes or configured
account profiles.

The first and every later trusted runtime observation must prove API-key
authentication. Subscription, OAuth, personal-token, header-derived,
agent-identity, Bedrock, missing, and unknown observations fail closed.

Claude reauthorizes the current observation before every tool call and successful
completion. Codex has no separate per-action authorization gate: an unsafe
initial account read refuses session startup, and a later unsafe account
notification stops the turn before subsequent progress, tool-call processing,
or successful completion.

Aiur records the provider and safe authentication class, moves the ticket to
`agent:error`, and does not retry that unsafe profile automatically.

Hosted mode also validates the effective usage-limit fallback. The local
default, `agent.rate_limit_fallback: claude`, is not statically API-key-only
and therefore makes a hosted configuration invalid. Set the fallback to `""`
to disable it, or select a registry backend whose account contract contains
only API-key modes.

The current production backends each expose at least one agent-side boundary,
so no production backend can pass hosted startup until the hosted-safe backend
work lands in #5701. Local mode remains the default and preserves existing
execution behavior without running hosted-only registry or
environment-contributor checks.

The mode is immutable for a running daemon. Editing `instance.mode` on reload
is rejected in either direction; restart Aiur to change it. A rejection lists
the backend or environment contributor and the unsafe boundary, never a secret
value.

## Hourly meta-check

`aiur-run` arms `aiur-meta` **before dispatching** and repeats it hourly.

The timer keeps the audit from being lost during a busy merge queue.

| Check | What it catches |
| --- | --- |
| Build home, Units, Commands, Build Orders, Analytics | Confident but incorrect operator projections and stalled work. |
| Interactive CLI timing | Empty or timed-out responses hidden by static status. |
| Host pressure | CPU PSI and free memory against configured admission thresholds; load is the PSI-unavailable fallback. |
| PR backlog | Review, conflict, and merge-queue snags. |
| Bottleneck choice | The single largest current wall-clock constraint. |

The check records what an operator can actually see and treats an empty or timed-out surface as a finding.

After each check, inspect its durable follow-up with `aiur findings`.

| Action | Command or location |
| --- | --- |
| Find unfiled records | `aiur findings --unfiled` |
| Record a finding | `aiur findings --record '<json>' --repo <owner>/<repo>` |
| Read the boot retrospective | `~/.aiur/repo/<owner>/<repo>/meta/retros/<boot-id>.md` |
| Read Build Order handoff rules | [Build Orders](/concepts/build-orders#executor-handoff-and-findings) |

## Alerts

| Source | Behavior |
| --- | --- |
| `.aiur/alerts` | Maps event-topic patterns to messages and optional sounds. |
| `emit_alert` | Lets agents raise milestone alerts for the Executor. |
| Dashboard and TUI | Show active attention and failure states. |
| Completed BEAM crash dump | An unexpected daemon exit raises a `system.beam.crash_dump` needs-attention alert carrying the bounded dump slogan. |

An idle ticket absent from the active poll is retained for at most five unresolved refresh attempts. Then `ticket.<id>.terminal_verification_abandoned` raises one attention with its identifier and cause. A returned ticket resets the counter; deferred batches and in-flight reads do not consume attempts. Restart resets these in-memory counters.

Automatic fallback label writes back off per ticket from one dispatch poll, doubling up to ten minutes. Other tickets remain eligible. The third consecutive failure raises `rate_limit_fallback_write_failed` once; a successful write clears the backoff. Backoff is in memory and resets on restart.

### Retrospective daemon heartbeat gaps

At Executor startup, Aiur compares the last heartbeat with its lifecycle
journal. A stale heartbeat beyond `monitoring.daemon_heartbeat_stale_ms` creates
an informational `system.daemon.gap` event. It reports `clean_shutdown` when
the latest journal event is a stop, and `unknown` after an unmatched start.

Missing heartbeat files are ignored; they may mean first boot or a changed
state directory. The notice describes a past interval and opens no attention.

This is retrospective reporting, not live monitoring. It appears at the next
Executor startup. Use an external service monitor for immediate outage alerts.

Background runs write the daemon dump beneath the durable run-log root by
default. Operators may override its location with `ERL_CRASH_DUMP` and bound
the write with `ERL_CRASH_DUMP_SECONDS`; Aiur removes both variables from agent
and build children so only the daemon owns that evidence.

## Usage and account meters

Aiur keeps unknown and partial pricing explicit instead of turning missing evidence into zero.

| Provider family | Meter meaning |
| --- | --- |
| Codex and Claude | Percentage used in renewing allotment windows. |
| Muse | Current and weekly allowance percentages from the most-constrained active native host, with reset times and observation age; account identity is unverified. |
| DeepSeek and OpenRouter | Prepaid dollar or credit balance. |
| DeepSeek percentage | Spend against a durable prepaid-balance baseline, not a provider quota. |
| DeepSeek concurrency | Process-local; shown in live CLI and TUI status, omitted from retained provider cards. |
| Kimi | Session observations only; no account-balance probe. |
| GitHub | Core REST and GraphQL percentage used. |
| ElevenLabs | Account credit quota as percentage used. |

Dashboard provider meters render the values as last read. Claude shows a named weekly bar per account.

Its CLI and Stream Deck summary uses the account with the highest weekly percentage used (or highest reported window when weekly usage is absent), labelled “worst of N accounts”.

If an account could not be read, the summary names the selected account and the observed account count instead; missing readings remain unknown. Observation ages remain attached to the actual readings.

Use `aiur usage` for session-observed model headroom; see [GitHub](/apis/github) and [ElevenLabs](/apis/elevenlabs) for non-model API meaning.

## Pause and capacity

| Control | Scope |
| --- | --- |
| Space in TUI | Pause or resume the selected ticket. |
| `aiur pause` / `aiur resume` | Durable global provisioning switch. |
| Dashboard sidebar pause | The same durable global switch. |
| `--pause` | Start a run globally paused. |
| Arrow keys / `aiur set max-agents N` | Change the live concurrency cap. |
| `aiur status` | Show the capacity bound currently limiting the fleet. |

A restart that cannot read persisted global-pause state starts paused rather than releasing work.

After 60 seconds, an unowned `in-progress` ticket goes to `todo` without a PR,
`rework` for conflicts or findings, and `human-review` otherwise. Mergeable
stale PRs stay reviewable; overlap alone creates no rework. In `human-review`
and `ci-wait`, update the base only for GitHub `CONFLICTING` or reviewer
request. The queue tests the current base.

A never-reviewed PR goes to `human-review`. A conflicting PR goes to `rework`
so its conflict can be resolved before review.

Live workspace leases, scheduled retries, `agent:paused` and `agent:parked`
protect the claim; unavailable PR evidence retains it for later polls. Budget-held writes
retry on later polls without consuming the three-attempt limit.

Other failed writes raise an attention. Exhausting three attempts raises an explicit
Executor attention and retains the claim until intervention or a new daemon boot.

## Remote control

| Control | Behavior |
| --- | --- |
| `model:remote` label | Starts an agent with remote control. |
| `r` key | Promotes the selected compatible agent. |
| Chat pane | Sends Executor text into the live session. |

Remote control is opt-in per agent and local-only in v1.

## Remote control calls

POST `/api/v1/control` runs allowlisted literal calls with a `Bearer` token and
returns local `aiur` output. Writes need a `write` token and `max_scope: write`;
results include instance and build identity. The body limit is 65,536 bytes;
the daemon records writes and refusals in `control-audit.ndjson`.

A `write` token grants close to full control of that instance. It can message
agents, and an agent with a shell can turn a message into code execution. Keep
write tokens in an environment variable outside agent workspaces. Read tokens
may be stored in files readable only by their owner (`0600`).


## Capability report

The read-only capability report describes the current instance without changing any
operation's gates; providers read runtime evidence independently, so registration
order does not change the result.

| Capability | Meaning |
| --- | --- |
| `api.http` | The HTTP listener is bound. A no-dashboard run reports `not_installed`; an unbound listener reports `not_running`. |
| `orchestration` | The orchestrator is running and its snapshot is current. An unpublished or stale snapshot is degraded; a dead process is unavailable even with a cached snapshot. |
| `instance.status` | Status is available when orchestration is available; otherwise it is degraded. |
| `agents.run` | Agents can run while orchestration exists, including with a degraded snapshot. Global pause remains run state. |
| `agents.message` | HTTP and orchestration exist and dashboard writes are enabled. |
| `commands.read` | The Command store and HTTP are available. |
| `commands.answer` | Commands can be answered with dashboard writes enabled. With orchestration down, answers can be recorded but delivery is degraded. Available answers advertise version 1. |
| `commands.supervisor_api` | A valid Supervisor token is configured and HTTP is available. The token is never reported. |
| `tracker.github`, `tracker.linear` | The matching tracker is configured. This does not claim upstream connectivity. |
| `build_orders` | GitHub Build Order catalog projection is running and healthy. Other trackers report `unsupported_tracker`; unhealthy catalogs are degraded with their observation time. |
| `build_orders.progress` | A healthy catalog contains a root. No root reports `not_configured`, with no numeric progress value. |
| `voice.stt`, `voice.tts` | HTTP and an ElevenLabs key are configured; TTS also requires a voice ID. Unreadable settings report unknown. |
| `streamdeck` | HTTP and dashboard credentials are configured. The daemon cannot observe whether the sidecar is installed or connected. |
| `webhook_ingress` | The configured repository has proven webhook delivery. Unproven delivery is degraded/unknown; degraded delivery reports `not_running`; unconfigured ingress is unavailable. |
| `remote_control` | Remote Control is enabled in agent configuration or a `+remote` route, and HTTP is bound. Otherwise it reports `disabled` or an unavailable HTTP dependency. |
| `accounting.meters` | The meter projection is running and at least one provider API or management key is configured. Credential presence does not prove upstream connectivity. |
| `conversations.read` | HTTP is bound. A missing live conversation process is degraded because disk history remains readable. |
| `executor.wakes` | The Executor wake inbox is running. |
| `executor.conversation` | Links to `/executor`; reports `executor_not_managed` until managed conversation support is installed. |

Unavailable dependencies carry their capability IDs in `depends_on`. When settings
cannot be read, writable-gated operations report `unknown/unknown` rather than assume
writes are enabled. Invalid Supervisor credentials also report unknown (normal
startup rejects them).

The `repository` section names the configured GitHub owner/repository or Linear
slug (with a null owner); failed identity reads produce null. The `executor` section
preserves the owner's roster state and consumer ID without recording an observation.

Only `active` and `idle` represent a live Executor. Missing claims report `absent`,
only expired claims report `expired`, and failed reads report `unknown`.
