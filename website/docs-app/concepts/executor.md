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
| [Dashboard](/guide/executor-control-center) | Browser fleet, Commands, Build Orders, analytics, and meters. |
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
