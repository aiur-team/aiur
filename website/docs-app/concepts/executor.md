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

## Talk to the Executor from the dashboard

Attaching identifies your external session as this instance's Executor session.
Opt-in is separate from wake recording and `--executor` authority; no Remote Control is required.

From the repository root, with the dashboard listener running, choose one:

```bash
aiur executor-attach --harness claude
aiur executor-attach --harness codex
```

Claude attachment installs marked `AIUR_EXECUTOR_HOOK=1` hooks in
`.claude/settings.local.json`, preserving other settings and hooks. Use
`--print-config` to review the configuration without installing it.

Codex always prints configuration: merge it into `<repo>/.codex/hooks.json`, then
review and trust it in Codex's `/hooks` dialog.

Start or resume the selected
session and confirm its hooks are enabled. Keep local settings out of Git; see
[Generated hook settings](#generated-hook-settings) for backups and cleanup.

Attachment creates private hook token, header and URL files in the Executor
state directory (normally `~/.aiur/repo/<owner>/<repo>/executor/`). These let
hooks authenticate to this instance's loopback endpoint. Codex attachment does not
edit Codex configuration or grant trust.

**Privacy before opting in:** attachment authorizes Aiur to read the attached
session's transcript, including your messages, assistant replies, reasoning and
tool output. Unrelated sessions are not opted in.

When Executor conversation recording is available, Aiur copies entries into its local
[conversation journal](/concepts/conversations#where-transcripts-live), with
owner-only directories (`0700`) and files (`0600`).

Transcripts can contain
secrets; masking and collapsed or hidden content are not a privacy boundary.
There is no automatic pruning: retained entries stay until you delete them.

**Phone visibility:** paired phones and watches may read the Executor transcript
by default. D19 pairing grants full access; there is no separate Executor
transcript visibility toggle. Treat pairing a device as granting access to this
conversation, including sensitive content.

Attachment alone does not guarantee a dashboard transcript or message delivery.
Attach-only builds still report the Executor conversation as unavailable; the
transcript reader and dashboard integration must also be present.

Sending is
**disabled until delivery is installed** and the session is eligible. Where
available, listener modes govern when messages arrive: Steer at tool boundaries,
Sync at turn end or the next prompt, Async through explicit reads, and Mute
silently holds messages.

See [listener modes](/guide/gui#conversations) and
[hook delivery](#attached-session-lifecycle-hooks). An idle session is not woken
by a delivery hook, and queued does not mean read.

Use `aiur executor-session --json` for the binding, liveness, last-hook age and freshness.
`awaiting_first_hook` means waiting for the first hook, not proof of transcript recording.

Check enabled
hooks and Codex trust first. A missing dashboard listener blocks attachment;
an existing live binding requires CLI `--takeover`. Commands and fleet blockers
remain in the [Commands inbox](/concepts/commands).

To opt out, run `aiur executor-detach`. It ends the binding, rotates the hook
credential and removes marked Claude hooks, preserving user edits. Remove
manually merged Codex hooks yourself.

Detaching does not erase existing
journals, provider logs, binding records, token/URL files or private settings
backups.

To erase recorded text, stop Aiur and follow the
[conversation deletion steps](/concepts/conversations#retention-and-deletion);
provider logs and other copies require separate deletion. Remove unused Executor
state files or backups only after stopping the instance.

## Conversation privacy

Worker transcripts can contain secrets and remain on disk until deleted.
Attached Executor transcripts follow the opt-in and paired-device access contract
above, and use the same journal storage contract when integrated.
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

`POST /api/v1/executor/hook/deliver?harness=claude|codex` uses the same
credential and normalizer to deliver pending Executor messages at a hook boundary.
Only the attached provider session and harness can receive a batch.

A `200`
contains the JSON envelope to print verbatim to hook stdout; every other status
prints nothing (`204` means no delivery). Non-loopback delivery requests return
`403`; missing or incorrect credentials return `401`.

Sync delivers at `Stop` or the next `UserPromptSubmit`; steer also delivers at
`PostToolUse`. Async messages remain pull-only. `SessionStart`, subagent hooks,
and `Stop` with `stop_hook_active: true` never claim messages.

Batches preserve arrival order, with at most 50 messages and a 64 KiB rendered frame. Oversized
first bodies are truncated.

A claim records harness queueing, not consumption; failed rendering, expired deadlines, and failed HTTP writes leave messages
pending for retry. The request budget is 1.5 seconds. An idle session waits for
the next prompt; this endpoint does not wake it.

The loopback `remote_ip` check is defence in depth, not the boundary: a local
tunnel or reverse proxy that forwards remote traffic to `127.0.0.1` passes it.
The hook token is the boundary.

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

### Generated hook settings

The Executor hook generator installs Claude hooks in the repository's
`.claude/settings.local.json`. It preserves existing settings and hook order,
refuses invalid JSON or hook structures, and backs up each changed file under
the private per-repository Executor state directory at
`hook-settings/settings.local.json.aiur-bak-<timestamp>`.

The backup directory has mode `0700`; files have mode `0600`. Install and
uninstall migrate backups left in the working tree by older versions, removing
each old copy only after verifying its private copy.

Add `.claude/settings.local.json` itself to `.gitignore` or the repository's
local `.git/info/exclude`. Settings may contain environment values,
permissions and absolute hook paths; the backup is stored outside the working
tree and is not covered by this ignore rule.

Removing the integration removes only commands
starting with `AIUR_EXECUTOR_HOOK=1`, plus legacy delivery commands matching
`curl -sS -f -m 3` and `/api/v1/executor/hook/deliver` (including old ports).

If no settings changed since install,
uninstall restores the original file bytes from the private backup. Later user
edits are preserved, and the backup remains available for manual restoration.

An existing marked lifecycle command is preserved, including its paths.
Uninstall and reinstall the hooks to point them at another instance.

Codex configuration is printed for merging into `<repo>/.codex/hooks.json`.
Review and trust those hooks in Codex's `/hooks` dialog before using them;
the generator does not edit Codex settings or grant trust.

Generated commands read the instance's private `.executor.hook-url` file on each
invocation. The daemon rewrites that file after an HTTP bind, so a changed
port does not require reinstalling hooks.

Lifecycle commands send input to the loopback endpoint with the separate header
file, suppress output and bound curl to two seconds.

Delivery commands also run
on `PostToolUse`, `UserPromptSubmit` and `Stop`, with a ten-second hook timeout
and a three-second curl budget. They read the private token at invocation and
print the delivery envelope to stdout.

Both commands exit successfully when the
daemon is unavailable. User and Khala handlers remain in their original order.

Compatibility of two `Stop` hooks that both return `decision: "block"` has not
been verified in either harness. Treat that combination as unsupported until
both continuations have been observed in the real session.
