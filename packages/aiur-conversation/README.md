# @aiur/conversation

Embeddable conversation components for apps that host an Aiur conversation.
It ships one component today, the chat composer `<aiur-composer>`.

The composer is a custom element with no dependencies and no build step, so it
works in plain HTML, React, Vue or Svelte. It never talks to Aiur or to a voice
provider itself. The host passes in adapters for upload, dictation and voice,
and receives the message on send.

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

Idle, the composer is one row: + (attach), the text input, mic and send.
Tapping the mic starts dictation and the row becomes a recording row, with
the input above it: cancel ✕, a live waveform, two-way voice, stop ■ and send.
The two-way voice button only appears in the recording row.

| Button | Adapter | Behaviour |
| --- | --- | --- |
| + (attach) | `upload(file) → Promise<{ name, … }>` | Opens the file picker. Each file shows as a chip while it uploads. Send waits until every upload finishes. |
| Mic | `dictation.start({ onPartial, onLevel }) → Promise<{ stop() → Promise<text>, cancel?() }>` | A tap starts dictation and it runs until stop, send or cancel. Holding the mic for 300 ms or more also works: letting go stops. The words go in at the cursor as they are heard. Enter or Space start it from the keyboard. |
| ✕ (cancel) | `dictation` | Discards the dictated words, keeps what was typed and calls `cancel`. Escape does the same. |
| ■ (stop) | `dictation` | Calls `stop` and leaves the final text in the input to edit. It never sends. |
| Two-way voice | `voice.start({ onEnd, initialText }) → Promise<{ stop() }>` | In the recording row, it stops dictation and starts a live conversation. The draft so far moves out of the input into `initialText`, to send as the first turn. While the conversation is live the button replaces the mic, and a tap ends it. Call `onEnd` if the session closes by itself. If `start` rejects, the text goes back into the input. |
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

### Events

- `aiur-send` has `detail: { text, attachments }`. It fires on every send, with or without `onSend`.
- `aiur-composer-error` has `detail: { action, error }`, where `action` is `send`, `upload`, `dictation` or `voice`. It fires when an adapter or `onSend` rejects. The composer shows no error text, so the host decides what to tell the user.

### Attributes and properties

- `placeholder`: the input's placeholder.
- `disabled`: turns off every button and the input.
- `accept`: file types for the picker, such as `image/*,audio/*`.
- `pinned`: fixes the composer to the bottom of the viewport and lifts it above
  the on-screen keyboard. Without `pinned`, the host places the composer in its
  own layout.
- `value`: the draft text, readable and writable.
- `attachments`: the finished uploads, read-only.
- `send()`, `clear()` and `focus()`.

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
| `--aiur-composer-button-bg` | `--aiur-color-surface-2` |
| `--aiur-composer-accent` (send, waveform, active voice) | `--aiur-color-accent` |
| `--aiur-composer-on-accent` | `#ffffff` |
| `--aiur-composer-focus` | `--aiur-color-focus` |
| `--aiur-composer-radius` | `--aiur-radius-xl` |
| `--aiur-composer-font` | `--aiur-font-body` |
| `--aiur-composer-shadow` | `--aiur-shadow-md` |
| `--aiur-composer-button-size` | `44px` |
| `--aiur-composer-max-input-height` | `40vh` |
| `--aiur-composer-z` (pinned) | `10` |

For anything else, use the exposed parts: `::part(card)`, `input`, `actions`,
`attach`, `mic`, `send`, `cancel`, `waveform`, `voice`, `stop`, `attachments`
and `attachment`. While dictating, the element has a `data-recording`
attribute, and during a voice conversation it has `data-voice-live`.

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
