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
| `options[]` | `id`, `label`, `description`, `benefits`, `drawbacks`, `risk` |
| `recommendation` | `{option_id, label}` when the agent recommended one |
| `free_response` | `{allowed, required}` |
| `answer` | the recorded answer, when there is one |
| `conflict` | the winner of a lost race, when one exists |
| `media[]` | typed artifacts: `{kind, value}` where `kind` is `url` or `path` |
| `actions` | which actions the caller may take: `{answer, revise, enrich}` |

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
re-renders from the new component payload.

The renderer escapes every interpolated value. Media is only turned into a
link for `https:` URLs; anything else renders as inert text.

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
