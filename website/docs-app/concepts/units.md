# Units

A **Unit** is one ticket together with the agent working it. It is the thing an Executor supervises: not a process, not a branch, but a piece of tracked work and whatever is currently happening to it.

Units is the dashboard's home page, at `/`. Its CLI counterpart is `aiur units`.

<img src="/images/dashboard/units-dark.png" alt="Desktop Units page with a synthetic fleet table and ticket backlog">

::: info Example data
Every screenshot in this section was captured from the shipped dashboard against an isolated fixture. Tickets (`EX-142` and similar), agents, decisions, repositories, and links are synthetic.
:::

## What the page shows

The page has two panels, and the difference between them matters.

| Panel | Covers | Source |
| --- | --- | --- |
| **Agents** | Running, retrying, and idle tickets that carry an active `agent:*` label. | The live orchestrator projection. |
| **Tickets** | Every open ticket on the repository, including ones no agent has been routed to. | The tracker. |

A ticket with no active `agent:*` label appears in Tickets and not in Agents. That is the usual reason a fleet looks empty while work exists: dispatch needs the label.

## Agent rows

Each row exposes work state, waiting reason, latest activity, elapsed time, open decision count, CI and review facts, and safe links to the ticket, the decision, or the agent conversation. Filters are cumulative. At narrow widths the table becomes a card list.

Counts across the top summarise active, blocked, paused, stuck, finished, and total.

## Ticket rows

Each ticket row shows its identifier, title, and labels. The row opens the ticket detail. The robot action opens an add-agent dialog prefilled with the agent, model, effort, and complexity that the current routing configuration would apply. The prediction is the dialog's editable starting point, not a read-only column.

Confirming that dialog is a writable control. It applies the configured first active-state label, which is what makes a ticket dispatchable at all, plus the selected `complexity:` tag and `model:` overrides, and removes the labels those replace. A tracker other than GitHub reports the panel as unsupported rather than unavailable.

The panel opens on the first five tickets so a busy backlog does not push the rest of the page out of reach. "Show more tickets" reveals the next batch, names how many it will add, leaves the rows already on screen in place, and disappears once every ticket is shown. The header always carries the full count.

## Search

The search field matches ticket identifiers, titles, and descriptions. Every term has to match somewhere, in either field and in any order, so `retry storm` finds a ticket titled "Retry the dispatch" whose body mentions a webhook storm. Matching ignores case and punctuation, tolerates a prefix or a single typo, and ranks title hits above description hits. Descriptions are matched against a bounded excerpt of each body, not the whole thing.

Search runs against the whole open backlog rather than the rows currently on screen, so it finds tickets the reveal has not reached yet. The reveal then batches the matches and its control counts them. Clearing the field restores the full list, and a query that matches nothing says so rather than leaving the panel blank.

## Reading it from the terminal

```bash
aiur units --scope unfinished --condition alert --json
```

`--scope` selects `live`, `unfinished`, `all`, or `none`. `--condition` repeats and requires any of `active`, `alert`, `paused`, `queued`, or `finished`. `--format` chooses `auto`, `table`, or line-oriented `records`. Every `--json` result carries per-source observation age, so a number is never printed without a timestamp.
