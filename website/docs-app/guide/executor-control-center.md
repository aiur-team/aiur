# Executor Control Center

The Executor Control Center is Aiur’s browser dashboard for supervising a run. It combines the live fleet, durable decisions, recorded outcomes, provider meters, Build Orders, and analytics entry point without turning the browser into a second source of truth.

::: info Example data
Every screenshot on this page was captured from the shipped LiveView dashboard against an isolated fixture. Tickets (`EX-142` and similar), agents, decisions, repositories, and links are synthetic.
:::

## Open the dashboard

Foreground and headless runs start the dashboard unless `--no-dashboard` is present. The launcher binds to loopback by default unless it can safely use configured, authenticated Tailscale exposure. The launch output prints its URL when it is running:

```yaml
server:
  host: 127.0.0.1
  port: 4000
```

Keep the default loopback bind unless you deliberately need network access. See [Authentication and network exposure](#authentication-and-network-exposure) before changing `server.host`.

## Overview

The overview gives the Executor a fast triage path: a blocking-decision banner, Fleet and Decision inbox tabs, and counts for active, blocked, paused, stuck, finished, and total tickets.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="/images/executor-control-center/overview-dark.png">
  <img src="/images/executor-control-center/overview-light.png" alt="Executor Control Center overview with synthetic fleet and decision counts">
</picture>

<img class="occ-mobile-shot" src="/images/executor-control-center/overview-mobile.png" alt="Executor Control Center overview at a mobile viewport">

## Decision inbox

The inbox at `/decisions` sorts durable decisions by blocking status, urgency, and age. Filters separate open, blocking, undelivered, supervising-Executor, resolved, and superseded records. Selecting a card opens its stable `/decisions/:decision_id` detail URL.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="/images/executor-control-center/decision-inbox-dark.png">
  <img src="/images/executor-control-center/decision-inbox-light.png" alt="Decision inbox populated with synthetic decisions in several lifecycle states">
</picture>

<img class="occ-mobile-shot" src="/images/executor-control-center/decision-inbox-mobile.png" alt="Decision inbox at a mobile viewport">

## Decision card and detail

A decision card shows the ticket, source agent, urgency, authority, recommended option, and current lifecycle. The expanded detail adds the full context, consequence of delay, options, artifacts, lifecycle timing, and durable action controls.

When writes are enabled, a human Executor can:

- **Answer** an open decision with an option or bounded custom response.
- **Retry delivery** after a recorded answer has a retryable delivery failure.
- **Revise** a recorded answer. Revisions are append-only corrections; the original action stays in history.
- **Handle a revision follow-up** when a correction can no longer reach an active target.

The target agent, not the browser, records `decision.acknowledged` and `decision.resolved` after consuming and completing the active answer. A supervising Executor can also decide or revise through the separately authenticated machine API when policy permits; see [Coordination and events](/concepts/coordination).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="/images/executor-control-center/decision-dark.png">
  <img src="/images/executor-control-center/decision-light.png" alt="Expanded synthetic decision with answer controls and lifecycle detail">
</picture>

<img class="occ-mobile-shot" src="/images/executor-control-center/decision-mobile.png" alt="Expanded decision at a mobile viewport">

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

## Fleet table

The fleet combines running, retrying, and idle tracker-active tickets. Each row exposes work and waiting state, latest activity, elapsed time, decision count, CI/review facts, and safe links to the ticket, decision, or agent conversation. The filters are cumulative and the table becomes a card list at narrow widths.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="/images/executor-control-center/fleet-dark.png">
  <img src="/images/executor-control-center/fleet-light.png" alt="Fleet table with synthetic active, blocked, retrying, and review tickets">
</picture>

<img class="occ-mobile-shot" src="/images/executor-control-center/fleet-mobile.png" alt="Fleet cards at a mobile viewport">

## Decision history

History is projected from the append-only decision audit. It attributes human Executor, supervising-Executor, ticket-agent, and system facts only when the canonical record identifies them. Dispatch, acknowledgement, revision, and follow-up results remain visible after the active card changes.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="/images/executor-control-center/history-dark.png">
  <img src="/images/executor-control-center/history-light.png" alt="Synthetic durable decision history entries">
</picture>

<img class="occ-mobile-shot" src="/images/executor-control-center/history-mobile.png" alt="Decision history at a mobile viewport">

## Recent outcomes

Recent outcomes come from the durable merge store, not a fresh GitHub poll on every render. Each card preserves repository, pull request, ticket attribution, observation source, and reconciliation health.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="/images/executor-control-center/recent-outcomes-dark.png">
  <img src="/images/executor-control-center/recent-outcomes-light.png" alt="Synthetic recent repository merge outcomes">
</picture>

<img class="occ-mobile-shot" src="/images/executor-control-center/recent-outcomes-mobile.png" alt="Recent outcomes at a mobile viewport">

## Analytics

`/analytics` renders the durable telemetry stream for the current live session. It shows ticket lifecycle timing, per-unit CPU and memory, concurrency against the cap, CPU-second cost per ticket, dispatch-time complexity breakdown, and completed-ticket counts. The writer records `pr_opened` and `pr_merged` anchors from the GitHub firehose, so completion KPIs and burn-up render for the current run. It is not a provider-billing report, and a missing telemetry stream renders an explicit empty state rather than invented zeros. The selected Build Order pane is current-boot only, not cross-session. [#1458](https://github.com/aiur-team/aiur/issues/1458) and [#1459](https://github.com/aiur-team/aiur/issues/1459) track the remaining gaps.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="/images/executor-control-center/analytics-link-dark.png">
  <img src="/images/executor-control-center/analytics-link-light.png" alt="Analytics report link beside recent outcomes">
</picture>

<img class="occ-mobile-shot" src="/images/executor-control-center/analytics-link-mobile.png" alt="Analytics report link at a mobile viewport">

## Writable controls

Dashboard mutations are enabled by default. Disable them when the dashboard is an observation-only surface:

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

The checked-in capture command starts the real endpoint with isolated in-memory providers and captures only synthetic content:

```bash
cd website
npm ci
npm run shot:control-center
```

The fixture never reads a live repository, customer record, issue, agent transcript, or secret. Do not replace its `example.test` data with production data when updating these assets.
