# @aiur/commands

An embeddable Command response component for applications that host Aiur.

A *Command* is a question an Aiur agent asked and is now blocked on (or would
like an answer to). This package renders one Command — its options, its
recommended option, a free-response field and its recorded answer — from the
documented component contract served by Aiur's ticket-scoped Commands API.

It has no dependencies, returns HTML strings, and never talks to Aiur itself:
the host owns authentication and the HTTP client.

## The boundary

```
host browser ──(host session)──► host server ──(AIUR_SUPERVISOR_TOKEN)──► POST /api/v1/commands/scope
                                      │                                          │
                                      │◄──────────── short-lived scoped grant ────┘
                                      ▼
                              browser gets the grant only
                                      │
                                      ▼
                     GET /api/v1/commands   (Authorization: Bearer <grant>)
                     GET /api/v1/commands/:id
                     POST /api/v1/commands/:id/answer
```

The host server exchanges its own Aiur instance credential for a grant naming
the exact ticket set one of its users may see, a label scope such as
`game:chess`, or both. The browser never receives the instance credential, and
Aiur never accepts a ticket set from request content: the grant is the scope.

## Component contract

Every Command renders to one `CommandComponent`:

| Field | Meaning |
| --- | --- |
| `state` | `pending`, `answered`, `revised`, `expired`, `unavailable`, `conflict`, `error` |
| `reason` | machine-readable detail for the state, when there is one |
| `decision_id`, `version` | identity and optimistic-concurrency version |
| `question`, `ticket`, `blocking` | what is being asked and where |
| `options[]` | `id`, `label`, `description`, `benefits`, `drawbacks`, `risk`, and an optional `media[]` |
| `recommendation` | `{option_id, label}` when the agent recommended one |
| `free_response` | `{allowed, required}` |
| `answer` | the recorded answer, when there is one |
| `conflict` | the winner of a lost race, when one exists |
| `media[]` | typed media items (`kind`, `mime_type`, `locator`, alt/caption) plus pre-existing artifact references (`kind` + `value`) |
| `actions` | which actions the caller may take: `{answer, revise, enrich, escalate}` |

A collection renders to a `CommandList`: `status` is `loading`, `empty`,
`ready`, `unavailable` or `error`, with `commands[]` and an `error` detail.

## Usage

```js
import { renderList, renderCommand } from '@aiur/commands';

const response = await fetch('/api/commands');   // your host's proxy
const list = await response.json();

document.querySelector('#commands').innerHTML = renderList(list, {
  answerUrl: '/api/commands/answer',
});
```

`renderCommand(command, { answerUrl })` renders one Command. A `pending`
Command with `actions.answer` renders a form carrying `data-aiur-command-form`
and `data-decision-id`; the host posts the form to its own endpoint and then
re-renders from the new component payload. With `actions.escalate` true it also
renders an "Escalate to Executor" form (`data-aiur-command-escalate-form`, an
optional `note` field, posted to `escalateUrl`); an `escalated` Command shows a
notice and no forms.

The renderer escapes every interpolated value. Media is only turned into a
link for `https:` URLs; anything else renders as inert text.

### Media

A Command's prompt and each of its options can carry typed media — `image`,
`animated_image`, `video` or `audio`. A typed item carries a `locator`; a
pre-existing artifact reference in the same list carries a bare `kind` + `value`.
An item whose locator kind is `url` is already public. An item whose locator kind
is `attachment` is a file Aiur serves, so tell the renderer where Aiur lives:

```js
renderCommand(command, {
  answerUrl: '/api/commands/answer',
  mediaBaseUrl: 'https://aiur.example.com',
});
```

The renderer then reads the file from
`GET /api/v1/commands/:decision_id/media/:attachment_id` with the same grant the
component came from. Aiur re-checks the ticket set and the Command's own
attachment list on every read. Without `mediaBaseUrl`, an attachment item renders
an "unavailable" panel rather than a broken element, and a signed or
non-allowlisted URL renders the same way.

Images and animated images render with their alt text and caption; video and
audio use native `controls` and take their `aria-label` from the alt text or
caption. Option media renders beside the option, outside its `<label>`, so a
playback control is never swallowed by the label's click target.

## Theming

Every element a host may style carries a stable `data-part` attribute (and the
matching `aiur-command-*` class). Both are a public contract.

| `data-part` | Element |
| --- | --- |
| `list` | the `renderList` wrapper |
| `list-status` | the loading / empty / unavailable / error line |
| `command` | one Command (`<article>`) |
| `header`, `state` | header row and its state label |
| `question` | the question heading |
| `ticket` | the ticket line |
| `recommendation` | the "Recommended: …" line |
| `notice`, `conflict` | state notices |
| `answer-form` | the answer `<form>` |
| `options`, `legend` | the option fieldset and its legend |
| `option`, `option-copy`, `chip` | one option, its text, its "Recommended" chip |
| `option-media` | media beside an option |
| `response`, `response-label` | the free-response field and its label |
| `actions`, `submit` | the footer and its submit button |
| `answer`, `answer-label` | the recorded answer and its label |
| `media-list`, `media`, `media-item`, `media-caption`, `media-kind`, `media-unavailable` | Command media |

Import the optional stylesheet, `@aiur/commands/theme.css`, and set custom
properties on any ancestor. All have defaults:

| Property | Controls |
| --- | --- |
| `--aiur-command-accent` | accent: submit button, chip, recommended option |
| `--aiur-command-radius` | corner radius |
| `--aiur-command-font` | font family |
| `--aiur-command-fg` | text colour |
| `--aiur-command-muted` | secondary text colour |
| `--aiur-command-bg` | Command background |
| `--aiur-command-border` | border colour |
| `--aiur-command-gap` | spacing |

User-visible copy is set with the `labels` render option (escaped like all
other text): `submit`, `legend`, `recommended`, `recorded`, `revised`.

```js
renderCommand(command, { labels: { submit: 'Send', legend: 'Pick one' } });
```

## Answering

Answers go through Aiur's canonical human-answer path, so the host does not
reimplement conflicts:

```json
{
  "idempotency_key": "6d0f…",
  "expected_version": 3,
  "option_id": "approve"
}
```

Send `custom_response` instead of `option_id` for a free response, and
`replace: true` to replace an answer that already exists. Stable responses:

| HTTP | Component `state` | Meaning |
| --- | --- | --- |
| 200 | `answered` / `revised` | answer recorded (a repeat with the same idempotency key is `answered` + `reason: duplicate_submit`) |
| 404 | — | no such Command, or it is outside the grant |
| 409 | `conflict` | stale version, already answered, or answer delivered |
| 422 | `error` | the answer failed validation |
| 503 | `unavailable` | Command storage is unavailable |

## Example host

`examples/host.mjs` is a complete, dependency-free example: it mints a grant
for a ticket set or a label scope, lists Commands, and renders them.

```bash
AIUR_BASE_URL=http://127.0.0.1:4000 \
AIUR_SUPERVISOR_TOKEN=... \
AIUR_HOST_TICKETS=42,43 \
AIUR_HOST_LABELS=game:chess \
AIUR_HOST_PRINCIPAL=player-7 \
node examples/host.mjs
```

Set either `AIUR_HOST_TICKETS` or `AIUR_HOST_LABELS`; both may be combined.

`node examples/host.mjs --self-check` renders a fixed Command without network
access.

## Tests

```bash
npm test
```

The fixtures in `test/fixtures/command-states.json` are shared with Aiur's
Elixir contract test, so the states this renderer knows and the states the
dashboard derives cannot drift apart.

## License

MIT
