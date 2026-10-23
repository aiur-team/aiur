# Continuous build history

A repository has one continuous build. Feature collections group work added over
time: a new feature, epic, bug batch, or experiment joins the existing build,
with its research and design evidence preserved. Existing [Build Order
roots](./build-orders) remain readable history and import as `bo-<number>`
features; new features do not need another root.

## The Build page

The dashboard home `/` (also served at `/build`) shows this build as one board.
Its navigation item is **Build**; the badge counts running agents, independent
of filters, and an unknown count is omitted.

<img src="/images/dashboard/build-dark.png" alt="Desktop Build page with the usage strip, the Live band and synthetic planned tickets">

The board has four sections.

| Section | Contents |
| --- | --- |
| **History** | Closed tickets by real end time, newest at the boundary with Live; earlier days load as you scroll up. |
| **Live** | The Now band of tickets with an active agent. |
| **Planned** | Build-queue members in queue order, grouped into dependency waves; unfiled pack members read **Planned · not filed**. |
| **Not queued** | Open tickets that are not in the build queue. |

The page reads the repository timeline from local stores. It requires dashboard
authentication and loads history by active day in the browser’s time zone.
Live changes are coalesced; snapshots distinguish unavailable sources from empty
sections.

## Epics

Each ticket appears under exactly one epic column, resolved in this order:

| Step | Source |
| --- | --- |
| 1 | The owning feature's epic. |
| 2 | A local override set with [`aiur epic set`](/reference/build-history-commands#epics). |
| 3 | The first configured general epic whose labels match the ticket. |
| 4 | **Unsorted**. |

General epics come from `build_order.general_epics`; see
[General epics](/reference/configuration-build-order#general-epics) for the
defaults. Feature collections are managed with [feature
commands](/reference/build-history-commands#features).

## Views and controls

The toolbar selects **Timeline**, **Gantt** or **List** and keeps the view in
the URL. Use Left/Right arrows or Home/End to move between view tabs, then Enter
or Space to select. Timeline and Gantt add **Day**, **Week** and **Month** range
buttons.

The status line shows the daemon state, including unknown before the first
snapshot, and the legend for the selected view: **Cleared** and **Pending**
edges, plus **Planned estimate** in Gantt.

In Gantt, history card height represents elapsed run time; idle gaps over three
hours fold into hatched bands. Hatched, dashed planned cards show estimates. A
“Start unknown” card has minimum height and ends at its recorded end time.

List (`?view=list`) shows Live, Planned, Not queued and newest-first History as
table rows. Ticket rows support keyboard focus. Use **Load earlier day** to fetch
more history.

Links retain view, span, feature focus, filters and ticket selection in `view`,
`span`, `feature`, `fmode`, `epic`, `model`, `tstate`, `astate`, `live`, `trees`
and `ticket`. Invalid values are removed.

Legacy Units parameters (`v`, `scope`, `conditions`) on the home page become
agent-state or ticket-state presets. The hook bridge replaces the current
history entry.

## The Live band

The Live band shows active agents between history and the plan. It settles at
the nearest viewport edge; the **Live** button returns to it. Minimize keeps
state counts visible (`live=min`), and a state preset expands it. The clock shows
cached observation time when stale and `—` when unknown.

Each agent card names its state in text, not colour alone.

| State | Meaning |
| --- | --- |
| **Running** | The agent is starting or working. |
| **Retrying** | The agent is in retry backoff; counted separately from running agents. |
| **Error** | The agent hit an error or is stuck. |
| **Awaiting command** | The agent raised a Command that is still open. |
| **Paused** | The agent is paused. |
| **Parked** | The agent is paused without reserving a slot, for example during a GitHub budget hold. |
| **State unknown** | Aiur could not determine the agent's state. |

Tickets whose lifetime retry latch is spent have no live agent and are left out
of Live.

## Ticket cards and the modal

Tickets render as full, line, mini or bar cards as space changes. Full cards
show complexity, section status and queue cues. Unknown progress, points and
estimates read `—`; unknown progress has no progress bar. Closed tickets
distinguish merged, failed, not planned and other closed outcomes.

Open a card, or a `/?ticket=<number>` link, to read the ticket's conversation.
The modal starts with the newest entries; scroll to the top to load earlier
ones. A missing past transcript reads “Conversation not retained”, and an
unknown ticket reads “Ticket not found”.

Remote workers show only their retained live window; stale or unavailable live
state is labeled separately from the transcript.

On a writable dashboard, a Not queued ticket's modal offers **Add to queue**.
In a running ticket's modal, use **Pause agent** or **Resume agent** with writable
access. The button waits for the agent's confirmation; a change from the TUI or
another tab takes precedence.

Pending, unavailable and failed requests explain
why through the button's accessible label. **Open in Conversations** stays hidden
until a full conversation page is available; legacy `/chat/...` links return to
the ticket modal.

Pause, resume and message an agent with [`aiur pause`, `aiur resume` and `aiur
message`](/reference/cli#inspect-and-operate-a-running-daemon).

## Usage strip

Hover or focus a usage line for account details, observation age, GitHub
snapshot age and budget holds.

The usage strip has an **APIs** card and a **Models** card.

| Row | What it shows |
| --- | --- |
| GitHub | REST core and GraphQL budget used in the current hour; see [GitHub API budgets](/apis/github-budgets#api-budgets). |
| ElevenLabs | Credit quota used, only when a key is configured; see [ElevenLabs metering](/apis/elevenlabs#what-the-usage-meter-measures). |
| Models | Session and weekly windows or credits for each configured provider. |

A provider that reports no limits reads **not observed**. Expired windows and
stale readings are identified explicitly. Reset labels refresh every 30 seconds
while the tab is visible. Locked sessions show an authentication message
without financial values.

## Unknown and stale states

An unknown value is never shown as `0` or as a plausible default.

| Case | What renders |
| --- | --- |
| Unknown progress, points or estimate | `—`, with no progress bar. |
| History, queue or open-ticket read failed | An unavailable marker with its cause and the last successful read, instead of an empty section. |
| Stale or partial read | The section header names the state and the read age. |
| Disabled source | The section keeps its reason. |
| Meter with no reading | **not observed**. |
| Gantt card with no start | “Start unknown”, at minimum height. |

The build timeline labels daemon state separately from socket reachability. An
offline or stale snapshot shows its last heartbeat age and local time; a missing
heartbeat reads “no heartbeat recorded”.

Socket loss lasting at least 500 ms shows “Daemon unreachable” and stops the
live glows. While the socket is open but the fleet snapshot is unread, the
footer reads “Daemon up · unread” with the age of the last good reading.

A source that a GitHub budget hold delays is named in the footer with the age of
its last read, for example “history held 2m”. Hover the footer for the full
sentence.

Before the first timeline load finishes, the footer shows the last daemon state
the server read, with its age. A recent reading can show “Daemon live · <1m ago”;
a reading 30 seconds old or older shows “Daemon
stale” with its age and the dot turned off. It reads “Daemon status unknown”
only when no daemon state has been observed yet.

Filters and unloaded history days have distinct empty messages. Before the first
snapshot, the timeline shows a loading skeleton; a failed initial read stops its
animation.

**Reconnect** retries a dropped socket immediately, or requests a fresh snapshot
when the socket is open. It reads “Reconnecting…” while pending and returns to
**Reconnect** after ten seconds if the page is still degraded. This control also
works with read-only access.

## What stays on the Units page

The Units page is the hidden rollback route `/units`, retained for one release.
Orchestration turns, context occupancy, cumulative token usage, the Tickets
panel and its routing preview stay there and in `aiur units`; see
[Units](/concepts/units).

## Adding work

The Executor files authorized work with `feature:<slug>` labels, registers its
owning collection through [feature commands](../reference/build-history-commands#features),
writes native `blocked_by` links for real prerequisites, and adds executable
tickets to the [build queue](./ticket-lifecycle#build-queue).

Prerequisites can
cross collection boundaries. Feature membership groups tickets; queue membership
schedules them when their prerequisites clear.

These are separate writes. Intake is complete only after the Executor reads back
the collection, projected labels, prerequisite links, queue membership, and order.

`aiur feature show <slug> --json` and `aiur queue show --json` provide those
checks; `aiur build-orders` reads legacy roots. Unknown or stale evidence does
not prove placement.

Only an explicit operator exclusion leaves filed work outside the build, parked
with `needs-triage` or `human:todo` and the reason. This default does not authorize
the Executor to file unsolicited work or expand a feature's acceptance boundary.

## Prioritizing work

“Prioritize” or “pull ahead” means place the new work before the previous next-up
using both a priority label and queue ordering. The Executor reports what it
displaced and verifies effective start order.

Within a list it adjusts ticket
positions; across lists it adjusts set ranks, which requires
`build_queue.set_order: ranked`. See [queue commands](../reference/cli#dashboard-page-commands).

Priority preserves real prerequisites, holds, and running agents. When a blocker
prevents immediate pickup, the Executor reports that constraint and the next
eligible work instead of claiming the new collection will start immediately.

Unfiled planning-pack items follow filed planned tickets in pack wave order. They
show a source document instead of a GitHub number and cannot be added to the queue.
Their copied links continue to open the real ticket after the pack records its number.

When packs cannot be read, **Planning packs unavailable** names the affected packs
and shows when they were checked; readable packs and queued tickets remain visible.
Pack writes refresh on the next index flush, including its ten-second daemon tick.
Between issue creation and rewriting the pack, both rows may briefly appear.
