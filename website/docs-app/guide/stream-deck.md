# Stream Deck

Open `/streamdeck` in the [Dashboard](/guide/executor-control-center) for the browser emulator, or install the physical Stream Deck + sidecar.

<img src="/images/dashboard/streamdeck-dark.png" alt="Desktop Stream Deck emulator showing synthetic agent keys">

## Drive the three modes

| Mode | Enter it | Keys | Touch strip | Dials A to D |
| --- | --- | --- | --- | --- |
| **Grid** | Initial view | Up to eight agent keys | Fleet summary, provider meters, page | A: no action. B: scroll physical provider panel. C: no action. D: page agents; press for next window. |
| **Command** | Press an agent key | Pause/Play, Prioritize/Deprioritize, Logs, Mic | Selected agent status and progress | A: Grid. B/C: no action. D: press for Logs. |
| **Logs** | Press Logs or dial D | Up to seven event keys plus LIVE | Five transcript rows | A: scroll transcript; press for Command. B/C: no action. D: scroll event keys. |

| Control state | Behavior |
| --- | --- |
| Pause / Prioritize | Labels reflect the selected agent's current state. |
| Read-only Dashboard | Mutating controls are disabled. |
| Mic | **Mic is press-and-hold, not a click**; capture stops on release, cancellation, or mode change. |

## Read the Logs surface

Logs runs from oldest at the far left to newest at the far right.

| Key | Meaning |
| --- | --- |
| Ticket opened | Leftmost origin; owns transcript lines before the first event. |
| Event key | One ticket event: progress, phase, comment, CI, PR, decision, or attention. |
| LIVE | Rightmost current view; uses the selected agent's lane, provider, ticket, and progress face. |

Transcript lines stay beneath the event active when they arrived; agent prose is not promoted into extra event keys.

### Selection and live typing

| Action | Result |
| --- | --- |
| Press an event key | Activates it, scrolls to the event, and deactivates LIVE. |
| Press LIVE | Jumps to the newest transcript line. |
| Turn dial A | Scrolls the transcript and updates the active event key. |
| Enter Logs | Opens at LIVE. |
| New text while LIVE | Reveals the message as it arrives and follows the feed. |
| Scroll away from LIVE | Stops following so history stays still. |

### Transcript styling

| Row | Display |
| --- | --- |
| Agent prose | Bright, without a label. |
| Tool call | Glyph gutter; muted after completion. |
| Shell command | `$` prefix. |
| Operator message | Coloured bar. |
| File edit | Unified diff with tinted added and removed rows. |

### Progress bars

| State | Meaning | Display |
| --- | --- | --- |
| Fresh | Recent reading | Solid red-to-green bar. |
| Stale | Real reading past its freshness window | Dimmed bar with outlined track. |
| Unknown | No reading has ever arrived | Dashed track, hollow dot, no bar. |
| 0% | A real zero reading | Short solid stub. |

## How Grid chooses agent keys

| Rule | Order |
| --- | --- |
| State buckets | `alert` → `stuck` → `running` → `paused` → `queued` |
| Queued tickets | Dependency-ready before blocked. |
| Slot order | Column-major: 1/2, then 3/4, then 5/6, then 7/8. |
| Paging | Moves by columns so each pair stays together. |

## Physical sidecar status

The supported transport deployment is Arch Linux on x64 glibc 2.28+.

| Requirement | Value |
| --- | --- |
| Hardware | Stream Deck + |
| Session | Arch Linux graphical session with systemd/logind |
| Device access | Installed udev rule and `users` fallback ACL |
| Unsupported | Alpine/musl, ARM, and glibc older than 2.28 |

The service connects to the authenticated Phoenix channel, routes physical key controls through AgentChat, and watches hotplug and suspend.

| Setting | Where |
| --- | --- |
| `AIUR_PHOENIX_URL` | `~/.config/aiur/streamdeck.env` |
| `AIUR_DASHBOARD_USERNAME` | `~/.config/aiur/streamdeck.env` |
| `AIUR_DASHBOARD_PASSWORD` | `~/.config/aiur/streamdeck.env` |
| `STREAMDECK_BRIGHTNESS` | Sidecar environment |

The password mints the channel token and never enters the WebSocket URL; a short-lived token is renewed after channel disconnects.

| Operator resource | Purpose |
| --- | --- |
| [Direct-HID runbook](https://github.com/aiur-team/aiur/blob/main/packages/streamdeck/README.md) | Install, device access, pairing, and recovery. |
| [Hardware evidence #1358](https://github.com/aiur-team/aiur/issues/1358) | Terminal end-to-end proof for the physical surface. |

## Voice input

Voice input transcribes held dictation and sends the text through the same agent-message path as the Dashboard composer.

::: info Deck controls land separately
The capture and transcription integration exists now; dedicated microphone and settings keys arrive separately.
:::

### Configure it

| Setting | Value |
| --- | --- |
| API key | `ELEVENLABS_API_KEY` in a private environment file. |
| Config reference | `elevenlabs.api_key: $ELEVENLABS_API_KEY` |
| Language | `elevenlabs.language_code: eng` |
| Required permissions | `Speech to Text` and `User`; see [ElevenLabs](/apis/elevenlabs). |

Prefer the environment reference over a literal key. See [Configuration](/reference/configuration#elevenlabs) for field defaults.

### Availability and privacy

| State | What the operator can expect |
| --- | --- |
| Key configured | Held microphone audio goes to ElevenLabs; returned text goes to the selected agent. |
| Key absent | Device selection and level meters work; transcription does not; no audio leaves the machine. |
| Capture released | Audio capture stops; there is no always-on listener or wake word. |
| Transcript returned | Text stays in memory until sent or discarded; the sidecar does not write it to disk. |
| Coding agent launched | `ELEVENLABS_API_KEY` is removed from its environment and never logged. |

The Units meter reads the ElevenLabs text-to-speech character pool, not speech-to-text audio-minute spend; see [ElevenLabs metering](/apis/elevenlabs#what-the-units-meter-measures).
