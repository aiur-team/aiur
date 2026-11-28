---
title: Embed conversation components
---

# Embed conversation components

`@aiur/conversation` provides reusable behavior and default views for host
apps that embed Aiur. It includes `<aiur-composer>` for message drafts,
attachments, dictation and two-way voice, and `<aiur-thread>` for a ticket's
operator and worker messages.

## Exportable views today

The host-styling contract currently covers these packages:

| Package | Exported view | Host contract |
| --- | --- | --- |
| `@aiur/conversation` | Chat composer and ticket thread | Controller state and commands, replacement controls, slots and CSS properties. |
| `aiur-build-order` | Build Order review and graph | `build-order.v1` document renderers, `<aiur-build-order>`, and host CSS tokens. |
| `@aiur/commands` | Command list and response | Static HTML renderers and `data-part` CSS hooks. |

Kanban, timeline and agent views do not have an export contract yet. The Build
Order element accepts `view="fit"` to render the review without its wide graph;
this is suitable for narrow containers. Hosts should verify their exact content
at 390×844 and 1440×900 because ticket titles and host fonts vary.

Build Order embedding uses a short-lived feature or epic grant. After
authenticating its viewer, the host server asks Aiur to mint the grant. The host
issues creators a grant for their game's scope, admins a grant for any selected
scope, and players none. Aiur checks current membership on each read; missing
or out-of-scope grants return 404 with no data.

```http
POST /api/v1/build-order/scope
Authorization: Bearer <host's Aiur supervisor token>
Content-Type: application/json

{"principal":"creator-7","build_order":{"kind":"feature","key":"chess-board"}}
```

The browser receives the short-lived token, never the supervisor token, and
uses it on `GET /api/v1/build-order/embed`. The package example at
`packages/aiur-build-order/examples/host.html` shows host token styling.

For a plain activity page, read `GET /api/v1/:issue_identifier/progress` with
the dashboard/client credential. Its `aiur.ticket_progress` v1 response has
`phase`, current or retained `progress`, ordered progress/check-in/phase
`events`, `sources`, and `generated_at`. Unknown progress stays unknown; no
percentage is estimated.

## Component contract

- **Controller and view.** Each component exposes a DOM-free controller with
  state, commands and events, plus a default view. Use the controller to render
  your own markup or keep the default view and give it your own theme.
- **Styling and replacement.** Default views expose every visual piece as a
  shadow part, with CSS custom properties for color, spacing, radius and
  typography. Named slots let a host supply its own controls.
- **Shared commands.** Default and host controls use the same commands, state
  events and attributes. A custom send button calls `send()`, just like the
  default button.
- **Shared semantics.** Conversation views use the same names for dictation
  (`idle`, `recording`, `stopping`), voice (`idle`, `starting`, `live`,
  `stopping`), and attachments (`uploading`, `ready`). State changes use
  `aiur-conversation-state` and failures use `aiur-conversation-error`, with
  codes including `permission_denied`, `upload_failed`,
  `provider_unavailable`, `send_failed`, `read_failed` and `answer_failed`. Controllers describe labels,
  focus order and live announcements for both default and host views.
- **Host adapters.** The host supplies upload, dictation, voice and send
  adapters. `<aiur-thread>` reads `{ entries, next_after }` from
  `/api/v1/:issue_identifier/thread/messages`, sends messages and
  attachments through its ticket-scoped adapter, and accepts a subscription
  adapter to refresh when the host receives `ticket.<id>.agent.thread.changed`.
  Host controls can call `load()`, `send(text, attachments)` and
  `answer(commandId, answer)`. Send results are available as `state.receipt`,
  and `refreshReceipt()` can re-read the request receipt. The backend APIs
  remain the source of truth for conversations.
  Components have no built-in transport to Aiur or to voice providers.
- **Replaceability.** Each component has a test that replaces a control or
  view and checks the same behavior and events.

## OGM-style reskinning

The default composer can take a warm palette, serif type and a compact
corner radius from the host stylesheet. Use `::part(input)` to give just the
input an underline. A slotted text button can call the same send command as
the default icon button.

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

<aiur-composer placeholder="Message">
  <button type="button" slot="send" disabled>Send message</button>
</aiur-composer>
```

After registering the element with `defineComposer()` and providing the host
adapters, connect the custom button.

```js
const composer = document.querySelector('aiur-composer');
const send = composer.querySelector('[slot="send"]');
send.addEventListener('click', () => composer.send());

function update({ controls }) {
  send.disabled = controls.send.disabled;
  send.setAttribute('aria-label', controls.send.label);
}
composer.addEventListener('aiur-conversation-state', ({ detail }) => update(detail));
update(composer.state);
```

The same pattern works with `mic`, `attach`, `voice`, `stop` and `cancel`.
Use the `input` and `status` slots for your own draft field and live region.
For the complete adapter API,
parts, tokens and a runnable example, see the [package README](https://github.com/aiur-team/aiur/tree/main/packages/aiur-conversation#readme).
