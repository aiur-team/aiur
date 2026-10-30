# Stream Deck

Open `/streamdeck` in the [GUI](/guide/gui) for the emulator, or install the physical Stream Deck + sidecar. Both show the same daemon-rendered images. Ticket frames and the desktop modal read masked journal entries that survive restarts and workspace removal, falling back to workspace logs only without a journal. The browser retains Settings and Commands.

Conversation dictation follows the ticket’s listener mode: default Sync waits for turn end; Steer delivers mid-turn when supported; Async holds messages for agent pull. If a turn is stuck, use the existing operator interrupt control.

<img src="/images/dashboard/streamdeck-dark.png" alt="Desktop Stream Deck emulator showing synthetic agent keys">

The Ticket strip shows category counts and backlog; provider meters are separate from this strip. See [Claude accounts](/guide/claude-accounts) for individual dashboard bars.

The physical deck uses server-rendered Ticket, Feature, Epic and Fleet views.
Dial 4 cycles views, turns page by eight keys, and a 500 ms hold goes back or
opens Settings at the root. Dial 1 scrolls and dial 2 changes ticket priority.

After selecting a ticket, hold dial 3 for 500 ms to dictate; release stops
capture, and a short tap sends the settled transcript. Choose instances in Settings.
The grid dial D turns pages and presses to cycle Ticket, Feature, Epic and Fleet; dial B scrolls the category chips.

## Read provider accounts

On the physical deck, turn dial 4 past the eight Fleet categories
to reach the provider meter keys. Press a meter to open one key per
account, sorted by name, with 5h and weekly remaining percentages and reset
countdowns. Missing windows show “—” with a hatched bar. Stale values stay
visible, dimmed and labelled “stale”.

The touch strip names the provider and
its summary account; hold dial 4 to return. Account keys are read-only.

## Drive the deck

Settings uses the same sections and choices on both surfaces; PC device choices need sidecar inventory.

| Mode | Enter it | Keys | Touch strip | Dials A to D |
| --- | --- | --- | --- | --- |
| **Ticket (Grid)** | Initial view | Up to eight ticket keys; pressing one opens its ticket deck page | Build progress; agent category chips; separate queued and not-queued backlog with page dots | A: no action. B: scroll category chips. C: browse instances; release after press to connect (physical). D: page keys; press to cycle views; hold for Settings at root. |
| **Ticket conversation** | Press a ticket key | Seven conversation turns plus LIVE | Selected turn, or the latest entry at LIVE | A: scroll text; press for Grid. B: priority. C: physical dictation. D: turn for older/newer turns; press to leave the ticket. |
| **Legacy Command** | Press an agent key | Pause/Resume, Priority up/down, Commands, Open PR, Dashboard, Mic, Settings; Send/Cancel replace links while dictating | Latest conversation entry across the full strip; voice panel while dictating | A: Grid. B: no action. C: physical dictation. D: conversation navigation. |
| **Settings** | Hold dial 4 at root or press Settings | Mic, Speaker, View, Sort, Brightness, Sleep, Instance, Alerts | Current section, choice, save errors and inventory availability | Dial 1: scroll/press select. Hold dial 4: back. |
| **Commands** | Press Commands in Command | History keys; then option keys, Mic, and Approve/Cancel | Command question, reading, OPEN/ANSWERED status | A: back a view. D: page history or options; press to approve. |

The server-rendered Ticket strip uses three bands: build progress at the left
(200 px), category chips across the middle (400 px), and `Queued M` / `Not queued K`
with pager dots at the right (200 px).

Chips show a state glyph and count, ordered
error, command, retrying, active, waiting for CI, usage limited, parked, paused,
then other Build states alphabetically and unknown last.

Zero counts are hidden;
missing counts read `Counts unavailable`, never zero. A dimmed band marked `stale`
retains the last counts.

More than eight categories show seven chips and `+N more`;
dial B (zero-based dial 1) moves that window one category per detent. On a selected
ticket, dial B retains the priority action.

Physical display and raw dial routing
require the server-image sidecar update (SD-103).

Physical and emulator ticket frames show the same masked turn keys and full-width conversation strip.
Ticket-key priority stars, lane icons and progress freshness come from the shared Build rows.
Queued keys use the shared prerequisite verdict: Blocked, Unblocked, or Readiness unknown when facts are missing.

### Feature view

The server Feature view uses the Build Features snapshot's closed/total percentage,
rounded down, with closed, published/open (including CI wait) and unpublished bar layers and a positive, known CI-wait
badge.

Missing closed or total counts show “—” with the source reason. Missing bar
counts leave an empty bar while a known closed/total percentage stays visible.

Each key represents a parent feature, summing its epic counts in snapshot order. Dial 4 pages eight keys;
press a key to drill into the parent feature's tickets, then hold Dial 4 to return
with the feature page preserved.

The strip names closed/total, unpublished count and
observation age in minutes for the first visible feature (the selected feature while drilled in).

The browser emulator and physical deck use the same SVG frames, pushed through the
shared frame updates.

Input acknowledgements carry navigation; images arrive in frame events.

The legacy browser modes retain their own controls.

| Legacy control state | Behavior |
| --- | --- |
| Pause | The label reflects the selected agent's current state. |
| Agent key | Selects the agent only; it never pauses or resumes it. Use the dedicated Pause/Play key in Command mode for that. |
| Read-only Dashboard | Pause, priority and Mic are disabled; Commands, links and Settings stay available because they change what you see, not what the fleet does. |
| Mic | **Mic is press-and-hold, not a click**; capture stops on release, cancellation, or mode change. |
| Priority | Dial 2 moves the selected ticket earlier (left) or later (right) in its list build queue. The strip reports `Queued #k`. The orchestrator priority star is separate. |

Multiple detents in one frame produce one move. The strip reports “not in a queue”,
“plan order is fixed”, “queue disabled”, or “outcome unknown”; unknown outcomes are
never retried. Physical dial routing requires the server-input sidecar update
(SD-103).

## Fleet view

Fleet uses the shared server-rendered frames on both the physical deck and the browser emulator.

Cycle dial D to Fleet for eight summary keys: active, needs command,
error/retrying, waiting for CI, usage limited, parked/paused, queued backlog,
and capacity.

Counts use the same filed tickets as the Ticket view. Unrecognized
states remain on Active with a visible unknown sub-count, such as `12 · 1?`.
Press a category to list its tickets; hold dial D to return.

The strip shows daemon state and heartbeat age, capacity (including staleness),
and global pause state. Unknown capacity shows `—`; a stale daemon stays
labelled stale. Fleet only displays global pause.

## Read ticket conversation turns

The keys and strip use the same conversation source, entry IDs and chronological
order as the desktop Build modal, including retained messages after a daemon restart.

Press a ticket key to read its conversation.

| Key | Meaning |
| --- | --- |
| Turn | One agent reply plus the tool/system entries since the previous reply or operator message. An operator message is its own turn. |
| LIVE | Pinned eighth key; returns to the newest entry. |

Bus events such as CI and PR updates do not become conversation keys.

The seven turn keys run from oldest to newest, with the newest next to LIVE.

| Action | Result |
| --- | --- |
| Press a turn key | Selects that turn and shows its text on the strip. |
| Press LIVE | Returns to the tail and follows new entries. |
| Turn dial A (1) | Scrolls the selected conversation text. |
| Turn dial D (4) backwards | Pages to seven older turns; crossing the retained window loads an earlier page. |
| Turn dial D forwards | Pages towards the live end. |
| Press dial A or D | Leaves the focused ticket. |

Pages retain at most 500 entries. A changed transcript or invalid page cursor
clears loaded pages and reloads the tail, so history never silently skips a gap.
Missing history says “Conversation not retained”; read failures say
“Conversation unavailable”; stale conversations show their age.



### Progress bars

| State | Meaning | Display |
| --- | --- | --- |
| Fresh | Recent reading | Solid green bar, slightly brighter at 100%. |
| Unknown | No reading has arrived | Ticket keys show no bar; other progress surfaces use a neutral grey track. |
| 0% | A real zero reading | Short solid stub, so "just started" never looks like "no reading". |

Stale readings retain their values with a dimmed bar.

## Ticket view

| Rule | Order |
| --- | --- |
| Agent states | `error` → `command` → `retrying` → `active` → `ci_wait` → `usage_limited` → `parked` → `paused` → reason states → unknown |
| Ties | Ticket number ascending within each state group. |
| Queued backlog | Filed Build `plan` rows follow agents, in queue position order; duplicates appear once. |
| Slot order | Column-major: 1/2, then 3/4, then 5/6, then 7/8. |
| Paging | Shared server pages hold eight keys; the last page leaves unused slots empty. |

The default Ticket view reads the same Now and planned rows as the Build page.
If that read fails, the key area shows “Tickets unavailable” until it recovers.
Agent-state labels match Build, including “Waiting for CI”, “Awaiting command” and “State unknown”.

Missing progress draws no bar and never becomes 0%. Tickets without an agent appear
only when queued; pressing a key opens that ticket’s deck page.
The order is the same in the browser emulator and on the physical deck.

## Epic view

Epic keys show remaining open tickets, open/total, and the percentage closed.
They use Build's `epic_progress`: most remaining first, then epic label;
unknown counts show “—” with a reason and sort last. A ticket counts under every
matching general epic, including tickets owned by a feature.

Press an epic key to list its matching tickets; hold dial 4 for 500 ms to go
back. With `build_order.general_epics: []`, or when every configured epic has zero total tickets, the view says “No epics configured”
and names that setting, without showing a zero remaining count.

Epic keys and the empty-state strip use the same shared SVG renderer in the
browser emulator and on the physical deck.

## Physical sidecar status

The daemon draws every image. The sidecar rasterizes its SVG frames to JPEG,
forwards raw input, and shows **Aiur offline** with blank keys when the channel
is down. On reconnect, the daemon sends a full frame and resets navigation.

The physical entry point shows the server grid; selecting a ticket opens its shared conversation strip. The legacy local
voice, Commands and browser links await server migrations;
use the dashboard for those controls.

The control and voice sections below
describe the emulator/legacy surfaces, not the current physical frame client.
The saved instance is still selected at startup; hardware dial C no longer
operates the legacy instance picker.


The dashboard's `/streamdeck` page emulates the deck without the sidecar; nothing in the dashboard needs it installed.

Download the Linux x64 archive from the rolling [`streamdeck-nightly`](https://github.com/aiur-team/aiur/releases/tag/streamdeck-nightly) pre-release, which is rebuilt in place whenever the sidecar changes. The `/streamdeck` page's setup dialog links the same asset.

The archive installs the sidecar, a systemd **user** service, and the udev rule required to access the device.

| Requirement | Value |
| --- | --- |
| Hardware | Stream Deck + |
| Session | Arch Linux graphical session with systemd/logind |
| Device access | Installed udev rule and `users` fallback ACL |
| Unsupported | Alpine/musl, ARM, and glibc older than 2.28 |

The supported deployment is Arch Linux on x64 glibc 2.28+.

The service uses `STREAMDECK_BRIGHTNESS` until brightness is saved in Settings, reconnects after device hotplug, suspend, or a dashboard disconnect, and keeps the keys and touch strip current with the live fleet.

| Setting | Where |
| --- | --- |
| `AIUR_PHOENIX_URL` | `~/.config/aiur/streamdeck.env` |
| `AIUR_CLIENT_TOKEN` | `~/.config/aiur/streamdeck.env`; optional engine environment for pane control |
| `AIUR_DASHBOARD_USERNAME` | `~/.config/aiur/streamdeck.env` |
| `AIUR_DASHBOARD_PASSWORD` | `~/.config/aiur/streamdeck.env` |
| `STREAMDECK_BRIGHTNESS` | Sidecar environment; default brightness until a deck setting is saved |

The sidecar prefers `AIUR_CLIENT_TOKEN` when set; otherwise it uses the
dashboard credentials to mint a short-lived channel token. Neither credential
enters the WebSocket URL. Create a token with `aiur token create streamdeck`.

The physical frame client forwards dials to the daemon's navigation reducer.
It loads the saved instance at startup and retries that target after a channel
failure. Authentication failures require corrected credentials and a restart.
The offline strip does not display connection details; consult service logs.

The sidecar reads the CLI's `~/.aiur/remote-instances.yaml` registry at startup:

```yaml
version: 1
instances:
  remote:
    url: https://remote.example.com
    token_file: ~/.aiur/tokens/remote
```

The environment daemon is always first, named `local` (`AIUR_PHOENIX_URL`, or
loopback port 4000 when unset). Registry names must be unique; `local` is
reserved. `AIUR_PHOENIX_URL` retains support for non-loopback HTTP and path prefixes.

Registry URLs require HTTPS except on loopback and cannot contain credentials,
paths, queries, or fragments.

Each remote sets exactly one `token_file` (absolute
or `~/`, readable and mode **0600**) or `token_env` (an `AIUR_TOKEN_*` variable).
Invalid URLs or credentials prevent that connection; the physical strip shows
**Aiur offline** until a channel supplies a frame.

Tokens are resolved when connecting and never shown on the strip
or in debug logs.

The sidecar remembers its last connection in `streamdeck-instance.json` under
`$XDG_CONFIG_HOME/aiur` (or `~/.config/aiur`); the daemon's Settings page chooses
which instance to follow. Restart the sidecar after editing the registry.

The browser emulator shows its current instance name only; open the other dashboard's
`/streamdeck` page to change instances there.

The [Stream Deck runbook](https://github.com/aiur-team/aiur/blob/main/packages/streamdeck/README.md) covers installation, device access, pairing, and recovery.

## Voice input

Voice input captures speech from a microphone attached to the sidecar machine, transcribes it to English text, and sends that text to the selected agent as an operator message.

### Legacy command keys

Shared ticket frames use conversation keys; these slots describe the legacy browser Command controls, while physical dictation uses dial 3 after selecting a ticket.

| Key | Slot | Behavior |
| --- | --- | --- |
| Pause/Play | First | Pauses or resumes the selected agent. |
| Priority up/down | Second/third | Moves a ticket one place in a list queue; disabled at edges or outside a list queue. |
| Mic | Seventh | Press-and-hold; live only while held. |
| Settings | Eighth | Opens shared Settings; hold dial 4 at the root to open it from the physical grid. |
| Commands | Fourth | Opens the agent's Command history; always present, so its absence can never be mistaken for "no Commands". |
| Open PR / Dashboard | Fifth/sixth | Opens the configured PR or Build ticket modal on the sidecar host; browser emulator uses a new tab. |
| Send | Fifth, once dictation has text | Delivers the accumulated text to the agent. |
| Cancel | Sixth, once dictation has text | Discards the accumulated text. |

A missing PR disables Open PR. Link keys accept only HTTP(S) URLs.

The browser shares Settings and its reported PC inventory; microphone capture runs on the sidecar.

### Dictate to an agent

On the physical deck, select a ticket, hold dial 3 for 500 ms and speak. Release
to stop capture; short-tap dial 3 to send the settled text to that ticket. This
uses the microphone chosen in Settings and the Dashboard message path. It does
not start a spoken conversation or play agent replies.

In the legacy command layout, hold Mic and use Send/Cancel:

| Step | What happens |
| --- | --- |
| Hold Mic | The touch strip becomes the voice panel: scrolling waveform, level bar, and text as it settles. |
| Release | Settled text stays; the in-flight phrase is dropped, so a half-heard word cannot be sent. |
| Hold again | Transcription accumulates across holds rather than replacing the previous phrase. |
| Send | Uses the same path as the Dashboard composer, so the message enters the agent transcript and its next turn. |
| Cancel | Discards the buffer and leaves you in the agent view. |
| Back out to Grid | Discards the buffer, so a message about one ticket never follows you into the next. |

Your operator message appears as its own conversation turn; LIVE returns to the newest entry.

### Settings

Hold dial 4 at the root to open Settings.

| Setting or state | Behavior |
| --- | --- |
| Navigation | Press a section key, turn dial 1 to scroll, then press it or a choice key to select; hold dial 4 to return. |
| Mic and Speaker | Choose devices attached to the sidecar's PC; inventory refreshes after device changes. |
| View and Sort | Set the default deck view and ordering. |
| Brightness | Save a value from 0 to 100; until saved, `STREAMDECK_BRIGHTNESS` supplies the default. |
| Sleep | Dim after the chosen idle timeout; 0 disables dimming. Any input restores brightness. |
| Instance | Choose which configured daemon instance the deck follows. |
| Alerts | Choose flash/chime for `command`, `ci_red`, `error` and `usage_limited`; daemon alert routing stays unchanged. |
| Stored choice | `~/.aiur/instances/<key>/streamdeck-settings.json`, private to the daemon instance; survives sidecar restarts. The old mic preference is migrated once. |
| Chosen device absent | Shows “missing”, uses the first available device and keeps the saved id for reconnection. |
| Save failure | Shows “not saved” and keeps the previous file and settings. |

There is no standalone microphone-test key. The browser uses the daemon's latest
sidecar inventory; disconnects and failed device discovery show “Unavailable” rather than an empty list.

### Voice replies are out of scope

Agent replies are not spoken; only alert chimes use the chosen speaker. Dictation
needs the `Speech to Text` and `User` permissions.

The Build ticket modal retains dictation. Worker conversation voice and the Executor prototype remain available from Home’s **Settings → Talk to Executor** (`/voice`).

### Configure it

| Setting | Value |
| --- | --- |
| Enable voice input | `elevenlabs.enabled: true` |
| API key | `ELEVENLABS_API_KEY` in a private environment file. |
| Config reference | `elevenlabs.api_key: $ELEVENLABS_API_KEY` |
| Language | `elevenlabs.language_code: eng` |
| Required permissions | `Speech to Text` and `User`; see [ElevenLabs](/apis/elevenlabs). |
| Optional voice | `elevenlabs.voice_id`; enables Dashboard spoken replies when set. |

```yaml
elevenlabs:
  enabled: true
  api_key: $ELEVENLABS_API_KEY
  language_code: eng
  voice_id: null # optional; enables Dashboard spoken replies when set
```

Prefer the environment reference over a literal key. See [Configuration](/reference/configuration#elevenlabs) for field defaults.

### Availability and privacy

| State | What the operator can expect |
| --- | --- |
| Key configured | Held microphone audio goes to Aiur, then to ElevenLabs; returned text waits in the deck buffer for Send. |
| Voice input declined (`enabled: false`) | Device selection, waveform, and level meters work; transcription and ElevenLabs metering are disabled; no audio leaves the machine. |
| Enabled, key absent | Device selection, waveform, and level meters work; transcription does not; no audio leaves the machine. |
| Capture released | Audio capture stops; there is no always-on listener or wake word. |
| Transcript returned | Unsent text stays in memory until sent or discarded; sent text follows ordinary message retention. |
| Coding agent launched | `ELEVENLABS_API_KEY` is removed from its environment and never logged. |

When voice input is enabled, the Units meter shows the ElevenLabs credit quota as percentage used; it omits invoice amounts and speech-to-text audio-minute spend. See [ElevenLabs metering](/apis/elevenlabs#what-the-usage-meter-measures). Declining voice input disables this provider meter.

### Without a key

The key is optional and its absence is not an error; unlike an absent key, `elevenlabs.enabled: false` records that voice input was declined and disables the provider integration (see [Configuration](/reference/configuration#elevenlabs)).

| Surface | Behavior with no key |
| --- | --- |
| Microphone selection, waveform, level meters | Keep working; the sidecar computes them locally. |
| Transcription | Unavailable, because there is nowhere to send audio. |
| Mic key | Explains itself with the connect-time reason `Aiur has no ElevenLabs API key - transcription is off`. |

### Where your voice goes

See [voice responsibilities and cloud processing](/apis/elevenlabs#who-does-what) for capture, transport, transcription, delivery and retention.

Voice transcription sends operator audio to a cloud provider.

**Aiur holds the credential and Aiur performs the ElevenLabs call. The sidecar never sees the key.**

| Step | Path a spoken word takes |
| --- | --- |
| 1 | The sidecar captures 16 kHz mono audio from the microphone on its own machine. |
| 2 | It sends that audio to Aiur over the same authenticated Stream Deck channel it uses for fleet state, not to any third party. |
| 3 | Aiur opens the ElevenLabs connection with the key from its own configuration and streams the audio on. |
| 4 | ElevenLabs returns text and Aiur pushes it back to the deck. |
| 5 | The sidecar corrects unambiguous mishearings of the coined name before display or delivery. |
| 6 | The finished message reaches the agent through the ordinary agent-message path. |

| Heard as | Result |
| --- | --- |
| `aeor`, `iyer`, `ayer`, `A, your` | Corrected to **Aiur**. |
| `higher`, `iron`, `ire`, `IR` | Left unchanged, rather than corrupting a real word or acronym. |

| Condition | Consequence |
| --- | --- |
| Key configured | Microphone audio reaches ElevenLabs and the transcribed text comes back; both leave your machine. |
| Key absent | No audio leaves your machine and no ElevenLabs connection is opened. |
| Mic released | Capture stops; there is no always-on listening and no wake word. |
| Waveform and level meter | Computed on the sidecar, so "is my microphone working" is answered locally; audio still travels through Aiur to ElevenLabs for transcription. |
| Transcripts | Unsent text stays in memory; submitted text follows ordinary message or Command retention. |

### Key handling

`ELEVENLABS_API_KEY` is a secret and is treated as one.

| Rule | Why |
| --- | --- |
| Configured only in Aiur's own configuration | No sidecar environment file carries it; the sidecar is given no way to hold it. |
| Scrubbed from coding-agent environments | Every `*_API_KEY` variable is removed, so an agent cannot read it. |
| Never logged or attached to a failure reason | A connection failure is reported generically instead. |

### Supported microphones

PipeWire and PulseAudio microphones are supported, including ALSA, USB, and Bluetooth devices. Output-monitor sources are not offered as microphones.

## Answer agent Commands

The Commands key on the ticket page opens the focused agent's Command history — past Commands newest-first, active ones highlighted — and is always present, so its absence can never be mistaken for "no Commands".

| Key | Meaning |
| --- | --- |
| Command key | One Command; an amber `OPEN` badge marks an answerable one, a muted `ANSWERED` badge a completed one. |
| Mic | Always present in an open Command's detail; press-and-hold to dictate. |
| Approve | Appears while dictated text is held; sending it is a deliberate second action. |
| Cancel | Appears while dictated text is held; discards it. |

### Answer one Command

Press a Command key to enter its detail: the description paints the bottom panel and the options paint the key row, four to a page.

| Step | What happens |
| --- | --- |
| Press an option key | Reads that option's detail in the bottom panel. Selecting is reading, never committing. |
| Dial D | Pages the options (or the history, on the history view). |
| Press dial D | Approves the selected option — the deliberate second action that turns a read into an answer. |
| Hold Mic | Dictates a free-text response, shown building in the bottom panel. |
| Approve | Sends the spoken text as the answer; it takes precedence over any listed option ("none of the above"). |
| Cancel | Discards the spoken text. |
| Back (dial A) | Leaves the detail for history, then returns to the agent row. |

The Approve state is unmistakable: when an answer is armed the strip shows a green `APPROVE` label, the one strip element that commits a durable operator decision.

If another surface answers first, the attempted answer key briefly shows the winning answer and “Answered by …”; withdrawn or changed Commands show a message and refresh the page.

Single-question Commands, including native agent questions, use the same option keys. Commands with multiple questions or any multi-select question show “Answer on dashboard”; option keys, dictation, and approval are disabled for them. Older plugins are also refused by the server with `dashboard_only`. Rebuild and install the sidecar after updating Aiur.

Completed Commands are read-only — they show what was asked and what was decided, with no Approve affordance.

### Attribution

An answer given on the deck is recorded with operator attribution (`operator` / `streamdeck`) — the same authoritative path as a Dashboard answer. It is never an Executor answer with an operator flavour in free text.

That is also what lets the deck answer `human_required` Commands an Executor cannot. Answers are only accepted for the agent currently focused on the deck.

### Authority

A deck's access follows its configured credential. When `AIUR_CLIENT_TOKEN` is set, the sidecar sends it as a bearer credential and its scope controls API access.

Revoking that client token prevents the sidecar from obtaining further channel tokens; existing channel tokens remain short-lived.

With the client token unset, dashboard Basic credentials remain a loopback-only migration fallback.

A plugged-in deck can keep requesting channel tokens while its configured credential remains valid; it does not require a fresh operator approval for each action. A write-scoped token lets it answer `human_required` and `irreversible` Commands — the floor constrains automation, not the operator.

A stolen or unattended deck carries the write authority of its configured token, so treat it like a logged-in session. Answers remain version-checked regardless: the deck answers the exact Command version it read, and a stale press is rejected as a conflict — never recorded as a second decision.

Aiur holds a streaming connection to ElevenLabs, so transcription results can appear while you are still speaking rather than after you release the key. If the selected microphone stops producing audio or disconnects, capture reports the problem instead of remaining in a false listening state.

The channel's `answer_command` operation also accepts `override: true` with a
nonblank `rationale` (up to 4,000 characters) to override an existing answer,
including after delivery. Ordinary answer submissions retain first-answer-wins
semantics.

The override record and routing state are visible in
`aiur commands --json`. Resumable workers wait for capacity; explicit parked or
paused labels require operator resume.

A merged PR creates a corrective ticket for a new worker and PR; later overrides
reuse its open work. Implementation requires the corrective PR to merge.

Physical override controls are separate from this transport operation.
