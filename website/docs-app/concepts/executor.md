# Executor

The Executor is the role that runs Aiur, assigns tickets, and tracks progress.

## Who drives

| Driver | How the role works |
| --- | --- |
| Human | Launches Aiur, reads the TUI or Dashboard, and answers agent Commands. |
| Designated agent | Drives the same run through the CLI and Dashboard on the human's behalf. |

Even when a human drives, a second agent is recommended for log analysis, snag detection, blockers, and background issues.

## Executor surfaces

| Surface | Purpose |
| --- | --- |
| [TUI](/guide/tui) | Foreground fleet and live chats. |
| [CLI](/reference/cli) | Agent-oriented run control; parity with interactive surfaces is the design target. |
| [GUI](/guide/gui) | Browser fleet, Commands, Build Orders, analytics, and meters. |
| [Stream Deck](/guide/stream-deck) | Physical or browser controls and event logs. |
| [Message Bus](/concepts/message-bus) | Agent coordination, Commands, blockers, and attentions. |

## Keeping tickets moving

| Responsibility | Operator action |
| --- | --- |
| Supply work | Apply `agent:todo` to dispatchable tickets. |
| Watch flow | Read [How a ticket flows](/concepts/ticket-lifecycle). |
| Resolve snags | Answer or defer [Commands](/concepts/commands). |
| Protect capacity | Pause work or change the live agent cap. |
| Finish safely | Keep CI, review, and merge gates moving without self-merging agent work. |

## Acknowledge before investigating

When a designated Executor takes a Command, it records
`aiur executor-ack <decision-id>` before investigating. Reading the Command or
receiving a wake does not acknowledge it. Repeated acknowledgements are safe.
Acknowledgement means “seen”, not “answered” or “resolved”.

By default, an Executor has five minutes to acknowledge and fifteen minutes from
routing to answer. Acknowledgement removes only the acknowledgement deadline.
Urgent blocking Commands halve both deadlines.

Missing a deadline, going offline
or stalling routes the question to the human; acknowledging after escalation
does not take it back. The Executor may still answer only within its authority,
and cannot replace a direct or relayed human answer.

See [Command routing](/concepts/commands#when-a-command-becomes-yours), the
[deadline configuration](/reference/configuration-daemon#decisions) and
[Executor CLI actions](/reference/cli-decisions).

## Asking the human

A designated Executor can ask the human with `aiur command request 'Ship today?'
--option yes=Ship --option no=Wait`. When the human answers, the durable Executor
journal delivers an `executor.decision.answered` wake on the next
`aiur executor-wait --json`, including after a listener restart.

The wake carries
the `decision_id`; read the answer with `aiur commands <decision_id> --json`.
An Executor request's optional ticket context never routes its answer to a worker.
Once the wake is enqueued, the answer counts as delivered and cannot be superseded.

## Conversation privacy

Worker transcripts can contain secrets and remain on disk until deleted.
The Executor journal identity follows the same storage contract when integrated.
See [Conversations](/concepts/conversations) for storage paths, retention,
masking limits and deletion steps.

### Attached-session lifecycle hooks

`POST /api/v1/executor/hook?harness=claude|codex` accepts lifecycle events for an
explicitly attached Executor session. It requires a loopback connection (IPv4
or IPv6) and the instance's dedicated hook bearer credential; dashboard login
and dashboard write permissions do not grant hook access.

The endpoint remains
available with a read-only dashboard.

Authenticated POSTs return `202` before
asynchronous validation and binding updates; a `202` does not mean an event was
accepted. Other authenticated methods return `405`.

The daemon's `Aiur.Executor.HookToken.ensure/0` creates an instance-scoped
`.executor.hook-token` and `.executor.hook-headers` pair in its Executor state
directory, with mode `0600` (directory `0700`).

Hook commands use
`curl -H @<headers-file>` to keep the bearer out of command arguments.
`rotate/0` revokes the previous credential; `ensure/0` repairs the header file
from the current token.

Each file replacement is atomic; rotation of the pair
can briefly reject a concurrent hook.

The harness is read only from the URL query. Unknown payload fields are dropped,
strings are bounded, and transcript paths must identify an owned regular file
under `~/.claude/projects/` or `~/.codex/sessions/` with the matching session
filename; symlinks and traversal are refused.

Claude subagents require `<session_id>/subagents/agent-<agent_id>.jsonl`.
The Codex agent filename rule remains provisional until a real CLI capture
confirms it.
Rejected paths become `nil`. Unattached sessions, foreign sessions and events
beyond 50 per second per binding are dropped.

A nil or rejected path preserves an existing locator for the same session;
a new session never inherits it.

Accepted events publish on the
internal `executor_hook` topic; rejection counts use
`[:aiur, :executor, :hook]` telemetry without recording payload content.
