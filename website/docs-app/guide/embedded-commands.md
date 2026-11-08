# Embedded Commands

A host application can show and answer the Commands that belong to one of its
users without giving that user Aiur credentials. Aiur issues a short-lived,
ticket-scoped grant, and the host renders the same Command component the
dashboard does.

This page covers the API and the component contract. The
[`@aiur/commands`](https://github.com/aiur-team/aiur/tree/main/packages/aiur-commands)
package README covers the renderer and the runnable example host.

## The boundary

The host **server** holds the Aiur instance credential and exchanges it for a
grant naming an explicit ticket set. The user's client receives only the grant.

```text
host browser ──► host server ──(AIUR_SUPERVISOR_TOKEN)──► POST /api/v1/commands/scope
                     │                                          │
                     │◄──────────── short-lived scoped grant ────┘
                     ▼
             GET /api/v1/commands        Authorization: Bearer <grant>
             GET /api/v1/commands/:id
             POST /api/v1/commands/:id/answer
```

A grant may name an explicit ticket set, a label scope such as `game:chess`, or
both.

The grant is an HMAC-signed token bound to one principal and one ticket set.
Aiur derives the signing key from the instance endpoint secret, so no extra
configuration is required and the grant can only be minted on this instance.

## Mint a grant

Only the supervisor credential may mint a grant, once per user session.

| Request | Body |
| --- | --- |
| `POST /api/v1/commands/scope` | `{"principal": "player-7", "tickets": ["42", "43"], "labels": ["game:chess"], "expires_in": 300}` |

The response carries the token, its expiry, and the scope it authorizes:

```json
{
  "token": "cs1.…",
  "expires_at": "2026-11-05T12:05:00Z",
  "scope": {"kind": "tickets", "label": "Ticket-scoped Commands", "tickets": ["42", "43"]}
}
```

The host server calls the mint endpoint and keeps the token out of its public
client. `expires_in` defaults to 900 seconds and is capped at 24 hours.

A label scope authorizes every ticket currently observed to carry one of the
grant's labels, so a ticket added to the game later needs no new grant. An
explicit ticket stays in scope whatever its labels.

If Aiur has not yet observed the labels, a label scope authorizes nothing; it
never widens to every ticket.

## Read and answer

Every read accepts only the bearer grant, and a Command outside it reports
exactly like a missing one, so a guessed identifier reveals nothing.

| Request | Returns |
| --- | --- |
| `GET /api/v1/commands` | `{"commands": [...], "count": n, "pagination": {...}, "scope": {...}, "health": {...}}` |
| `GET /api/v1/commands/:decision_id` | `{"command": {...}, "scope": {...}}` |
| `POST /api/v1/commands/:decision_id/answer` | `{"command": {...}, "scope": {...}}` |
| `POST /api/v1/commands/:decision_id/reject` | `{"command": {...}, "scope": {...}}` |
| `GET /api/v1/commands/:decision_id/media/:attachment_id` | the media file, or a redirect to its public URL |

A list read also accepts `labels=game:chess`, which narrows the page to the
tickets currently carrying that label. Request labels only narrow: a label
outside the grant lists nothing rather than widening its ticket set.
`/api/v1/decisions` accepts the same filter.

A list read also accepts one `tag=source:settings`, which keeps only Commands
carrying that [tag](#tags-and-sibling-commands). Like
`labels`, it narrows within the grant and never widens it.

The answer body names one option or a free response, plus the version the user
was looking at and an idempotency key:

```json
{
  "idempotency_key": "6d0f…",
  "expected_version": 3,
  "option_id": "approve"
}
```

Send `custom_response` instead of `option_id` for a free response, and
`replace: true` to replace an answer that already exists. Answers go through
Aiur's canonical human-answer path, so optimistic version checks, idempotency,
replacement precedence, and audit attribution all behave exactly as they do on
the dashboard.

## Reject a Command

A user can refuse a Command, including a blocking one, and say why. Post the
reason, the version the user was looking at, and an idempotency key:

```json
{
  "idempotency_key": "9a41…",
  "expected_version": 3,
  "reason": "This question is wrong: the build already shipped."
}
```

The reason is kept verbatim (up to 4,000 bytes) in the Command's record and in
the answer event. The rejection is the Command's answer, so a waiting agent
unblocks and receives a message that names the rejection and quotes the reason.

Scope, version checks and idempotency behave as for `answer`. A blank reason is
a 422, and a Command outside the grant is the same 404.

## Tags and sibling Commands

A `decision.requested` payload may carry `tags`: up to 8 lowercase slugs such
as `group:proposal-7` or `source:settings`, each at most 96 bytes, with at most
one `group:` tag. An invalid list is refused as `{:decision_invalid, {:tags,
reason}}`. Tags persist with the Command and appear in the component map and on
its lifecycle events.

Commands that share a `group:` tag on one ticket are siblings. When one is
rejected or dismissed, every other open or deferred sibling is mooted with
`reason_class: sibling_rejected`; its detail and actor name the rejected
Command. An answered sibling keeps its answer, and other groups and tickets are
untouched.

## Component states

Every Command renders to one component map with a stable `state` that the
dashboard card and the embeddable renderer both derive from
`Aiur.Commands.ComponentState`, so the two surfaces cannot drift.

| `state` | Meaning |
| --- | --- |
| `pending` | waiting for an answer; options and free response are available |
| `answered` | an answer is recorded |
| `revised` | an answer was replaced and recorded as a revision |
| `rejected` | rejected with a reason; `reason` and `answer.custom_response` carry it verbatim, `answer.rejected` is `true` |
| `expired` | expired, moot, or dismissed; nothing can be answered |
| `unavailable` | the retained store is partial, so the state is unknown |
| `conflict` | another answer won, the version moved, or delivery is in flight |
| `error` | the read or the answer failed |

A collection carries its own status: `loading`, `empty`, `ready`,
`unavailable`, or `error`.

The component map also carries `options[]`, `recommendation`, `free_response`,
`answer`, `conflict`, `media[]`, `tags[]`, and `actions`, which says whether the
caller may answer, reject or revise.

## Command media

A Command's prompt and each of its options can carry typed media: `image`,
`animated_image`, `video`, or `audio`. The component's `media[]` holds those
items, and an option's own `media[]` sits on the option.

A typed item has a `kind`, a `mime_type`, a `locator`, and alt text or a caption.
A pre-existing artifact reference in the same list has a bare `kind` + `value`.
The presence of `locator` is what tells the two apart.

```json
{
  "kind": "image",
  "mime_type": "image/png",
  "locator": {"kind": "attachment", "attachment_id": "med_9f2c…"},
  "alt_text": "Cover A: bright meadow",
  "caption": "Cover A",
  "width": 1200,
  "height": 630
}
```

A `url` locator is already public and needs nothing from the host. An
`attachment` locator is a file Aiur serves, so the host reads it from the media
route with the same grant.

Aiur re-checks the ticket set and the Command's own attachment list on every
read. A signed or non-allowlisted URL never appears in the component, and a
server-local path never appears at all.

`renderCommand(command, { mediaBaseUrl })` points an `attachment` locator at the
host's Aiur origin. Without it, an attachment item renders an unavailable panel
instead of a broken element. Pass the same option to `renderList`.

The renderer covers all four kinds: images and animated images render with their
alt text and caption, and video and audio use native `controls` with a poster
where the item has one. A Command whose media cannot be resolved still renders.

## Theme the component

Every styled element carries a stable `data-part` attribute. Import `@aiur/commands/theme.css` and set `--aiur-command-*` custom properties on any ancestor; the `labels` render option replaces the visible copy. The package README lists every part and property.

## Answer outcomes

Stable HTTP and component states let a host show one message per outcome.

| HTTP | Component `state` | When |
| --- | --- | --- |
| 200 | `answered`, `revised` or `rejected` | recorded; a repeat with the same idempotency key is `answered` with `reason: duplicate_submit` |
| 404 | — | the Command does not exist, or is outside the grant |
| 409 | `conflict` | stale version, already answered, or the answer was already delivered |
| 422 | `error` | the answer failed validation |
| 503 | `unavailable` | Command storage is unavailable |

## What a grant cannot do

A grant cannot widen itself: Aiur never reads a ticket set from request content,
so a host cannot ask for another game's or workspace's Commands. It also cannot
replace an answer that another surface already delivered without Aiur's
precedence rules, because every answer goes through `Aiur.Commands.Answering`.
