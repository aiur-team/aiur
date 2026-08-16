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

## Why Units matter

The Units page is the first place to look for stalled work. A row in a paused, blocked, or alert state means the run is not advancing, and the reason is visible on the row rather than hidden in a log.
