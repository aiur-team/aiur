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

The grant is an HMAC-signed token bound to one principal and one ticket set.
Aiur derives the signing key from the instance endpoint secret, so no extra
configuration is required and the grant can only be minted on this instance.

## Mint a grant

Only the supervisor credential may mint a grant. A host server calls this once
per user session and keeps the token out of its public client.

| Request | Body |
| --- | --- |
| `POST /api/v1/commands/scope` | `{"principal": "player-7", "tickets": ["42", "43"], "expires_in": 300}` |

The response carries the token, its expiry, and the scope it authorizes:

```json
{
  "token": "cs1.…",
  "expires_at": "2026-11-05T12:05:00Z",
  "scope": {"kind": "tickets", "label": "Ticket-scoped Commands", "tickets": ["42", "43"]}
}
```

`expires_in` defaults to 900 seconds and is capped at 24 hours.

## Read and answer

Every read accepts only the bearer grant. A Command outside the grant reports
exactly like a missing one, so a guessed identifier reveals nothing.

| Request | Returns |
| --- | --- |
| `GET /api/v1/commands` | `{"commands": [...], "count": n, "pagination": {...}, "scope": {...}, "health": {...}}` |
| `GET /api/v1/commands/:decision_id` | `{"command": {...}, "scope": {...}}` |
| `POST /api/v1/commands/:decision_id/answer` | `{"command": {...}, "scope": {...}}` |

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

## Component states

Every Command renders to one component map with a stable `state`. The dashboard
card and the embeddable renderer both derive it from
`Aiur.Commands.ComponentState`, so the two surfaces cannot drift.

| `state` | Meaning |
| --- | --- |
| `pending` | waiting for an answer; options and free response are available |
| `answered` | an answer is recorded |
| `revised` | an answer was replaced and recorded as a revision |
| `expired` | expired, moot, or dismissed; nothing can be answered |
| `unavailable` | the retained store is partial, so the state is unknown |
| `conflict` | another answer won, the version moved, or delivery is in flight |
| `error` | the read or the answer failed |

A collection carries its own status: `loading`, `empty`, `ready`,
`unavailable`, or `error`.

The component map also carries `options[]`, `recommendation`, `free_response`,
`answer`, `conflict`, `media[]` (typed artifacts from the Command), and
`actions`, which says whether the caller may answer or revise.

## Answer outcomes

Stable HTTP and component states let a host show one message per outcome.

| HTTP | Component `state` | When |
| --- | --- | --- |
| 200 | `answered` or `revised` | recorded; a repeat with the same idempotency key is `answered` with `reason: duplicate_submit` |
| 404 | — | the Command does not exist, or is outside the grant |
| 409 | `conflict` | stale version, already answered, or the answer was already delivered |
| 422 | `error` | the answer failed validation |
| 503 | `unavailable` | Command storage is unavailable |

## What a grant cannot do

A grant cannot widen itself: Aiur never reads a ticket set from request content,
so a host cannot ask for another game's or workspace's Commands. It also cannot
replace an answer that another surface already delivered without Aiur's
precedence rules, because every answer goes through `Aiur.Commands.Answering`.
