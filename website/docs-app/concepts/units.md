# Units

A Unit is one agent run working one ticket. Every dispatched ticket is a Unit for as long as its run is active, paused, or waiting.

## What the Units page shows

The Units page (dashboard `/`, or `aiur units` on the CLI) is the live fleet table. It lists the tracker-active tickets and their runs together:

<img src="/images/dashboard/units-dark.png" alt="Desktop Units fleet table with synthetic active, blocked, retrying, and review tickets">

- Work and waiting state, with cumulative filters for `active`, `alert`, `paused`, `queued`, and `finished` conditions.
- Latest activity and elapsed time per row.
- Decision count, so tickets that raised a [Command](/concepts/commands) stand out.
- CI and review facts with safe links to the ticket, the decision, or the agent conversation.

The filters narrow what the page projects. `aiur units` reads the same projection with `--scope live|unfinished|all|none` and repeats `--condition` to require any of the selected conditions.

## API meters

A strip at the top of the Units page meters the non-model APIs a run spends, beside the model providers' own meters.

**GitHub** shows its two primary budgets, Core (REST requests) and GraphQL (points), as percentage *used* with remaining/limit counts and the reset time. An active secondary (abuse) rate-limit backoff is named on its own row, because the primary windows still read healthy while one is in force.

**ElevenLabs** appears only when `elevenlabs.api_key` is configured; with no key there is no account to meter and the row is absent entirely, rather than reading "Unavailable" or showing an empty bar. A configured key whose read fails is a different thing and does say so, naming the reason: a rejected key, a rate limit, or an unreachable endpoint, without ever printing the credential.

Read the ElevenLabs figure for exactly what it is:

- It is the **account credit quota** (`character_count` against `character_limit` from `GET /v1/user/subscription`), reported as credits **left** and a bar that *depletes* as they are spent. Every other meter on the page reads percentage *used* with a bar that fills, so this one runs in the opposite direction by design; its label and its fill agree with each other.
- It is **not a dollar balance**. The ElevenLabs API publishes no remaining-balance figure at all; the only money-shaped fields it returns are amounts owed, so Aiur shows no dollar amount here and does not derive one from character counts.
- It is **not a voice-input spend meter**. Speech-to-text, which is what Stream Deck voice input uses, is billed per minute of audio; the character quota is primarily the text-to-speech credit pool. Dictating heavily can therefore leave this meter unmoved.

An account with a zero character limit renders its counts and no bar: there is no denominator, so there is no percentage to state.

## Tickets

The Tickets panel on the same page covers every open ticket on the repository, including the ones no agent has been routed to yet. The fleet table only ever shows tickets carrying an active `agent:*` label. Each row shows its identifier, title, and labels. A row opens the ticket's detail; the robot action opens an add-agent dialog prefilled with the agent, model, effort, and complexity the current routing configuration would apply. The prediction is the dialog's editable starting point rather than a column you can only read.

The panel opens on the first five tickets so a busy backlog does not push the rest of the page out of reach. A "Show more tickets" control below the table reveals the next batch and leaves the rows already on screen in place; it names how many it will add and disappears once every ticket is shown. The panel header always carries the full count.

A search field under the panel title narrows the list as you type. It matches ticket identifiers, titles, and descriptions. Every term has to match somewhere, in either field and in any order, so `retry storm` finds a ticket titled "Retry the dispatch" whose body mentions a webhook storm. Matching ignores case and punctuation, tolerates a prefix or a single typo, and ranks title hits above description hits so the ticket you meant sorts first. Descriptions are matched against a bounded excerpt of each body, not the whole thing. The search runs against the whole open backlog rather than the rows currently on screen, so it finds tickets the reveal has not reached yet; the reveal then batches the matches, and its control counts them. Clearing the field restores the full list, and a query that matches nothing says so rather than leaving the panel blank.

Confirming the add-agent dialog is a writable control. It applies the configured first active-state label, which is what makes a ticket dispatchable at all, plus the selected `complexity:` tag and `model:` overrides, and removes the labels those replace. A tracker other than GitHub reports the panel as unsupported rather than unavailable.

## Why Units matter

The Units page is the first place to look for stalled work. A row in a paused, blocked, or alert state means the run is not advancing, and the reason is visible on the row rather than hidden in a log.
