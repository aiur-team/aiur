# GUI

The GUI is Aiur's browser interface for supervising a run. It combines the build history, the live fleet, durable decisions, recorded outcomes, provider meters, Build Orders, and analytics.

High-rate snapshot notifications on Home, Units, Commands, Build Orders, and Stream Deck arrive in batches spaced at least 500 ms apart. Each subscription group holds one unacknowledged batch while newer notifications coalesce by event type. User actions and chat messages keep their existing delivery path.

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

<img src="/images/dashboard/build-dark.png" alt="Desktop Build page with the usage strip, the Live band and synthetic planned tickets">

## Find a surface

Use the browser when you need interactive detail; use the paired command when terminal output is more useful.

| GUI label | Route and purpose | CLI counterpart |
| --- | --- | --- |
| **Build** | `/` is the continuous build timeline; `/build` is a live alias. [Continuous build history](/concepts/build-history) describes its sections, views, ticket modal and usage strip. | none; `aiur agents`, `aiur queue show` and `aiur feature show` cover its parts |
| **Units** (rollback) | `/units` is the Units fleet table and its filters, plus the Tickets panel of every open ticket; [Units](/concepts/units) describes this surface. | `aiur units` |
| **Commands** | `/commands` is the durable decision inbox and each decision's detail. | `aiur commands` |
| **Build Order** | `/build-orders` is the Build Order catalog and one root's execution detail, reachable by URL without a navigation item. | `aiur build-orders` |
| **Build queue** | `/build-orders` includes the read-only queue panel on the catalog page: item states, waiting prerequisites, start-order ranks, progress, source freshness and observation age, and open or recently resolved attentions. Manage queues with the CLI. | `aiur queue show` |
| **Analytics** | `/analytics` is latest-run telemetry with durable restart fallback and an optional Build Order scope. The page opens with a loading message while telemetry is analyzed in the background; concurrent cold loads share one retained-summary scan. A source line labels the data as the live boot or a retained prior run and shows how long ago it was observed. A notice identifies periods with analytics capture disabled. | `aiur analytics` |
| **Streamdeck** | `/streamdeck` is the browser emulator for the physical Stream Deck + sidecar. | none |

| Route change | Behavior |
| --- | --- |
| `/units` | Hidden Units rollback page, retained for one release. |
| `/chat/:owner/:repository/:identifier` | Redirects same-repository ticket links to `/?ticket=identifier`, opening the Build ticket modal. |
| `/?v=1&scope=…&conditions=…` | Opens Build with the matching legacy Units filter. |
| `/commands` and `/commands/:decision_id` | Current Commands inbox and detail URLs. |
| `/decisions` and `/decisions/:decision_id` | Redirect permanently to the `/commands` equivalents. |
| `/api/v1/decisions`, `decision_id`, event topics | Keep the **decision** vocabulary for compatibility. |

On narrow screens, scroll within the **Build queue** table to see prerequisites, ranks and attentions.

The operator-facing UI and CLI call these records **Commands**.

Open the settings cog in the sticky top bar to pause or resume new agent starts, change the theme, or switch between Gruvbox (the default) and the aiur palette. A global pause leaves existing agents running and observed; pause an individual agent from its row for containment.

Pause requires writable access and a known fleet state; an unavailable state reads “Pause state unknown”. The “New starts paused” chip appears only when pause is confirmed.

The theme starts dark until you toggle it. Both choices stay in this browser; another tab keeps its current palette until reload. Fonts are served by the dashboard, including offline.

Drag the navigation edge to switch between icons and labels, or focus the edge and use the arrow keys. The choice stays in this browser. On phones, navigation stays visible in a fixed bottom bar. A red dot on Commands means an answer is waiting; unavailable counts keep their notice instead of showing zero.

The **Models** pane shows a named weekly line for each [Claude account](/guide/claude-accounts). Each line shows the percentage used, a bar, and the reset time next to a recycle icon. Freshness and observation age are in the line's tooltip. A missing reading shows `unknown`, not zero.

The pane shows only providers with a real account: a routed backend, a keyed API, or a provider with an observation. Unconfigured placeholders are not shown.

GUI data tables sort by their meaningful column headings. The first click sorts descending, the second reverses the order, and the active heading shows its direction. Icon and action columns are not sortable.

Fleet and capacity facts show their observation age, including fresh data. Tracker rows and retry failures retain their source ages; unknown observations say `age unavailable`. Retry rows identify `since daemon start <UTC time>` because retry state resets on restart. These observations come from the same status read model as `aiur status` and `aiur agents`.

A degraded CODEOWNERS trust banner shows the lookup cause and elapsed age (`age unknown` when unavailable); see [GitHub trust](/apis/github-auth#who-aiur-trusts).

The `sort` query parameter preserves the selected table, column, and direction in copied or refreshed URLs. Paginated and progressively revealed tables sort the displayed rows, then reapply that order when more rows appear.

## The pages

Each page renders a durable concept whose detail lives in Concepts.

| Page | Concept detail |
| --- | --- |
| Build | [Sections, views, the ticket modal, usage, and unknown states](/concepts/build-history). |
| Units (`/units`, rollback) | [Fleet, tickets, and meters](/concepts/units). |
| Commands | [Issues agents flag for the Executor](/concepts/commands). |
| Build Order | [Planning packs, phases, lanes, and dependencies](/concepts/build-orders). |
| Analytics | Lifecycle time, CPU, memory, whole-host fleet/build pressure, concurrency, and cost; missing telemetry stays explicit. |
| Experiments | A separate experiment index and specification detail at `/experiments`; shown when the experiments capability is available. |

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

## Writable controls

| Writable control | Where | Action |
| --- | --- | --- |
| Fleet | Settings cog on Build, Units, Commands, Build Order, Analytics and Streamdeck | Pause or resume new agent starts. |
| Unit | `/units` | Pause or resume one agent, or send it a message. |
| Fleet capacity | `/units` | Adjust capacity. |
| Ticket | `/units` Tickets panel | Apply routing labels. |
| Ticket | Build ticket modal | Add a not-queued ticket to the build queue. |
| Command | Commands | Answer or revise. |

Apart from Add to queue, the Build ticket modal is read-only. The CLI covers fleet, Unit and capacity controls plus initial Command answers; Command revision and the ticket-routing preview remain GUI-only today.

Disable mutations for an observation-only surface:

```yaml
observability:
  dashboard_writable: false
```

The home ticket modal hides Add to queue when `dashboard_writable` is `false`.

In read-only mode, the `/units` Tickets panel shows the Add an agent action as unavailable before any routing choices are requested. Run `aiur --todo <ticket-id>` from the repository to queue a ticket through the CLI.

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

Retained Analytics charts use at most 180 evenly spaced resource observations per actor, including the first and last. Chart detail is sampled; headline CPU totals and resource peaks use the full retained profiles.

Full log combines newest runs that fit its bounded projection with current telemetry. Latest-run fallback and Full log decode at most 45 MiB per cold load. The source line reports included runs and omissions, and names skipped newer runs in Latest-run. Analytics is unavailable if none fit; without materialized history, raw files over 1 MiB are unavailable.

### Read an experiment

Open **Experiments** below Analytics and select an experiment. The shareable
`/experiments/:id` URL shows its design, windows, hypothesis and registered
metrics. On a phone, **All experiments** returns to the index. Existing
experiments remain visible when capture is off; unavailable evidence and store
errors are shown explicitly.

Frozen baseline details include the revision, capture time, Aiur version and
SHA-256 hash. A warning identifies metric packs that changed since the freeze.

The page reads the cached report analysis matching the current frozen inputs
(or a legacy root-level `result.json`) for group summaries, sample counts and
analyst labels. Below the
analysis minimum, interval, p-value and effect cells say **not enough data**.

The **Analyst report** card shows the analyst's Markdown, including tables. A
pending message appears until a report exists. Reports may lag the evidence;
the card identifies newer results with both report and result times. Tables
over 4,096 cells are shown as text to keep reports bounded.

The median-change chart shows stored percentage estimates and confidence
intervals, with the expected direction labelled. Hollow points mark **not enough
data** or unavailable estimates; no interval is drawn below the sample minimum.

Select a metric to see its
box-and-dot distribution and time series; metric and stratum selections are
shareable through `?metric=` and `?stratum=`. Stratum chips appear only for stored
stratum analyses.

Cohorts use both colour and marker shape; additional cohorts use numbered markers. On phones, the time
series scrolls within its container. Every chart has a **Show data** table.

Sample meters distinguish the minimum sample guard from estimated power
requirements. Missing estimates and sample counts remain unavailable; captured
empty samples show zero.

Sample points come from
frozen snapshots; if none exist, the page says so and shows only stored group
summaries. Rolling medians appear only when supplied in the stored analysis.
