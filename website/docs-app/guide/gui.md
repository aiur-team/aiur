# GUI

The GUI is Aiur's browser interface for supervising a run. It combines the live fleet, durable decisions, recorded outcomes, provider meters, Build Orders, and analytics.

## Open the GUI

| Launch condition | GUI result |
| --- | --- |
| Normal foreground or headless run | Listener requested. |
| `--no-dashboard` | Listener disabled. |
| Writable mode | On loopback it binds without credentials and fails closed; beyond loopback it refuses to start without both credentials. |
| Read-only loopback | Requires credentials for access. Without them the listener may bind, but every request is refused until both credentials are set. |
| Host selection | `server.host` wins over the `127.0.0.1` default. |

Startup prints the URL and effective bind only when the listener runs:

```text
Dashboard: http://127.0.0.1:4000 (bind host=0.0.0.0, port=4000)
```

## Find a surface

Use the browser when you need interactive detail; use the paired command when terminal output is more useful.

| GUI label | Route and purpose | CLI counterpart |
| --- | --- | --- |
| **Units** | `/` is the Units fleet table and its filters, plus the Tickets panel of every open ticket; [Units](/concepts/units) describes this surface. | `aiur units` |
| **Commands** | `/commands` is the durable decision inbox and each decision's detail. | `aiur commands` |
| **Build Order** | `/build-orders` is the Build Order catalog and one root's execution detail. | `aiur build-orders` |
| **Build queue** | `/build-orders` includes the read-only queue panel on the catalog page: item states, waiting prerequisites, start-order ranks, progress, source freshness and observation age, and open or recently resolved attentions. Manage queues with the CLI. | `aiur queue show` |
| **Analytics** | `/analytics` is latest-run telemetry with durable restart fallback and an optional Build Order scope. A source line labels the data as the live boot or a retained prior run and shows how long ago it was observed. | `aiur analytics` |
| **Streamdeck** | `/streamdeck` is the browser emulator for the physical Stream Deck + sidecar. | none |

| Route change | Behavior |
| --- | --- |
| `/commands` and `/commands/:decision_id` | Current Commands inbox and detail URLs. |
| `/decisions` and `/decisions/:decision_id` | Redirect permanently to the `/commands` equivalents. |
| `/api/v1/decisions`, `decision_id`, event topics | Keep the **decision** vocabulary for compatibility. |

On narrow screens, scroll within the **Build queue** table to see prerequisites, ranks and attentions.

The operator-facing UI and CLI call these records **Commands**.

Open the settings cog in the sticky top bar to pause or resume all agents, change the theme, or switch between Gruvbox (the default) and the aiur palette. Pause requires writable access and a known fleet state; an unavailable state reads “Pause state unknown”. The “All agents paused” chip appears only when pause is confirmed.

The theme follows your operating system until you toggle it. Both choices stay in this browser; another tab keeps its current palette until reload. Fonts are served by the dashboard, including offline.

Drag the navigation edge to switch between icons and labels, or focus the edge and use the arrow keys. The choice stays in this browser. On phones, navigation stays visible in a fixed bottom bar. A red dot on Commands means an answer is waiting; unavailable counts keep their notice instead of showing zero.

The **Models** pane shows a named weekly line for each [Claude account](/guide/claude-accounts). Each line shows the percentage used, a bar, and the reset time next to a recycle icon. Freshness and observation age are in the line's tooltip. A missing reading shows `unknown`, not zero.

The pane shows only providers with a real account: a routed backend, a keyed API, or a provider with an observation. Unconfigured placeholders are not shown.

Each current-run Units row shows Aiur orchestration turns for the current running attempt and the provider's current context occupancy. A turn counts a distinct `session_started` event, not a model request. An unknown count or context observation appears as `—`; context is separate from cumulative token usage.

Open a Units row's conversation to see its **Cumulative Token Usage** panel. For a running Codex agent, it uses the current attempt; otherwise it shows ticket scope.

The panel shows input, output, cached input, derived uncached input, cached proportion, scope, and observation age. Current context occupancy remains separate.

Unsupported, missing, ambiguous, or incomplete measurements remain `—`. A missing observation timestamp is labeled unknown. The panel uses Codex thread snapshots without adding the overlapping per-turn stream.

GUI data tables sort by their meaningful column headings. The first click sorts descending, the second reverses the order, and the active heading shows its direction. Icon and action columns are not sortable.

The fleet table's **Context** column shows each agent's observed context occupancy when its provider reports it. If the provider reports used tokens without a window size, the table says **unknown capacity**; an absent observation shows **—**.

Fleet and capacity facts show their observation age, including fresh data. Tracker rows and retry failures retain their source ages; unknown observations say `age unavailable`. Retry rows identify `since daemon start <UTC time>` because retry state resets on restart. These observations come from the same status read model as `aiur status` and `aiur agents`.

A degraded CODEOWNERS trust banner shows the lookup cause and elapsed age (`age unknown` when unavailable); see [GitHub trust](/apis/github#who-aiur-trusts).

The `sort` query parameter preserves the selected table, column, and direction in copied or refreshed URLs. Paginated and progressively revealed tables sort the displayed rows, then reapply that order when more rows appear.

The temporary, unlinked `/build` route previews the build timeline loading shell.
It requires dashboard authentication; the production data source is not wired yet.

## The pages

Each page renders a durable concept whose detail lives in Concepts.

| Page | Concept detail |
| --- | --- |
| Units | [Fleet, tickets, and meters](/concepts/units). |
| Commands | [Issues agents flag for the Executor](/concepts/commands). |
| Build Order | [Planning packs, phases, lanes, and dependencies](/concepts/build-orders). |
| Analytics | Lifecycle time, CPU, memory, whole-host fleet/build pressure, concurrency, and cost; missing telemetry stays explicit. |

### Read a Build Order program

Normal releases include discovered state-node planning packs on `/build-orders`
and `/build-orders/:root_number`. Pack members without GitHub issues appear as
drafts; promoted members use live issue state when available.

Pack workstreams name the epic columns, and pack phases name the rows, including
phase zero.
Click an epic heading to collapse or expand its cards; counts remain visible.
External gates appear in an expandable list above the graph.

A bounded GitHub catalog preview reports how many members were read out of the
reported total when truncated. The selected GitHub read also remains bounded;
an installed planning pack supplies its full membership. Missing live membership
or ticket status remains explicit even when the plan is readable.

Open a draft card to read its local document. Descriptions longer than 4,000
bytes show a sanitized preview and a **Full document** link to the authenticated
pack document, or the issue for promoted tickets. Documents are read-only.

### Read fleet and build pressure

Analytics records fleet and build-gate whole-host sources alongside daemon process
telemetry. The pressure chart shows occupied agents, configured/max/effective
agent capacity, active and queued builds, and the oldest live build wait.

Its source strip and timestamped table distinguish current, stale, degraded,
partial and empty observations. Load stays diagnostic. Dispatch uses CPU PSI when
available; status names its threshold or load fallback. A growing build queue
shows verification throttling; build occupancy does not hold dispatch.

A gap means the source was not current enough to support that value; it is never
silently plotted as zero. Build-queue wait is the oldest waiter still live at the
sample time, not a completed-build latency. These measurements expose when the
build gate limits verification; they do not automatically change the agent cap.

The build-gate scan runs on a reduced cadence and carries the last observation
forward, so measuring the gate never perturbs a real build acquisition.

<img src="/images/dashboard/units-dark.png" alt="Desktop Units fleet table with synthetic active, blocked, retrying, and review tickets">

## Writable controls

| Writable control | Action |
| --- | --- |
| Unit | Pause or resume. |
| Command | Answer or revise. |
| Fleet | Adjust capacity. |
| Ticket | Apply routing labels. |

The CLI covers Unit and Fleet controls plus initial Command answers. Command revision and ticket-routing preview remain GUI-only today.

Disable mutations for an observation-only surface:

```yaml
observability:
  dashboard_writable: false
```

In read-only mode, Tickets shows the Add an agent action as unavailable before any routing choices are requested. Run `aiur --todo <ticket-id>` from the repository to queue a ticket through the CLI.

Writable requests must also have the expected same-origin `Origin` or `Referer` and `X-Aiur-Request: 1`. These checks supplement authentication; they are not a reason to expose the dashboard publicly.

## Authentication and network exposure

Browser access uses HTTP Basic Authentication configured through environment variables:

```bash
export AIUR_DASHBOARD_USERNAME=example-executor
export AIUR_DASHBOARD_PASSWORD='replace-with-a-strong-secret'
aiur
```

Aiur refuses to start a dashboard bound beyond loopback without both credentials. A loopback listener — writable or read-only — may bind without them, but its authentication plug fails closed and refuses every dashboard request until both credentials are set.

Put remote access behind a private network or trusted reverse proxy and use TLS there; Basic Auth does not encrypt transport.

The supervisor Decision API has a separate bearer credential, `AIUR_SUPERVISOR_TOKEN`. Generate one with `openssl rand -base64 32`, then put `AIUR_SUPERVISOR_TOKEN=<generated-token>` in `~/.aiur/.env` for all projects or the repository `.env` for one project.

An exported value wins, then the global file, then the repository file. The token must be at least 32 bytes, bearer-safe, and free of surrounding whitespace. A present non-empty invalid value aborts startup, while an absent or empty value leaves the API disabled.

Dashboard credentials never grant machine-API authority, and the bearer token never signs a human browser action.

The Analytics ticket timeline marks the earliest PR-open time. Open PRs appear in review; merged, rework, and paused states take precedence.
