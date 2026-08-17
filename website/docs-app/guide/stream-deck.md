# Stream Deck

Open `/streamdeck` in the [Dashboard](/guide/executor-control-center) to use the browser emulator, or install the physical Stream Deck + sidecar. Both surfaces show the same fleet state and provide the same agent controls.

The browser emulator has three modes. A key press changes more than the key grid: it also changes the touch strip and dial actions. Treat the dial labels as current-mode controls, not as persistent settings.

## Drive the three modes

| Mode | Enter it | Keys | Touch strip | Dials A–D |
| --- | --- | --- | --- | --- |
| **Grid** | The initial view; press an agent key to select it. | Up to eight agent keys. | Fleet summary, provider-meter segments, and the page indicator. | **A (Focus):** Back; it has nowhere to go at the top level. **B (Volume):** on the physical deck, turn to scroll the merged provider panel when more providers are configured than it shows at once. The panel says so with a chevron on the side that still has providers. Unassigned in the browser emulator. **C (Speed):** unassigned. **D (Page):** turn to page the agent columns; press to cycle the next agent window. |
| **Command** | Press an agent key in Grid. | Pause/Play, Logs, Mic, and Settings, plus Send and Cancel once dictation has produced text; the remaining slots are blank. | The selected agent’s provider, status, and progress — or the voice panel while the Mic is held or a dictated message is waiting. | **A:** return to Grid. **B/C:** unassigned. **D:** press to open Logs; turning it has no command-mode action. |
| **Settings** | Press **Settings** in Command. | On the physical deck, one key per detected microphone, then TestMic and a paging key. In the browser emulator, none: the pane is text. | The selected microphone, or the voice panel while TestMic is held. | **A:** return to Command. |
| **Logs** | Press **Logs**, or press dial D in Command mode. | Up to seven event keys for the selected agent, and the LIVE key. | The five-row transcript readout for wherever you have scrolled. | **A:** turn to scroll the transcript and press to return to Command. **B/C:** unassigned. **D:** turn to scroll the event-key window; its press does not add another mode. |

The `Pause` label reflects the selected agent’s actual current state. In a read-only Dashboard the mutating controls — Pause and Mic — are disabled; Logs and Settings stay available because they change what you see, not what the fleet does. **Mic is press-and-hold, not a click:** it is active only while held and clears on release, cancellation, or leaving the key.

There is no prioritize key on the deck. The agent view has four slots and the microphone took the fourth. Agent priority is unchanged as an orchestrator control and remains available from the Dashboard; the deck still shows the resulting state, as a star on the agent’s Grid key and in the order Grid ranks agents.

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
| Fresh | A recent reading | Solid green bar; a slightly brighter green at 100% |
| Stale | A real reading that has aged past its freshness window | The same borderless green bar, dimmed |
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

### The keys

Voice lives in the agent view, which you reach by pressing an agent key in Grid. Its four keys are **Pause**, **Logs**, **Mic** and **Settings**; the remaining four slots are blank.

- **Mic** is the third key and is press-and-hold. It is live only while held.
- **Settings** is the fourth key. On the physical deck it opens the microphone picker described below. In the browser emulator it opens a text pane instead: the microphones being chosen between are attached to the machine running the sidecar, and a browser tab cannot see them. Dial A backs out of either.

### Dictate to an agent

Select an agent in Grid, then:

1. **Hold Mic** and speak. The touch strip becomes the voice panel: a waveform scrolling left to right, a vertical level bar beside it, and the transcribed text underneath as it settles.
2. **Release** when you have finished the thought. The text stays.
3. **Hold Mic again** to add to it. Transcription **accumulates across holds** — the panel shows everything you have said so far, not just the last phrase. This is what lets you say a sentence, think, and then say the rest.
4. **Send** and **Cancel** appear as the fifth and sixth keys as soon as there is something to send. Send delivers the accumulated text to the agent; Cancel discards it. Both leave you in the agent view, so you can dictate again, back out with dial A, or open Logs.

A sent message goes through the same path as the Dashboard composer, so it appears in the agent's transcript and the agent picks it up on its next turn. Open **Logs** after sending and you will see your own message in the feed — Logs opens at the live end, which is where a message you just sent lands.

Two things worth knowing about the buffer. Only *settled* text is sent: the in-flight phrase you can see being revised is dropped when you release, so a half-heard word cannot end up in the message. And the buffer belongs to the agent you were focused on — backing out to Grid discards it, rather than carrying a message about one ticket into the next.

### Choose a microphone

**Settings** lists the microphones attached to the sidecar's machine, six to a page, with a seventh key for **TestMic** and an eighth to page when there are more than six. Press one to select it; the selected key wears the same plate, rail and chip that marks the active key in Logs.

The choice is written to `~/.config/aiur/streamdeck-mic.json` and **survives a sidecar restart**. If the microphone you chose is not attached the next time the sidecar starts, capture falls back to the first available device — but the stored preference is kept, so unplugging a headset for an afternoon does not forget it.

**Hold TestMic** to check that a microphone actually works. The voice panel appears with the waveform, the level bar and live text, exactly as it does while dictating, but nothing is delivered to an agent. Speak, and if the trace moves the microphone is working. The waveform and the level bar are computed on the sidecar from the captured audio, so they respond immediately and keep working even with no ElevenLabs key configured — in that case the panel shows the reason where the text would be, and the meters keep moving underneath it.

A machine with no microphone is a legitimate state, not a failure: the pane says so rather than showing an empty grid.

### Voice replies are out of scope

The Stream Deck path transcribes; it does not speak. It needs only the `Speech to Text` and `User` permissions. The Dashboard Units modal can separately use the same server-held credential for interactive spoken replies when `Text to Speech` permission and a `voice_id` are configured.

### Configure it

Voice input needs an ElevenLabs API key. Add it with `aiur init`, which offers the question during a fresh setup and backfills it into an existing config, or write the section by hand:

```yaml
elevenlabs:
  api_key: $ELEVENLABS_API_KEY
  language_code: eng
  voice_id: null # optional; enables Dashboard spoken replies when set
```

Prefer the `$ELEVENLABS_API_KEY` reference over pasting the key into the file. See [Configuration](/reference/configuration) for the field reference.

A configured key also puts an ElevenLabs meter on the Dashboard Units page. It shows the account **credit quota** as percentage used and labels the amount due on the next invoice; that dollar figure is money owed, not a remaining balance. Note that it is not a meter of what dictation costs: speech-to-text bills per minute of audio, while the character quota is primarily the text-to-speech credit pool. See [API meters](/guide/executor-control-center#api-meters).

### Without a key

The key is optional and its absence is not an error. Microphone selection, the waveform and the level meters keep working, because with no key configured there is nowhere for audio to be sent. Only transcription is unavailable, and the deck says so — it receives the reason `Aiur has no ElevenLabs API key - transcription is off` in the state it gets on connect, so a disabled Mic key can explain itself immediately.

### Where your voice goes

This is the one part of Aiur that sends operator data to a third party, so it is worth stating plainly. **Aiur holds the credential and Aiur performs the ElevenLabs call. The sidecar never sees the key.**

The path a spoken word takes is:

1. The sidecar captures 16 kHz mono audio from the microphone on its own machine.
2. It sends that audio to **Aiur**, over the same authenticated Stream Deck channel it already uses for fleet state — not to any third party.
3. **Aiur** opens the connection to ElevenLabs, using the key from its own configuration, and streams the audio on.
4. ElevenLabs returns text and Aiur pushes it back to the deck. Before display or delivery, the sidecar corrects unambiguous mishearings of the coined name — `aeor`, `iyer`, `ayer`, and `A, your` become **Aiur**. Real words and acronyms such as `higher`, `iron`, `ire`, and `IR` are left unchanged rather than risk silently corrupting the operator's meaning.
5. The finished message is delivered to the agent through the ordinary AgentChat path.

The consequences of that arrangement:

- When a key **is** configured, microphone audio reaches ElevenLabs and the transcribed text comes back. That audio and that text leave your machine.
- When a key is **not** configured, no audio leaves your machine and no connection to ElevenLabs is opened.
- Audio is captured only while the Mic key is held. There is no always-on listening and no wake word.
- The waveform and the level meter are computed on the sidecar from the captured audio and never wait on a round trip, so "is my microphone working" is answered locally. Only transcribed text makes the trip.
- Transcripts are held in memory until they are sent or discarded; nothing writes them to disk.

### Key handling

`ELEVENLABS_API_KEY` is a secret and is treated as one.

- It is configured in **one** place — Aiur's own configuration. No sidecar environment file carries it, and the sidecar is given no way to hold it.
- It is removed from coding-agent environments along with every other `*_API_KEY` variable, so an agent cannot read it.
- It is never written to a log line and never attached to a failure reason, so a connection failure is reported generically.

### Supported microphones

PipeWire and PulseAudio microphones are supported, including ALSA, USB, and Bluetooth devices. Output-monitor sources are not offered as microphones.

Aiur holds a streaming connection to ElevenLabs, so transcription results can appear while you are still speaking rather than after you release the key. If the selected microphone stops producing audio or disconnects, capture reports the problem instead of remaining in a false listening state.
