# Stream Deck

Open `/streamdeck` in the [Dashboard](/guide/executor-control-center) to use the browser emulator, or install the physical Stream Deck + sidecar. Both surfaces show the same fleet state and provide the same agent controls.

The browser emulator has three modes. A key press changes more than the key grid: it also changes the touch strip and dial actions. Treat the dial labels as current-mode controls, not as persistent settings.

## Drive the three modes

| Mode | Enter it | Keys | Touch strip | Dials A–D |
| --- | --- | --- | --- | --- |
| **Grid** | The initial view; press an agent key to select it. | Up to eight agent keys. | Fleet summary, provider-meter segments, and the page indicator. | **A (Focus):** Back; it has nowhere to go at the top level. **B (Volume):** on the physical deck, turn to scroll the merged provider panel when more providers are configured than it shows at once. The panel says so with a chevron on the side that still has providers. Unassigned in the browser emulator. **C (Speed):** unassigned. **D (Page):** turn to page the agent columns; press to cycle the next agent window. |
| **Command** | Press an agent key in Grid. | Pause/Play, Prioritize/Deprioritize, Logs, and Mic; the other four slots are blank. | The selected agent’s provider, status, and progress. | **A:** return to Grid. **B/C:** unassigned. **D:** press to open Logs; turning it has no command-mode action. |
| **Logs** | Press **Logs**, or press dial D in Command mode. | Up to seven event keys for the selected agent, and the LIVE key. | The five-row transcript readout for wherever you have scrolled. | **A:** turn to scroll the transcript and press to return to Command. **B/C:** unassigned. **D:** turn to scroll the event-key window; its press does not add another mode. |

The `Pause` and `Prioritize` labels reflect the selected agent’s actual current state. In a read-only Dashboard those mutating controls are disabled. **Mic is press-and-hold, not a click:** it is active only while held and clears on release, cancellation, or leaving the key.

## Read the Logs surface

Logs reads like a chat window: **oldest at the far left, newest at the far right.** Scroll fully left for the beginning of the ticket, fully right for what the agent is doing now.

### What the event keys are

One key per event on the ticket’s shared event bus — progress and phase changes, inbound comments, CI and PR transitions, decisions and attentions. The key shows the event’s direction badge, its name (`PR merged`, `Progress check-in`, `Decision requested`), and how long ago it happened.

Two keys always exist:

- **The origin key**, leftmost, labelled `Ticket opened`. It anchors the beginning of the log and owns every transcript line that predates the first published event, so nothing is unreachable.
- **The LIVE key**, rightmost. It wears the same face as the agent’s key on the Grid — lane icon, provider mark, ticket number and progress bar — with `LIVE` in place of the title.

Transcript lines are not event keys. What the agent *said* is detail underneath the event it happened during; what *happened to the ticket* is a key.

### Selection

Exactly one key is active at a time, and it is unmistakable: a full-bleed plate in the badge’s colour, a rail down the left edge, and an inverted badge chip. LIVE turns bright green when it is the active view.

Pressing an event key makes it active and scrolls the strip to that event; LIVE goes inactive. Pressing LIVE reverses it and jumps to the newest line. Scrolling with dial A does the same thing without touching a key — scroll into an event and that key lights up, scroll back to the end and LIVE lights up again. Entering Logs always opens at the live end.

### Live typing

While LIVE is the active key the strip follows the feed, and a newly arrived agent message is revealed character by character so you can watch it land. Scroll away from the live end and it stops: what you are reading then is history, not something being typed now.

### Transcript styling

The readout follows the shape of a terminal coding-agent transcript. Agent prose is unlabelled and bright; tool calls carry a glyph gutter and go muted once complete; shell commands are prefixed `$`; operator messages get a coloured bar; and file edits render as real unified-diff lines with added and removed rows tinted, not as a one-line summary.

### Progress bars

A progress bar has three states, and they are deliberately different pictures:

| State | What it means | How it looks |
| --- | --- | --- |
| Fresh | A recent reading | Solid bar, hue-mapped red-to-green |
| Stale | A real reading that has aged past its freshness window | The same bar, dimmed, with the full track outlined |
| Unknown | No reading at all | Dashed track and a hollow status dot; no bar |

A genuine 0% shows a short solid stub, so “just started” never looks like “no reading”. If a bar drops to an empty track and back, that is a bug — report it.

## How Grid chooses agent keys

Grid has five buckets, in this exact priority: `alert` → `stuck` → `running` → `paused` → `queued`. Within `queued`, dependency-ready (unblocked) agents precede blocked agents. The order is the same in the browser emulator and on the physical deck.

The eight key slots are column-major, not the usual row-major order. The first column contains agents 1 and 2, the next contains 3 and 4, and so on. Paging moves by columns, so a column’s pair stays together as you turn or press dial D.

## Physical sidecar status

The Linux x64 archive installs the sidecar, a systemd **user** service, and the udev rule required to access the device. The supported deployment is Arch Linux on x64 glibc 2.28+; Alpine/musl, ARM, and older glibc are not supported.

The service applies `STREAMDECK_BRIGHTNESS`, reconnects after device hotplug, suspend, or a dashboard disconnect, and keeps the keys and touch strip current with the live fleet.

Set `AIUR_PHOENIX_URL`, `AIUR_DASHBOARD_USERNAME`, and `AIUR_DASHBOARD_PASSWORD` in the private sidecar environment file at `~/.config/aiur/streamdeck.env`. The password is used only to mint the short-lived channel token and is not placed in the WebSocket URL. A Stream Deck +, an Arch Linux graphical session with systemd/logind, and the `users` fallback ACL are required for the physical surface.

The [Stream Deck runbook](https://github.com/aiur-team/aiur/blob/develop/packages/streamdeck/README.md) covers installation, device access, pairing, and recovery.

## Voice input

Voice input captures speech from a microphone attached to the sidecar machine, transcribes it to English text, and sends that text to the selected agent as an operator message.

::: info Deck controls are not available yet
The capture and transcription support described below is available, but the physical microphone and settings keys will arrive in a later release.
:::

### Configure it

Voice input needs an ElevenLabs API key. Add it with `aiur init`, which offers the question during a fresh setup and backfills it into an existing config, or write the section by hand:

```yaml
elevenlabs:
  api_key: $ELEVENLABS_API_KEY
  language_code: eng
```

Prefer the `$ELEVENLABS_API_KEY` reference over pasting the key into the file. See [Configuration](/reference/configuration) for the field reference.

A configured key also puts an ElevenLabs meter on the Dashboard Units page. It reads the account **credit quota** and shows credits remaining; ElevenLabs publishes no dollar balance, so no cost figure is shown. Note that it is not a meter of what dictation costs: speech-to-text bills per minute of audio, while the character quota is primarily the text-to-speech credit pool. See [API meters](/guide/executor-control-center#api-meters).

### Without a key

The key is optional and its absence is not an error. Microphone selection and the level meters keep working, because with no key configured there is nowhere for audio to be sent. Only transcription is unavailable, and the deck reports why rather than failing silently.

### Where your voice goes

This is the one part of Aiur that sends operator data to a third party, so it is worth stating plainly:

- When a key **is** configured, microphone audio is streamed to ElevenLabs and the transcribed text is returned. That audio and that text leave your machine.
- When a key is **not** configured, no audio leaves your machine and no connection to ElevenLabs is opened.
- Audio is captured only while dictation is explicitly held open. There is no always-on listening and no wake word.
- Transcripts are held in memory until they are sent or discarded; the sidecar does not write them to disk.

### Key handling

`ELEVENLABS_API_KEY` is removed from coding-agent environments and never written to Aiur logs.

### Supported microphones

PipeWire and PulseAudio microphones are supported, including ALSA, USB, and Bluetooth devices. Output-monitor sources are not offered as microphones.

Transcription results can appear while you are still speaking. If the selected microphone stops producing audio or disconnects, capture reports the problem instead of remaining in a false listening state.
