# GUI

The GUI is Aiur's browser interface for supervising a run. It combines the build history, the live fleet, durable decisions, recorded outcomes, provider meters, Build Orders, and analytics.

High-rate snapshot notifications on Home, Commands, and Stream Deck arrive in batches spaced at least 500 ms apart. Each subscription group holds one unacknowledged batch while newer notifications coalesce by event type. User actions and chat messages keep their existing delivery path.

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
| **Build** | `/` is the continuous build timeline; `/build` is a live alias. [Continuous build history](/concepts/build-history) describes its sections, views, ticket modal and usage strip. Old Build Order links redirect here: `/build-orders/<root>` opens the home focused on the root's imported feature `bo-<root>`. | none; `aiur agents`, `aiur queue show` and `aiur feature show` cover its parts |
| **Units** | CLI fleet inspection; legacy /units URLs redirect to Build. | `aiur units` |
| **Commands** | `/commands` is the durable decision inbox and each decision's detail. **From Executor** filters inbox rows (`?requester=executor`); Executor requests carry a badge. | `aiur commands` |
| **Analytics** | `/analytics` shows latest-run telemetry, with restart fallback and optional Build Order scope. It loads while background analysis runs; concurrent cold loads share one retained-summary scan. The source line identifies live or retained data and its age. A notice marks periods without analytics capture. | `aiur analytics` |
| **Streamdeck** | `/streamdeck` is the browser emulator for the physical Stream Deck + sidecar. | none |

| Route change | Behavior |
| --- | --- |
| `/units` | Permanent redirect to /, preserving the query string. |
| `/chat/:owner/:repository/:identifier` | Redirects same-repository ticket links to `/?ticket=identifier`, opening the Build ticket modal. |
| `/?v=1&scope=…&conditions=…` | Opens Build with the matching legacy Units filter. |
| `/commands` and `/commands/:decision_id` | Current Commands inbox and detail URLs. |
| `/decisions` and `/decisions/:decision_id` | Redirect permanently to the `/commands` equivalents. |
| `/build-orders` and `/build-orders/:root_number` | Redirect permanently to `/` and `/?feature=bo-<root>`; an invalid root opens `/`, and only `ticket` carries over. |
| `/api/v1/decisions`, `decision_id`, event topics | Keep the **decision** vocabulary for compatibility. |

The operator-facing UI and CLI call these records **Commands**.

The Commands inbox keeps all open Commands visible. Routing chips read **With Executor**,
**Needs you**, **Needs you and Executor**, or **From Executor**. Older Commands without
routing facts show **Routing…**. Cards show when they were asked and, after human
routing, how long they have needed you.

Use **Needs you**, **With Executor**, **From Executor**, or **Resolved** to filter;
links preserve `route=needs_you|with_executor|from_executor|resolved`. Open and All
include unrouted Commands. Resolved Commands appear in the history table.

Only Commands routed to you (including those shared with the Executor) count in the
banner and navigation badge. Unknown counts display an
unavailable notice or `—`; partial retained data is labelled partial.

The Executor filter applies to each retained inbox page. Its count is labelled as page-scoped, never a total; partial or unavailable data shows an unknown count. Use **Next retained page** to continue, even when the current page has no matches. Status filter counts and Command history retain their existing scope.

New worker journals recover conversation from the workspace transcript
when it can be replayed, otherwise from this launch's IssueLog. Recovered
records belong to an `import` session after a `pre_journal` gap: earlier history
may still be missing. IssueLog bodies at its 1,000-character cut are marked
truncated. Existing journals are not imported again.

Open the settings cog in the sticky top bar to pause or resume new agent starts, change the theme, or switch between Gruvbox (the default) and the aiur palette. A global pause leaves existing agents running and observed; pause an individual agent from its Build ticket modal for containment.

Pause requires writable access and a known fleet state; an unavailable state reads “Pause state unknown”. The “New starts paused” chip appears only when pause is confirmed.

The theme starts dark until you toggle it. Both choices stay in this browser; another tab keeps its current palette until reload. Fonts are served by the dashboard, including offline.

Drag the navigation edge to switch between icons and labels, or focus the edge and use the arrow keys. The choice stays in this browser. On phones, navigation stays visible in a fixed bottom bar. A red dot on Commands means an answer is waiting; unavailable counts keep their notice instead of showing zero.

Provider usage remains in the [Build usage strip](/concepts/build-history#usage-strip); the legacy Models pane has been retired.

GUI data tables sort by their meaningful column headings. The first click sorts descending, the second reverses the order, and the active heading shows its direction. Icon and action columns are not sortable.

A degraded CODEOWNERS trust banner shows the lookup cause and elapsed age (`age unknown` when unavailable); see [GitHub trust](/apis/github-auth#who-aiur-trusts).

The `sort` query parameter preserves the selected table, column, and direction in copied or refreshed URLs. Paginated and progressively revealed tables sort the displayed rows, then reapply that order when more rows appear.

The Build home page at `/` reads the repository timeline from local stores.
It requires dashboard authentication and loads history by active day in the browser’s time zone.
Live changes are coalesced; snapshots distinguish unavailable sources from empty sections.

List (`?view=list`) shows Live, Planned, Not queued and newest-first History as table rows.
Ticket rows support keyboard focus. Use **Load earlier day** to fetch more history.
Unknown values stay explicit, and degraded section headings show their source state and read age.

The Now band shows active agents between history and the plan. It settles at
the nearest viewport edge; **Live** returns to it. Minimize keeps state counts
visible (`live=min`), and a state preset expands it. The clock shows cached
observation time when stale and `—` when unknown.

Agents in failure back-off carry `agent:retrying` and are counted separately
from running agents. Labels such as `agent:ci-red` and
`agent:paused-usage-limit` appear on cards and in agent-state filters. Tickets
with spent retry latches have no live agent and are left out of Now.

The toolbar selects Timeline, Gantt or List and retains the view in the URL.

In Gantt, history card height represents elapsed run time; idle gaps over three hours fold into hatched bands.
Hatched, dashed planned cards show estimates. A “start unknown” card has minimum height and ends at its recorded end time; unknown estimates stay marked as unknown.

Use Left/Right arrows or Home/End to move between view tabs, then Enter or Space
to select. The status line shows the daemon state, including unknown before
the first snapshot, and the legend for the selected view.

Its links retain view, span, feature focus, filters and ticket selection in
`view`, `span`, `feature`, `fmode`, `epic`, `model`, `tstate`, `astate`,
`live`, `trees` and `ticket`. Invalid values are removed.

Legacy Units
parameters (`v`, `scope`, `conditions`) on the home page become agent-state
or ticket-state presets. The hook bridge replaces the current history entry.
## The pages

### Keyboard

Tab to the Build timeline to reach one ticket card. Use the arrow keys, Home, and End to move through cards in reading order; Enter opens its ticket. Space also opens a ticket, or locks/unlocks its dependency chain when the hidden `?trees=1` mode is active. Escape closes the ticket or tree layer and returns focus to the board.

Card names include complexity. The circled complexity glyphs are decorative.

Each page renders a durable concept whose detail lives in Concepts.

| Page | Concept detail |
| --- | --- |
| Build | [Sections, views, the ticket modal, usage, and unknown states](/concepts/build-history). |
| Units | CLI fleet inspection; /units redirects to /. |
| Commands | [Issues agents flag for the Executor](/concepts/commands). |
| Build Order | [Planning packs, phases, lanes, and dependencies](/concepts/build-orders). |
| Analytics | Lifecycle time, CPU, memory, whole-host fleet/build pressure, concurrency, and cost; missing telemetry stays explicit. |
| Experiments | A separate experiment index and specification detail at `/experiments`; shown when the experiments capability is available. |

A worker holding a native question raises a Command; open Commands to answer it.

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

## Conversations

See [Conversations](/concepts/conversations) for journal storage, retention,
secret handling, earlier history and jump-point precision.

### Answer a Command

Open Commands from this agent appear beside their anchored conversation entry,
with a top link that jumps to the card. A Command with no known position is
pinned above the history and marked **Position unknown**.

The cards use the same
answer controls as the Commands inbox, including multi-question answers and
conflict outcomes. Answers recorded elsewhere update the card live; they never
edit the transcript. Read-only dashboards show cards without answer controls.

### Send a message

On a worker's full conversation page, writable dashboards offer a **Message to
agent** composer. Its read-only mode indicator shows the effective listener
mode, or **mode unknown** when it cannot be observed. Legacy routing retains
the existing send behavior.

**Accepted** means the message was accepted for processing. **Queued** means
the harness queued it (Sync: next boundary), not that the agent read it.
**Saved** in Async means the agent reads it when it chooses. The local delivery
item disappears when the matching operator message enters the journal.

**Failed** shows the reason and restores the message when the draft is empty;
an existing draft is preserved. **Outcome unknown** means delivery cannot be
confirmed: check the agent before retrying. A send with an unknown outcome keeps
the draft; sending the same text again reuses its request ID.

Lost receipts or ten minutes without a journal entry also become unknown; held Async messages
have no ten-minute expiry.

Delivery observations belong to the browser tab and disappear on reconnect.
The journal is the durable record. Read-only dashboards show a notice in place
of the composer.

## Writable controls

| Writable control | Where | Action |
| --- | --- | --- |
| Fleet | Settings cog on Build, Commands, Analytics and Streamdeck | Pause or resume new agent starts. |
| Unit | Build ticket modal | Read the conversation, message or pause the agent. |
| Fleet capacity | CLI | Run `aiur set max-agents <n>`. |
| Ticket | CLI | Queue with `aiur --todo <ticket-id>`. |
| Ticket | Build ticket modal | Add a not-queued ticket to the build queue; pause or resume a running agent. |
| Command | Commands | Answer, replace an undelivered Executor answer, or send a correction. |

Command details include an escalation timeline from recorded facts, with the
cause, absolute time, and relative age. An unavailable timeline is labeled
explicitly.

Native requests show every question together: choose one answer
(or several when offered), select Other to write a response where allowed,
and submit all answers at once.

Suggested responses for single-question
Commands place the recommended option first and mark it Recommended.

On Command detail, **Replace** asks for confirmation before opening an empty answer form. It is available for an Executor answer until delivery starts. A competing answer shows who answered, when, and their answer.

Delivered and in-flight answers show their status and recorded answer. If an answer or replacement attempt loses a delivery race, its form is disabled and **Send a follow-up message** opens the unit chat.

**Send correction** records new direction; it does not undo work already done. Stale Commands offer a refresh, and withdrawn Commands explain why the answer is no longer needed.

Build ticket modal mutations require writable dashboard access. The CLI covers fleet, Unit and capacity controls plus initial Command answers; Command revision remains GUI-only today; the retired ticket-routing preview has no GUI entry.

Disable mutations for an observation-only surface:

```yaml
observability:
  dashboard_writable: false
```

The home ticket modal hides Add to queue when `dashboard_writable` is `false`.

The legacy Units board, Tickets panel and routing preview have been retired. Run `aiur --todo <ticket-id>` from the repository to queue a ticket through the CLI.

Writable requests must also have the expected same-origin `Origin` or `Referer` and `X-Aiur-Request: 1`. These checks supplement authentication; they are not a reason to expose the dashboard publicly.

### Retired drawer controls

The Units conversation drawer and its listener selector, interactive worker voice
chat and Executor voice prototype controls have been retired.

Backend listener
modes and Executor voice APIs remain available; their configuration is documented
in [voice configuration](/reference/configuration-voice). Build retains message
sending and dictation; full conversation pages retain their own composer.

See [Executor voice](/guide/executor-voice) for shared Executor composer support.


## Authentication and network exposure

Browser access supports Google sign-in and passkeys. On loopback, Basic Auth remains available as a browser fallback. Machine clients can use individually revocable bearer tokens created with `aiur token create`:

```bash
export AIUR_DASHBOARD_USERNAME=example-executor
export AIUR_DASHBOARD_PASSWORD='replace-with-a-strong-secret'
aiur
```

Public binds require machine credentials, browser Basic Auth off, and Google sign-in with an email allowlist or an enrolled passkey. Basic Auth is refused on every route when the dashboard binds beyond loopback. Loopback may bind without machine credentials, but refuses dashboard requests until they are set.

To enable Google sign-in, configure an HTTPS `server.public_url`, set the operator email allowlist, and add both OAuth client values to `~/.aiur/.env`:

```yaml
server:
  public_url: https://dashboard.example.com
  trusted_proxies: [10.0.0.0/8]
dashboard_auth:
  google:
    allowed_emails: [operator@gmail.com]
  passkeys: true
  session_max_age_days: 30
  browser_basic_auth: false
```

Replace the CIDR with the actual proxy peer range. The `platform` shortcut trusts private IPv4 and IPv6 peers and is safe only when the host platform isolates that network from untrusted workloads. Public deployments must keep browser Basic Auth off and use bearer tokens for machine clients.

In Google Cloud, create an OAuth consent screen in External / Testing mode, add the operator as a test user, and request `openid email`. Create a Web application OAuth client with redirect URI `https://dashboard.example.com/auth/google/callback`.

Put `AIUR_GOOGLE_CLIENT_ID` and `AIUR_GOOGLE_CLIENT_SECRET` in `~/.aiur/.env`, then restart Aiur. Sign in with the allowlisted, verified account and register a passkey while that Google sign-in is fresh; enroll each device (iCloud Keychain can sync Apple devices).

Google and passkey sessions also require `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD` to be configured for browser sign-in.

After confirming Google and passkey sign-in, set `dashboard_auth.browser_basic_auth: false` and restart Aiur; this setting is read at startup. Machine API clients can use individually revocable bearer tokens created with `aiur token create`; browser routes continue to use sign-in sessions.

Put remote access behind a private network or trusted reverse proxy and use TLS there; Basic Auth does not encrypt transport.

The supervisor Decision API has a separate bearer credential, `AIUR_SUPERVISOR_TOKEN`. Generate one with `openssl rand -base64 32`, then put `AIUR_SUPERVISOR_TOKEN=<generated-token>` in `~/.aiur/.env` for all projects or the repository `.env` for one project.

An exported value wins, then the global file, then the repository file. The token must be at least 32 bytes, bearer-safe, and free of surrounding whitespace. A present non-empty invalid value aborts startup, while an absent or empty value leaves the API disabled.

Dashboard credentials never grant machine-API authority, and the bearer token never signs a human browser action.

The Analytics ticket timeline marks the earliest PR-open time. Open PRs appear in review; merged, rework, and paused states take precedence.

Retained Analytics charts use at most 180 evenly spaced resource observations per actor, including the first and last. Chart detail is sampled; headline CPU totals and resource peaks use the full retained profiles.

Full log combines newest runs that fit its bounded projection with current telemetry. Latest-run fallback and Full log decode at most 45 MiB per cold load. The source line reports included runs and omissions, and names skipped newer runs in Latest-run. Analytics is unavailable if none fit; without materialized history, raw files over 1 MiB are unavailable.

The Build page usage strip shows API budgets and provider windows or credits. Bars and labels show what remains: full is 100% left, empty is unusable until reset, with warning colours near empty. Hover or focus a usage line for account details, observation age, GitHub snapshot age, and budget holds.

Build cards keep agent pause causes distinct: provider usage limits read `Paused · usage limit` with a reset time when the runtime reports one, CI handoffs read `Waiting for CI`, and `Parked` identifies other non-reserving pauses.

Unknown readings stay marked as unobserved; expired windows and stale readings are identified explicitly. Reset labels refresh every 30 seconds while the tab is visible. Locked sessions show an authentication message without financial values.

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

## Open a full conversation

Select **Open in conversation** from a Command with a known conversation position,
or navigate to `/conversations/:conversation_id`. The legacy Units and drawer
links have retired with the board.

A conversation without recorded messages shows **No messages yet**. Until its
journal exists, it also says **Conversation not found**; storage failures show
**Conversation unavailable** instead. The first recorded message appears without
reloading the page.

The event navigation lists progress, pushes, PRs and Commands. Select an event
to jump to and highlight its transcript position. Filter chips include CI and
reviews when needed. **Approximate position** means the event was observed near
that entry; it does not claim an exact causal match.

On phones the event list
sits above the transcript and scrolls independently.

`/conversations/:conversation_id` opens the durable conversation page. Read-only
dashboards keep the transcript and event navigation available; sending requires
writable access and an available listener.

It starts with the latest 50 entries. **Load older**, **Jump to start**,
and **Load newer** browse earlier history; **Latest entries** returns to the
live tail.

Agent prose uses Markdown. Reasoning and command or tool output start collapsed;
select a summary to expand it. File edits show diffs. Operator bubbles, session
dividers and gap rows keep the source and continuity visible. See
[Reading entries](/concepts/conversations#reading-entries) for masking and
truncation details.

The page keeps up to 500 entries on screen. When you scroll up,
new entries show a counter that returns you to the latest page.

The status distinguishes live, idle, ended, continuity unknown and unavailable
history. Journal failures keep the last readable content with a stale marker
and observation age. Imported history shows **Earlier history is not available**.

## Read a conversation over HTTP

These read-only routes use dashboard authentication or a read client token,
including when
`dashboard_writable` is false. Responses set `Cache-Control: no-store`:

- `GET /api/v1/conversations/resolve?subject=executor`
- `GET /api/v1/conversations/resolve?subject=worker&owner=OWNER&repository=REPO&identifier=NUMBER`
- `GET /api/v1/conversations/ID/entries`
- `GET /api/v1/conversations/ID/sessions`
- `GET /api/v1/conversations/ID/anchors`

Resolve returns `conversation_id` and `subject`. Worker lookup uses the full
repository and stored provider identity; multiple conversations matching a
transferred issue return `409 ambiguous_subject` with `conversation_ids`.
No matching subject returns `404 subject_not_found`.

Entries default to the last 50 positions in ascending order. Choose one of
`tail=true`, `from_start=true`, `before=POS`, `after=POS`, or `around=POS`,
with `limit=1..200` and optional comma-separated `kinds`. Follow `prev_cursor`
with `before` or `next_cursor` with `after`; null means that direction is
complete.

Pages include sessions, `head_pos`, `complete_from_start`, and
`observed_at`. An existing empty conversation returns an empty page with
`head_pos: 0`; an unknown ID returns `404 conversation_not_found`. Unreadable
storage returns `503 conversation_unavailable`; invalid cursors or limits
return 422.

Anchors accept `kinds`, `pos_from` and `pos_to` (inclusive).
Sessions contain no local source paths.

Conversation text can contain secrets. Body and output are masked by default;
`reveal=true` is honored only for an authenticated operator connecting from
loopback. Device principals and client tokens always remain masked. Basic Auth is refused
on public binds. Treat revealed content as sensitive.

Write verbs return 405; sends continue through the listener path.
