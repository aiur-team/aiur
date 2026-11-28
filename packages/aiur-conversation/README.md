# @aiur/conversation

Embeddable conversation components for apps that host an Aiur conversation.
It ships the chat composer `<aiur-composer>` and ticket thread `<aiur-thread>`.

The composer is a custom element with no dependencies and no build step, so it
works in plain HTML, React, Vue or Svelte. It never talks to Aiur or to a voice
provider itself. The host passes in adapters for upload, dictation and voice,
and receives the message on send.

## Component contract

Every conversation component pairs a DOM-free controller with a default view.
The controller owns draft and session state, adapter lifecycle, commands, and
events. Hosts can render the controller state with their own markup or restyle
the default view with CSS custom properties, shadow parts and named slots.

Default and slotted controls use the same commands. The controller supplies the
labels, focus order and announcements, along with each control's availability.
A host view uses those values to keep replacement controls accessible.

Components share the voice, dictation, attachment and error vocabulary below.
The host supplies transport adapters. Backend APIs own the conversation data
and the transport to providers. Every component tests a replacement view or
control against the same behavior and events as its default.

## Install

The package is not on a registry. Pin it by commit and install the tarball:

```sh
rev=<aiur commit>
git clone --quiet --filter=blob:none --sparse https://github.com/aiur-team/aiur.git aiur-src
git -C aiur-src sparse-checkout set packages/aiur-conversation
git -C aiur-src checkout --quiet "$rev"
npm pack ./aiur-src/packages/aiur-conversation --pack-destination vendor/
npm install ./vendor/aiur-conversation-0.1.0.tgz
```

Since the package has no dependencies, you can also copy `src/` into your app
and import `composer.mjs` from there.

## Use

```html
<aiur-composer placeholder="Message" pinned></aiur-composer>

<script type="module">
  import { defineComposer } from '@aiur/conversation';

  defineComposer();
  const composer = document.querySelector('aiur-composer');

  composer.adapters = {
    upload: async (file) => {
      const body = new FormData();
      body.append('file', file);
      const response = await fetch('/api/uploads', { method: 'POST', body });
      return response.json(); // must include `name`; it comes back on send
    },
    dictation: {
      async start({ onPartial, onLevel }) {
        const recording = await myRecorder.start({
          onTranscript: (textSoFar) => onPartial(textSoFar),
          onVolume: (zeroToOne) => onLevel(zeroToOne),
        });
        return { stop: () => recording.finish(), cancel: () => recording.discard() };
      },
    },
    voice: {
      async start({ onEnd, initialText }) {
        const session = await myVoice.connect({ onClose: onEnd });
        if (initialText) session.say(initialText);
        return { stop: () => session.close() };
      },
    },
  };

  composer.onSend = (text, attachments) =>
    fetch('/api/messages', { method: 'POST', body: JSON.stringify({ text, attachments }) });
</script>
```

Every adapter is optional. A button whose adapter is missing is not shown,
so a host without voice gets a composer without the voice buttons.

Idle, the composer is one row: + (attach), the text input, mic and send. The
mic and send remain at the right edge while dictating; the recognized text
fills the space to their left. The two-way button slides in immediately left
of the mic. During a two-way session the mic mutes/unmutes, and the composer
shows the live waveform plus a running transcript for both speakers.
Transcript bubbles use a full-width row above the controls: your words align
right in the host accent, and agent replies align left on the host button
surface. The bubbles have no visible speaker labels. Muting changes the mic to
a slashed icon; transcript, send and active controls share the host accent.

| Button | Adapter | Behaviour |
| --- | --- | --- |
| + (attach) | `upload(file) → Promise<{ name, … }>` | Opens the file picker. Each file shows as a chip while it uploads. Send waits until every upload finishes. |
| Mic | `dictation.start({ onPartial, onLevel }) → Promise<{ stop() → Promise<text>, cancel?(), setMuted(muted) }>` | A tap starts dictation and it runs until stop, send or cancel. Holding the mic for 300 ms or more also works: letting go stops. The words go in at the cursor as they are heard. Enter or Space start it from the keyboard. |
| ✕ (cancel) | `dictation` | Discards the dictated words, keeps what was typed and calls `cancel`. Escape does the same. |
| ■ (stop) | `dictation` | Calls `stop` and leaves the final text in the input to edit. It never sends. |
| Mic | `voice.start` session | During a two-way session, toggles microphone mute without ending the conversation. The required session `setMuted(muted)` hook is called. |
| Two-way voice | `voice.start({ onEnd, onPartial, onLevel, initialText }) → Promise<{ stop(), setMuted(muted) }>` | Beside the mic while dictating, upgrades dictation into a live conversation. The draft moves into `initialText` as the first turn. During voice, `onPartial('user' | 'agent', text)` updates that speaker's transcript and `onLevel(level)` drives the waveform. The two-way button ends the session. Call `onEnd` when it closes by itself; if `start` rejects, the text returns to the input. |
| Send | `onSend(text, attachments)` | Enter sends and Shift+Enter adds a new line. In the recording row it stops dictation and sends the final text. If `onSend` returns a promise, the draft stays until it resolves. A rejection keeps the draft. |

#### Dictation callbacks

`dictation.start` receives two callbacks. Call them as often as your recognizer
and microphone allow:

- `onPartial(text)`: everything recognized so far in this dictation, not only
  the new words. Each call replaces the previous partial in the input. The
  input is read-only while dictation runs, so typing can't be overwritten.
- `onLevel(level)`: the microphone loudness from 0 to 1. Each call moves the
  waveform by one bar. With a `MediaStream`, read an `AnalyserNode` on each
  animation frame and pass its RMS.

`stop()` resolves to the final text, which replaces the last partial. If it
resolves to an empty string, the last partial stays.

Aiur's voice packages run on a server. `voice_transcribe` provides streaming
speech-to-text and `voice_converse` provides the live voice session. Your
adapters talk to your own server endpoint, and that endpoint runs these
packages. You can use your own voice transport the same way.

## Commands and state

Use the same commands on a `ComposerController` or an `<aiur-composer>`.

| Command | Behavior |
| --- | --- |
| `send()` | Sends the draft and ready attachments. While recording, it waits for final dictation first. Resolves to whether the send succeeded. |
| `attach(file)` | Calls the upload adapter. Resolves to whether the upload became a ready attachment. |
| `removeAttachment(id)` | Removes the ready attachment with the given ID from `state.attachments`. |
| `startDictation(start?, end?)` | Starts dictation at a selection. The element uses its input selection. The headless controller defaults to the end of the draft. |
| `stopDictation()` / `cancelDictation()` | Finish with the final transcript or discard the dictated words. |
| `startVoice()` / `stopVoice()` | Start or end two-way voice. Starting while recording first finishes dictation. |
| `clear()` | Clears the draft, attachments and current error. |

The element also has `focus()` for the textarea and `openFilePicker()` for
an attach button. Element attributes include `placeholder`, `disabled`,
`accept` (file types) and `pinned` (fixed above the on-screen keyboard).
Set `controller.disabled` when using a headless view. Stop and cancel remain
available for an active dictation so the microphone can be released.

Both forms expose writable `value`, ready upload payloads in `attachments`, and
a `state` snapshot. Voice, dictation and attachment states use these names:

| Field | Values | Element hook |
| --- | --- | --- |
| `dictation` | `idle`, `recording`, `stopping` | `data-dictation-state`, plus `data-recording` while recording |
| `voice` | `idle`, `starting`, `live`, `stopping` | `data-voice-state`, plus `data-voice-live` when live |
| `attachments[].state` | `uploading`, `ready` | `data-state` on each attachment part |
| `sending` | Boolean | `data-sending` while pending |
| `error` | Error details or `null` | `data-error-code` when present |

### Events

Subscribe with `addEventListener` on either form. On the element the events
bubble and cross the shadow boundary.

- `aiur-conversation-state` carries the current snapshot in `detail`. Render
  `controls[name].hidden`, `.disabled`, `.label` and `voice.pressed` when
  replacing controls. A headless view also uses `inputLabel`, `readOnly`,
  `caret` and `focusOrder` to lay out native controls in tab order, plus
  `announcement` in a polite live region. Return focus to the input when a
  focused control disappears. Use Enter to send, Shift+Enter for a newline
  and Escape to cancel dictation.
- `aiur-send` carries `{ text, attachments }` in `detail` when a send starts.
  A host that needs to confirm delivery should provide `onSend` and reject
  that promise on failure so the draft stays available.
- `aiur-conversation-error` carries `{ action, code, message, error }` in
  `detail`. The action is `send`, `upload`, `dictation`, `voice`, `read` or
  `answer`. The
  shared `conversationError(action, error)` helper keeps a recognized
  adapter code, maps permission errors to `permission_denied`, and otherwise
  uses `upload_failed`, `provider_unavailable`, `send_failed`, `read_failed` or
  `answer_failed` as appropriate.
  Use `message` for user-facing text. The original error is available for
  host diagnostics. The element still emits `aiur-composer-error` with the
  same detail.

### Headless usage

```js
import { ComposerController } from '@aiur/conversation';

const composer = new ComposerController();
composer.adapters = hostAdapters;
composer.onSend = sendToHost;
composer.addEventListener('aiur-conversation-state', ({ detail }) => render(detail));
render(composer.state);
```

## Ticket thread

`<aiur-thread>` renders a ticket's entries and exposes the same controller as a
headless API. The host supplies ticket-scoped adapters; `read` returns
`{ entries, next_after }` from `GET /api/v1/:issue_identifier/thread/messages`,
`send` accepts `{ message_id, text, attachments }`,
and optional `subscribe` calls its callback when the thread changes (for
example, from `ticket.<id>.agent.thread.changed`). The controller de-duplicates
entries by position when a live refresh overlaps the current page.

```js
import { defineThread } from '@aiur/conversation';

defineThread();
const thread = document.querySelector('aiur-thread');
thread.adapters = {
  read: ({ after, limit }) => api.readTicketThread(issue, { after, limit }),
  send: (message) => api.sendTicketMessage(issue, message),
  answer: (answer) => api.answerTicketCommand(issue, answer),
  subscribe: (onChanged) => eventFeed.subscribe(`ticket.${issue}.agent.thread.changed`, onChanged),
};
```

Use `thread.load()`, `thread.send(text, attachments)` and
`thread.answer(commandId, answer)` from host controls. The send adapter response
is exposed as `state.receipt`; if it includes `request_id`, provide an optional
`receipt(requestId)` adapter and call `refreshReceipt()` to read the latest
`queued`, `delivered` or `consumed` status and delivery mode. The component emits the
shared `aiur-conversation-state` and `aiur-conversation-error` events and an
`aiur-thread-state` snapshot. Hosts can replace the controls through the
`controls` slot. Style the `thread`, `entries`, `entry`, `entry-body`,
`timestamp`, `status` and `error` parts and the `--aiur-thread-*` custom
properties. Compose `<aiur-thread>` beside `<aiur-composer>`; each owns its
controller and the host owns the adapters.

## Theme

The composer reads aiur-style tokens when the page has them, and falls back to
neutral defaults when it doesn't. To use a different palette, set any of these
custom properties on the composer or on an ancestor:

| Property | Default |
| --- | --- |
| `--aiur-composer-bg` | `--aiur-color-surface` |
| `--aiur-composer-fg` | `--aiur-color-fg` |
| `--aiur-composer-muted` (placeholder) | `--aiur-color-muted` |
| `--aiur-composer-line` | `--aiur-color-line` |
| `--aiur-composer-button-bg` (agent bubble) | `--aiur-color-surface-2` |
| `--aiur-composer-accent` (user bubble, send, waveform, active voice) | `--aiur-color-accent` |
| `--aiur-composer-on-accent` (user bubble text) | `AccentColorText` |
| `--aiur-composer-focus` | `--aiur-color-focus` |
| `--aiur-composer-radius` | `--aiur-radius-xl` |
| `--aiur-composer-font` | `--aiur-font-body` |
| `--aiur-composer-shadow` | `--aiur-shadow-md` |
| `--aiur-composer-gap` | `6px` |
| `--aiur-composer-padding` | `6px` |
| `--aiur-composer-control-radius` | `999px` |
| `--aiur-composer-font-size` | `1rem` |
| `--aiur-composer-button-size` | `44px` |
| `--aiur-composer-max-input-height` | `40vh` |
| `--aiur-composer-z` (pinned) | `10` |

Use `::part()` for individual pieces. Parts include `card`, `input`,
`actions`, `status`, `file-input`, `waveform`, `waveform-bar`,
`attachments`, `attachment`, `attachment-name`, `remove-attachment`,
`transcript-bubble`, `transcript-bubble-user`, `transcript-bubble-agent`,
and `attach`, `mic`, `send`, `cancel`, `voice` and `stop`. The button
icons add an `-icon` suffix to their respective button parts; the mic keeps
the `mic-icon` part when muted.

### OGM-style reskinning

Set theme variables on the element or an ancestor and style parts from the
host stylesheet. The [example page](examples/composer.html?skin=ogm) uses
a warm palette, squared corners, serif type and a text send button.

```html
<style>
  aiur-composer {
    --aiur-composer-bg: #fffaf0;
    --aiur-composer-font: Georgia, serif;
    --aiur-composer-radius: 6px;
    --aiur-composer-gap: 12px;
  }
  aiur-composer::part(input) { border-bottom: 2px solid #596743; }
</style>

<aiur-composer>
  <button type="button" slot="send" disabled>Send message</button>
</aiur-composer>
```

Named slots are `input`, `send`, `mic`, `attach`, `voice`, `stop`, `cancel`,
`status`, and `remove-attachment-<id>` for each ready attachment. The default
view controls visibility for the action slots. Wire a replacement's native
activation to its command and use the snapshot for its disabled state and
accessible name. For example, with the element registered and configured:

```js
const composer = document.querySelector('aiur-composer');
const button = composer.querySelector('[slot="send"]');
button.addEventListener('click', () => composer.send());
function update({ controls }) {
  button.disabled = controls.send.disabled;
  button.setAttribute('aria-label', controls.send.label);
}
composer.addEventListener('aiur-conversation-state', ({ detail }) => update(detail));
update(composer.state);
```

For `attach`, call `openFilePicker()` or pass files to `attach(file)` from
your own picker. For `voice`, call `stopVoice()` when `state.voice` is
`live`, and `startVoice()` otherwise. A replacement input updates `composer.value`
on edit and renders `state.value`, `caret`, `inputLabel`, `disabled` and
`readOnly` from snapshots. Wire Enter to `send()` as in a headless view.
For a status replacement, use
`role="status"` and update its text from `state.announcement`.

## React

React 18 passes attributes to a custom element but not properties. Set
`adapters` and `onSend` through a ref:

```jsx
function Composer({ adapters, onSend }) {
  const ref = useRef(null);
  useEffect(() => {
    defineComposer();
    Object.assign(ref.current, { adapters, onSend });
  }, [adapters, onSend]);
  return <aiur-composer ref={ref} placeholder="Message" />;
}
```

## Develop

```sh
npm ci
npm test
python3 -m http.server   # then open examples/composer.html
```
