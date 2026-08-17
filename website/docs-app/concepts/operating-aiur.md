# Operating Aiur

## Operator surfaces

| Surface | Best for |
| --- | --- |
| [TUI](/guide/tui) | Foreground fleet board and live agent chat. |
| [Dashboard](/guide/executor-control-center) | Browser fleet, Commands, Build Orders, analytics, and meters. |
| [CLI](/reference/cli) | Agent-driven operation and terminal automation. |
| [Stream Deck](/guide/stream-deck) | Physical or browser fleet controls and event logs. |

## Hourly meta-check

`aiur-run` arms `aiur-meta` **before dispatching** and repeats it hourly.

The timer keeps the audit from being lost during a busy merge queue.

| Check | What it catches |
| --- | --- |
| Units, Commands, Build Orders, Analytics | Confident but incorrect operator projections and stalled work. |
| Interactive CLI timing | Empty or timed-out responses hidden by static status. |
| Host load | Capacity pressure against the configured admission gate. |
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

## Usage and account meters

Aiur keeps unknown, partial, and stale pricing explicit instead of turning missing evidence into zero.

| Provider family | Meter meaning |
| --- | --- |
| Codex and Claude | Percentage used in renewing allotment windows. |
| DeepSeek and OpenRouter | Prepaid dollar or credit balance. |
| DeepSeek percentage | Spend against a durable prepaid-balance baseline, not a provider quota. |
| DeepSeek concurrency | Process-local; shown in live CLI and TUI status, omitted from retained provider cards because an instantaneous reading goes stale. |
| Kimi | Session observations only; no account-balance probe. |
| GitHub | Core REST and GraphQL percentage used. |
| ElevenLabs | Account credit quota as percentage used, plus the amount due on the next invoice; neither figure tracks speech-to-text audio-minute spend. |

Dashboard provider meters carry the age of each observation.

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

## Remote control

| Control | Behavior |
| --- | --- |
| `model:remote` label | Starts an agent with remote control. |
| `r` key | Promotes the selected compatible agent. |
| Chat pane | Sends Executor text into the live session. |

Remote control is opt-in per agent and local-only in v1.
