# Dashboard

The Dashboard is Aiur’s browser dashboard for supervising a run. It combines the live fleet, durable decisions, recorded outcomes, provider meters, Build Orders, and analytics entry point without turning the browser into a second source of truth.

::: info Example data
Every screenshot on this page was captured from the shipped LiveView dashboard against an isolated fixture. Tickets (`EX-142` and similar), agents, decisions, repositories, and links are synthetic.
:::

## Open the dashboard

Foreground and headless runs request the dashboard unless `--no-dashboard` is present. Its default writable mode requires both `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`, including on loopback. Without credentials, set `observability.dashboard_writable: false` for a read-only loopback dashboard, or the listener refuses to start. The launcher binds to loopback by default unless it can safely use authenticated Tailscale exposure. A configured `server.host` wins over that default. The launch output prints its URL and effective bind address only when the listener is running:

```text
Dashboard: http://127.0.0.1:4000 (bind host=0.0.0.0, port=4000)
```

Set a stable bind explicitly when local ingress, probes, or tunnels depend on it:

```yaml
server:
  host: 127.0.0.1
  port: 4000
```

Set `server.host: 127.0.0.1` explicitly when the dashboard must remain loopback-only. See [Authentication and network exposure](#authentication-and-network-exposure) before choosing a network-visible bind.

## Find a surface

The navigation labels and routes are the same projections the page-parity CLI reads. Use the browser when you need interactive detail; use the paired command when terminal output is more useful.

| Dashboard label | Route and purpose | CLI counterpart |
| --- | --- | --- |
| **Units** | `/` — the Agents fleet table and its filters, plus the Tickets panel of every open ticket; the tables below describe this surface. | `aiur units` |
| **Commands** | `/decisions` — durable decision inbox and each decision’s detail. | `aiur commands` |
| **Build Order** | `/build-orders` — Build Order catalog and one root’s execution detail. | `aiur build-orders` |
| **Analytics** | `/analytics` — live-run telemetry and an optional Build Order scope. | `aiur analytics` |
| **Streamdeck+** | `/streamdeck` — browser emulator for the same live projection used by the authenticated physical Stream Deck + sidecar; [#1358](https://github.com/aiur-team/aiur/issues/1358) defines the remaining terminal hardware proof. | — |

## Overview

The overview gives the Executor a fast triage path: a blocking-decision banner, Fleet and Decision inbox tabs, and counts for active, blocked, paused, stuck, finished, and total tickets.

<img src="/images/dashboard/overview-dark.png" alt="Desktop Dashboard overview with synthetic fleet and decision counts">

## Decision inbox

The inbox at `/decisions` sorts durable decisions by blocking status, urgency, and age. Filters separate open, blocking, undelivered, supervising-Executor, resolved, and superseded records. Selecting a card opens its stable `/decisions/:decision_id` detail URL.

<img src="/images/dashboard/decision-inbox-dark.png" alt="Desktop decision inbox populated with synthetic decisions in several lifecycle states">

## Decision card and detail

A decision card shows the ticket, source agent, urgency, authority, recommended option, and current lifecycle. The expanded detail adds the full context, consequence of delay, options, artifacts, lifecycle timing, and durable action controls.

When writes are enabled, a human Executor can:

- **Answer** an open decision with an option or bounded custom response.
- **Retry delivery** after a recorded answer has a retryable delivery failure.
- **Revise** a recorded answer. Revisions are append-only corrections; the original action stays in history.
- **Handle a revision follow-up** when a correction can no longer reach an active target.

The target agent, not the browser, records `decision.acknowledged` and `decision.resolved` after consuming and completing the active answer. A supervising Executor can also decide or revise through the separately authenticated machine API when policy permits; see [Coordination and events](/concepts/coordination).

<img src="/images/dashboard/decision-dark.png" alt="Desktop expanded synthetic decision with answer controls and lifecycle detail">

## Decision lifecycle

The stepper is a compact view over two canonical axes: decision state and delivery state. It never invents a transition.

| Display state | What it means |
| --- | --- |
| **Recorded** | The request is durable and still awaits an answer. |
| **Dispatch pending** | An answer is durable; delivery is queued or not yet confirmed. |
| **Delivered** | The active answer reached the target agent. |
| **Acknowledged** | The target emitted the correlated acknowledgement event. |
| **Resolved** | The target emitted the correlated terminal resolution event. |
| **Delivery failed** | Delivery failed and may be retryable; the answer remains durable. |
| **Superseded** | A newer append-only revision replaced an earlier action. |

## API meters

A strip at the top of the Units page meters the non-model APIs a run spends, beside the model providers' own meters.

**GitHub** shows its two primary budgets, Core (REST requests) and GraphQL (points), as percentage *used* with remaining/limit counts and the reset time. An active secondary (abuse) rate-limit backoff is named on its own row, because the primary windows still read healthy while one is in force.

**ElevenLabs** appears only when `elevenlabs.api_key` is configured; with no key there is no account to meter and the row is absent entirely, rather than reading "Unavailable" or showing an empty bar. A configured key whose read fails is a different thing and does say so, naming the reason — a rejected key, a rate limit, an unreachable endpoint — without ever printing the credential.

Read the ElevenLabs figure for exactly what it is:

- It is the **account credit quota** (`character_count` against `character_limit` from `GET /v1/user/subscription`), reported as credits **left** and a bar that *depletes* as they are spent. Every other meter on the page reads percentage *used* with a bar that fills, so this one runs in the opposite direction by design; its label and its fill agree with each other.
- It is **not a dollar balance**. The ElevenLabs API publishes no remaining-balance figure at all — the only money-shaped fields it returns are amounts owed — so Aiur shows no dollar amount here and does not derive one from character counts.
- It is **not a voice-input spend meter**. Speech-to-text, which is what Stream Deck voice input uses, is billed per minute of audio; the character quota is primarily the text-to-speech credit pool. Dictating heavily can therefore leave this meter unmoved.

An account with a zero character limit renders its counts and no bar: there is no denominator, so there is no percentage to state.

## Units (fleet table)

The Agents panel combines running, retrying, and idle tracker-active tickets. Each row exposes work and waiting state, latest activity, elapsed time, decision count, CI/review facts, and safe links to the ticket, decision, or agent conversation. The filters are cumulative and the table becomes a card list at narrow widths.

<img src="/images/dashboard/fleet-dark.png" alt="Desktop fleet table with synthetic active, blocked, retrying, and review tickets">

## Tickets

The Tickets panel covers every open ticket on the repository, including the ones no agent has been routed to yet — the fleet table only ever shows tickets carrying an active `agent:*` label. Each row shows its identifier, title, and labels. A row opens the ticket's detail; the robot action opens an add-agent dialog prefilled with the agent, model, effort, and complexity the current routing configuration would apply — the prediction is the dialog's editable starting point rather than a column you can only read.

The panel opens on the first five tickets so a busy backlog does not push the rest of the page out of reach. A "Show more tickets" control below the table reveals the next batch and leaves the rows already on screen in place; it names how many it will add and disappears once every ticket is shown. The panel header always carries the full count.

A search field under the panel title narrows the list as you type. It matches ticket identifiers, titles, and descriptions — every term has to match somewhere, in either field and in any order, so `retry storm` finds a ticket titled "Retry the dispatch" whose body mentions a webhook storm. Matching ignores case and punctuation, tolerates a prefix or a single typo, and ranks title hits above description hits so the ticket you meant sorts first. Descriptions are matched against a bounded excerpt of each body, not the whole thing. The search runs against the whole open backlog rather than the rows currently on screen, so it finds tickets the reveal has not reached yet; the reveal then batches the matches, and its control counts them. Clearing the field restores the full list, and a query that matches nothing says so rather than leaving the panel blank.

Confirming the add-agent dialog is a writable control. It applies the configured first active-state label — which is what makes a ticket dispatchable at all — plus the selected `complexity:` tag and `model:` overrides, and removes the labels those replace. A tracker other than GitHub reports the panel as unsupported rather than unavailable.

## Decision history

History is projected from the append-only decision audit. It attributes human Executor, supervising-Executor, ticket-agent, and system facts only when the canonical record identifies them. Dispatch, acknowledgement, revision, and follow-up results remain visible after the active card changes.

<img src="/images/dashboard/history-dark.png" alt="Desktop synthetic durable decision history entries">

## Recent outcomes

Recent outcomes come from the durable merge store, not a fresh GitHub poll on every render. Each card preserves repository, pull request, ticket attribution, observation source, and reconciliation health.

<img src="/images/dashboard/recent-outcomes-dark.png" alt="Desktop synthetic recent repository merge outcomes">

## Analytics

`/analytics` renders the durable telemetry stream for the current live session. It shows ticket lifecycle timing, per-unit CPU and memory, concurrency against the cap, CPU-second cost per ticket, dispatch-time complexity breakdown, and completed-ticket counts. The writer records `pr_opened` and `pr_merged` anchors from the GitHub firehose, so completion KPIs and burn-up render for the current run. The Provider spend KPI appears only to an authorized browser and only when a scoped provider estimate exists; otherwise it is locked or unavailable, never reported as zero. A missing telemetry stream renders an explicit empty state. A selected Build Order narrows the view to its typed members in this session. [#1458](https://github.com/aiur-team/aiur/issues/1458) and [#1459](https://github.com/aiur-team/aiur/issues/1459) track remaining analytics gaps.

<img src="/images/dashboard/analytics-link-dark.png" alt="Desktop Analytics report link beside recent outcomes">

## Writable controls

Dashboard mutations are enabled by default. They cover pausing and resuming a unit, answering and revising decisions, adjusting capacity, and applying routing labels from the Tickets panel. Disable them when the dashboard is an observation-only surface:

```yaml
observability:
  dashboard_writable: false
```

Writable requests must also have the expected same-origin `Origin` or `Referer` and `X-Aiur-Request: 1`. These checks supplement authentication; they are not a reason to expose the dashboard publicly.

## Authentication and network exposure

Browser access uses HTTP Basic Authentication configured through environment variables:

```bash
export AIUR_DASHBOARD_USERNAME=example-executor
export AIUR_DASHBOARD_PASSWORD='replace-with-a-strong-secret'
aiur
```

Aiur refuses to start a writable dashboard, or a dashboard bound beyond loopback, without both credentials. A loopback dashboard may run without them only when it is not writable. Put remote access behind a private network or trusted reverse proxy and use TLS there; Basic Auth does not encrypt transport.

The supervisor Decision API has a separate bearer credential, `AIUR_SUPERVISOR_TOKEN`. Dashboard credentials never grant machine-API authority, and the bearer token never signs a human browser action.

## Reproduce the screenshots

The checked-in capture command starts the real endpoint with isolated in-memory providers and captures one desktop image for each documented surface. Keeping a single image prevents a screen change from creating a stale light, dark, and mobile set:

```bash
cd website
npm ci
npm run shot:dashboard
```

The fixture never reads a live repository, customer record, issue, agent transcript, or secret. Do not replace its `example.test` data with production data when updating these assets.
