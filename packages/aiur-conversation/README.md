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
      async start() {
        const recording = await myRecorder.start();
        return { stop: () => recording.transcribe(), cancel: () => recording.discard() };
      },
    },
    voice: {
      async start({ onEnd }) {
        const session = await myVoice.connect({ onClose: onEnd });
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

| Button | Adapter | Behaviour |
| --- | --- | --- |
| + (attach) | `upload(file) → Promise<{ name, … }>` | Opens the file picker. Each file shows as a chip while it uploads. Send waits until every upload finishes. |
| Mic | `dictation.start() → Promise<{ stop() → Promise<text>, cancel?() }>` | Press and hold to record. Releasing inserts the text at the cursor and does not send. Space or Enter also work when held. Escape cancels. |
| Two-way voice | `voice.start({ onEnd }) → Promise<{ stop() }>` | A tap starts a live conversation and a second tap ends it. Call `onEnd` if the session closes by itself. |
| Send | `onSend(text, attachments)` | Enter sends and Shift+Enter adds a new line. If `onSend` returns a promise, the draft stays until it resolves. A rejection keeps the draft. |

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
| `--aiur-composer-accent` (send, active voice) | `--aiur-color-accent` |
| `--aiur-composer-on-accent` | `#ffffff` |
| `--aiur-composer-focus` | `--aiur-color-focus` |
| `--aiur-composer-radius` | `--aiur-radius-xl` |
| `--aiur-composer-font` | `--aiur-font-body` |
| `--aiur-composer-shadow` | `--aiur-shadow-md` |
| `--aiur-composer-button-size` | `44px` |
| `--aiur-composer-max-input-height` | `40vh` |
| `--aiur-composer-z` (pinned) | `10` |

For anything else, use the exposed parts: `::part(card)`, `input`, `actions`,
`attach`, `mic`, `voice`, `send`, `attachments` and `attachment`.

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
