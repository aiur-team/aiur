# Units

A Unit is one agent run working one ticket while it is active, paused, or waiting.

## What the Units page shows

The Units page is dashboard `/` and CLI `aiur units`.

<img src="/images/dashboard/units-dark.png" alt="Desktop Units fleet table with synthetic active, blocked, retrying, and review tickets">

| Column or control | Meaning |
| --- | --- |
| State filters | Cumulative `active`, `alert`, `paused`, `queued`, and `finished` conditions. |
| Activity | Latest action and elapsed time. |
| Commands | Durable issues the Unit raised for the Executor. |
| CI and review | Current PR facts with safe links to the ticket, Command, or conversation. |
| CLI scope | `--scope live|unfinished|all|none`; repeat `--condition` for any selected condition. |

## API meters

The Units strip shows non-model APIs beside model-provider meters.

| API | What the row means | Detail |
| --- | --- | --- |
| GitHub Core | REST request budget percentage used | [GitHub API budgets](/apis/github#api-budgets) |
| GitHub GraphQL | Query-point budget percentage used | [GitHub API budgets](/apis/github#api-budgets) |
| GitHub secondary limit | Active abuse-control backoff | [GitHub API budgets](/apis/github#api-budgets) |
| ElevenLabs | Subscription character pool; appears only when a key is configured | [ElevenLabs metering](/apis/elevenlabs#what-the-units-meter-measures) |

A configured meter that cannot refresh names authorization, rate-limit, or connectivity failure without exposing its credential.

## Tickets

The Tickets panel covers every open repository ticket, including work that has not been routed to an agent.

| Surface | Behavior |
| --- | --- |
| Fleet table | Shows tickets carrying active `agent:*` labels. |
| Tickets panel | Shows identifier, title, and labels for the entire open backlog. |
| Ticket row | Opens ticket detail. |
| Robot action | Opens an editable routing preview for agent, model, effort, and complexity. |
| Confirm add-agent | Applies the first active-state label and selected routing overrides. |
| Non-GitHub tracker | Reports the panel as unsupported. |

### Reveal and search

| Control | Behavior |
| --- | --- |
| Initial reveal | Shows five tickets and keeps the full count in the header. |
| Show more tickets | Adds the next batch without moving existing rows; disappears when complete. |
| Search terms | Match identifier, title, or a bounded description excerpt in any order. |
| Matching | Ignores case and punctuation; accepts prefixes and one typo. |
| Ranking | Title hits rank above description hits. |
| Scope | Searches the whole backlog, including unrevealed rows. |
| Empty result | States that nothing matched; clearing restores the full list. |

## Why Units matter

Paused, blocked, and alert rows make the reason stalled work is not advancing visible without opening a log.
