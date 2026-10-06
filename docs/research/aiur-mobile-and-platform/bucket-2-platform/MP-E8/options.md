---
feature_id: MP-E8
title: Continuous build history (provisional)
artifact: options and recommendations (pre-brainstorm)
base_main_sha: b62d6d05938f3e5a6c91f0901c9b06f3ae099384
date: 2026-10-06
bucket: 2-platform
---

# MP-E8 — options and recommendations

Facts and citations are in [baseline.md](baseline.md) (cited as B§n). This file
proposes designs. It does not write tickets or a DESIGN gate.

**Settled by Kevin:**
- a fixed list of general epics plus short-lived feature epics;
- exactly one epic per ticket;
- epic columns appear and hide with the viewport;
- feature tagging, with a feature view and a compact mode.

**Open:** the time axis (§3). Every other design here is written so that it does not
depend on the time-axis answer. Rows are produced by one replaceable *row-order
function*.

---

## 1. Epic assignment (inside Kevin's model)

The model is decided. The open part is **how a ticket gets its one epic**, given
that 90 % of history carries no epic signal (B§5).

### 1.1 Options

| # | Option | For | Against |
| --- | --- | --- | --- |
| E-A | **Labels only.** Each general epic has a label matcher (for example Bugs ← `bug`, Improvements ← `enhancement`, Infra ← `refactor`, Docs ← `documentation`). A feature epic is a `build-lane:<slug>` on a feature member. Anything else lands in an "Unsorted" column | No new store. Works on GitHub | 659 issues (49 %) match no type label, so "Unsorted" becomes the largest column. Exactly-one breaks when a ticket has both `bug` and `enhancement` |
| E-B | **Registry only.** aiur keeps a local `ticket → epic` map. The Executor or an agent sets it at creation, and a one-time classifier fills history | Exactly-one is enforced by construction. No GitHub writes | Invisible on GitHub. A lost store loses every assignment |
| E-C | **Rule plus override (recommended).** A per-repo config lists the general epics and their label matchers. A precedence rule picks one epic per ticket: (1) a feature epic from the ticket's feature (§2), (2) the first matching general epic in config order, (3) Unsorted. A local override registry holds operator or Executor corrections and the one-time history classification | History needs no GitHub writes. Exactly-one is deterministic. Labels stay the visible signal for new work | Two inputs to explain. The override must be shown ("set by operator") |

### 1.2 Hard constraint: do not use the `epic:` label prefix for membership

`IssueSync` treats any `epic:*` label as **deliberate parking**: it is exempt from
the zero-state-label heal and from the strand sweep
(`src/lib/aiur/orchestrator/issue_sync.ex:480-491`).

- Putting `epic:bugs` on ordinary tickets would silently switch off strand recovery
  for them.
- General-epic matchers must use existing type labels or a new family. The
  candidate name is `area:`. Avoid `epic:`, or change `IssueSync` in the same
  change.

### 1.3 Column visibility

- **Recommended:**
  - General-epic columns keep fixed positions. A general column that is empty in
    the viewport collapses to a narrow labelled rail rather than disappearing, so
    the columns do not shift sideways while scrolling.
  - Feature-epic columns appear when any card in the viewport plus one screen of
    buffer carries them. They are inserted next to their feature's other epics and
    removed with hysteresis (hidden only after they have been out of the buffer
    for one more screen).
- **Alternative (Kevin's literal wording):** every column, general or feature, hides
  when it is empty in the viewport. This is simpler, but cards jump sideways
  whenever a general column toggles. That is a product question (PQ-3).
- **Engineering, resolved:**
  - Visibility is computed on the client from the cards the hook has rendered.
  - The server sends the full column catalogue once. Columns are CSS grid tracks
    collapsed with `grid-template-columns`, not re-rendered.
  - This keeps each LiveView patch small, because the server only adds rows.

### 1.4 Ticket type versus epic

The general epics overlap ticket type (Bugs, Improvements). Two consequences:

- A "ticket type" filter (§6) mostly duplicates the general columns. It is still
  useful **inside feature epics**, for example to find the bugs within a feature.
- If Kevin prefers general epics by *area* (Runtime, Dashboard, Platform, Docs),
  type becomes a pure filter. The built-in lanes (`plan-graph runtime dashboard-ui
  accounting platform`, `metadata.ex:5`) are an existing area seed (PQ-1).

---

## 2. Features: tagging, view, compact mode

### 2.1 What a feature is

A feature has:
- a name and slug;
- one or more feature epics;
- a membership that changes over time;
- optionally, a Build Order root.

General epics have no feature.

**Recommended:** every existing `build-order` root becomes a feature. Its sub-issues
are members by explicit parent link. A small feature can exist without a root.

### 2.2 Where the tag lives

| # | Option | For | Against |
| --- | --- | --- | --- |
| F-A | GitHub label `feature:<slug>` only | Visible on GitHub and in `gh`. The join time is backfillable from `LabeledEvent.createdAt` (B§4.1). Survives store loss | One label per feature pollutes the label list. No place for a name, status, original-scope baseline or epics. A label rename breaks history |
| F-B | aiur registry only | Holds metadata, join events and provenance | Invisible on GitHub. Agents and humans cannot tag from GitHub |
| F-C | **Both (recommended).** The registry is the system of record for feature metadata and the membership journal. `feature:<slug>` is the GitHub projection. A label applied by a human or the Executor is accepted as a join | Visible, recoverable (the registry can be rebuilt from labels and label events), and keeps provenance | Two writers to reconcile. The rule: a label without a registry entry → join recorded with source `label`; a registry join without a label → the label is written (one paced write) |

- **Registry location:** a JSON store under `Config.Paths.decision_state_dir`, the
  same pattern as MP-E1's store (MP-E1 findings F9).
- **Owner:** the `build-orders` component (MP-R1 component map row 119), as
  `Aiur.BuildOrder.Features`. It is *not* a dashboard module.
- **`feature:` must be added to the label families aiur-build's reconciliation
  test accepts.** That test rejects unprojected `agent:*`-style families (MP-E1
  findings F10).
- `feature:` does not start with the configured `agent` prefix, so it is never
  parsed as a state label (MP-E1 findings F1).

### 2.3 One feature per ticket, or several

**Recommended: one.** Reasons:
- It matches "exactly one epic per ticket", because a feature epic belongs to one
  feature.
- It keeps compact mode and the done/total figure unambiguous.

A ticket that serves two features is either:
- in a general epic, and shown as a ghost dependency in both features (§2.6); or
- in the feature that motivated it, as a ghost in the other.

Several features per ticket would need the epic rule to choose which feature
wins, and the done counts would double-count (PQ-6).

### 2.4 How added scope gets tagged (never silently)

| Path | Rule | Join source recorded |
| --- | --- | --- |
| Created as a sub-issue of the feature's root, or by aiur-build with the label | Joins at once. The parent link is explicit intent | `inherited:parent` |
| A human or the Executor applies `feature:<slug>` | Joins at once | `label:<login>` |
| Executor `aiur feature add <slug> <ids…>` | Joins and writes the label | `cli:executor` |
| An open ticket gains a `blocked_by` edge to or from a member, or becomes a sub-issue of a member | **Suggestion only.** One attention, `feature.<slug>.attention.scope_suggested`, lists the candidates. The Executor confirms with `aiur feature add` or dismisses. Dismissals are remembered | `suggested→confirmed:executor` |
| A ticket is created by an agent while working a member (follow-up) | Suggestion (as above), unless the agent passed the feature explicitly through a tool argument that the Executor policy allows | `suggested…` |

There is no auto-tagging from heuristics such as title similarity or lane. The
Executor's confirmation is the gate, which keeps D-style authority (MP-E2 D9)
consistent.

### 2.5 Recording when a ticket joined

- **Use an aiur journal event as the system of record.** The event is
  `feature.<slug>.member.added` / `.removed`, with `{ticket, at, source, actor}`.
  - It is appended to the registry journal.
  - It is published on the bus under the namespace rules in the events-and-replay
    contract §9.
- **Backfill and recovery:**
  - The GitHub timeline gives `LabeledEvent.createdAt` for `feature:` labels.
  - For roots, `SubIssueAddedEvent.createdAt` is available; both were verified
    (B§4.1).
  - The cost is the same 1 point per 100 issues as the history backfill.
  - The daemon filters its own actor's bus events (MP-E1 findings F2). Joins must
    therefore be journaled at the write, not inferred from the bus.
- **Original vs added scope:**
  - The registry stores a **baseline**: the membership at the moment the feature is
    marked "planned". That moment is set by aiur-build at publish, or by
    `aiur feature baseline <slug>`.
  - Joins after the baseline are *added scope*.
  - A feature with no baseline shows all members as original, with a "no baseline"
    note. It must never guess.

### 2.6 Feature view and compact mode

- **Feature view (highlight):**
  - Uses the same visual vocabulary as today's chain pin: non-members at `.3`
    opacity, non-feature edges at `.12` (B§2.6).
  - It is driven by URL state (`?feature=<slug>`), not by client-only state, so it
    survives reloads and can be shared.
  - Chain-pin hover still works inside it.
  - Under forced colors, a non-member gets a dashed outline instead of a fade
    (`aiur-dom-svg-layout`'s fallback, B§2.6).
- **Compact mode (`?feature=<slug>&compact=1`):**
  - Non-member rows are removed. Each run of removed rows is replaced by one
    **gap marker**: "+N unrelated · <first date> – <last date>", or the row-key
    equivalent if the time axis is not date-based. The marker can be expanded in
    place.
  - Every dependency edge to a non-member is kept and drawn to a **ghost node**:
    - a dashed card with `#N`, title, epic chip, state and date;
    - it is placed in the nearest kept row, on the side of its true position;
    - an arrow glyph shows whether the true row is earlier or later.
  - A dependency is never hidden. Clicking a ghost opens the ticket modal.
  - Feature epics stay visible. General epics show only if a member or ghost sits
    in them.
- **Feature summary header (sticky in feature view):**
  - done/total, using **one** completion figure (PQ-7: lifecycle ratio or
    complexity-weighted; B§2.5);
  - a small chart of original vs added scope over time, built from join events
    and `closedAt`;
  - the epics with done/total each;
  - active agents now;
  - the open attentions (failed prerequisite, scope suggestions).

### 2.7 Link to MP-R1-C10's public "planned features"

| Aspect | MP-R1-C10 `features[]` | MP-E8 feature registry |
| --- | --- | --- |
| Scope | aiur's own product roadmap | Any target repo's work packages |
| Storage | A static file (`components.json`) in the aiur repo | Runtime, per instance |
| IDs | `MP-E\|N…` | Slugs |
| Audience | Public docs page | Operator |

**Recommended: do not share one store.** Instead:
- add an optional `tracking: {repo, feature_slug}` field to a C10 entry, so the
  public page can show live progress for the aiur repo's own features;
- add an optional `public_ref` on the registry entry.

Sharing one store would force a per-instance runtime store into a build-time docs
manifest. That is PQ-8.

### 2.8 GitHub API cost (features)

- **Reads:** no extra polling. Labels already arrive with the open-issue poll and
  webhook deliveries (MP-E1 findings F8). The backfill is included in the ~30-point
  history backfill (B§4.2).
- **Writes:** one label write per join (CLI or confirmed suggestion), paced like
  MP-E1 (`max_writes_per_minute` 20).
  - A 60-ticket feature costs 60 writes, about 3 minutes paced.
  - **Recommended:** history is not retro-labelled. Old Build Order roots become
    features in the registry with membership from sub-issues, and **no label
    writes**. Labels are written only for joins from now on.

---

## 3. Time axis (open: options for Kevin)

### 3.1 Options

| # | Row order | Past | Planned | Not queued |
| --- | --- | --- | --- | --- |
| T-A | **Completion time** | `merged_at`, else `closedAt` | Queue rank (MP-E1), levelled into prerequisite waves | Last section |
| T-B | **Start time** | First `agent:in-progress` label or telemetry dispatch | Queue rank | Last section |
| T-C | **Calendar buckets** (day/week rows, DAG layered inside each bucket) | Bucket by completion | Buckets by projected start (needs an estimate) | Last section |
| T-D | **Global topological waves** (today's model, extended) | DAG level | DAG level | Last section |

**T-A**
- For: available for every closed issue at about 30 points. Monotonic. The "now"
  line sits naturally between done and in flight. In-progress tickets sit at "now".
- Against: a ticket worked for 3 days shows at the end only.

**T-B**
- For: shows what ran concurrently, and matches "worked on".
- Against: 379 closed issues never had an `agent:*` label, so they have no start.
  Telemetry covers only 30 days. The fallback is `createdAt`, which mixes the
  meaning of the axis.

**T-C**
- For: a readable date ruler, and gap markers map exactly to dates.
- Against: projected dates are guesses, and every "unknown" must still render
  (AGENTS.md age rule).

**T-D**
- For: the closest to today's grid.
- Against: 91 % of tickets are isolated nodes (B§5), so level 0 holds about 1,250
  tickets. Time is lost.

- **Research leaning, not a decision:** T-A for the past, plus "now" plus queue-rank
  waves for the future. The past rows can carry a date ruler in the gutter (T-C's
  benefit without projected dates).
- **The past/future boundary is always "now":** in-flight tickets (claimed through
  human-review) form a sticky band. That band is the Units "live" scope.

### 3.2 How DAG edges cross time

- **Under T-A**, a satisfied edge points from an earlier row to a later row.
  - An edge whose blocked ticket finished **before** its blocker (a `not_planned`
    blocker, or a manual close) is drawn dashed and amber as an *order violation*.
    It reuses the `:terminal_unsatisfied` classification of `EdgeState`
    (`edge_state.ex:9-22`).
  - An edge from a past ticket to a planned ticket crosses the "now" band.
- **Edges to cards outside the loaded window** end in a stub at the window edge,
  labelled "#N ↑ <date>" or "#N ↓ planned". Clicking the stub scrolls to the card
  (the same visual language as compact-mode ghosts, §2.6).
- **Direction (PQ-4):** the options are past above / future below, or the reverse.
  - **Recommended:** past above, so edges point downward like today's
    blocker-above-blocked layout (`hook:276-317`). The page opens scrolled to
    "now", and the "not queued" section is last.

### 3.3 The planned section and MP-E1

- **When MP-E1 is shipped:**
  - planned = every open item in any queue whose state is not `claimed`, ordered
    by the queue rank;
  - rows are prerequisite levels within the rank;
  - each card carries its contract §2.3 state chip.
- **Before MP-E1 (fallback, if MP-E8 ships first):** planned = open members of
  selected Build Order roots, plus open `agent:todo` tickets, ordered by `phase:N`
  then `sort_issues_for_dispatch` (`priority`, `created_at`).
- **"Not queued"** = open, not a queue item, and carrying no active agent state.
  - That is about 63 tickets today.
  - `needs-triage`, `human:todo`, `agent:paused`/`parked` show as chips.
  - An `agent:todo` ticket outside a queue (a manual promotion, MP-E1
    `overridden`) belongs in **planned**, because the dispatcher will run it.
- **DESIGN-E1's read-only queue panel is subsumed** by the planned section.
  - Recommended: MP-E1 ships CLI-first. Its dashboard view becomes MP-E8's planned
    section, so no throwaway panel is built (PQ-9).
  - If E1 must have a view before E8, keep it as a minimal list on
    `/build-orders`, removed by E8.

---

## 4. Data loading and rendering

### 4.1 Options

| # | Option | Verdict |
| --- | --- | --- |
| D-A | Render all tickets server-side in one grid | Rejected. 1,344 cards and edges in one DOM: the hook measures every card on every patch (`hook:276-317`). Mobile WebView suffers (MP-N1 DV-P6). Growth is about 40 a week |
| D-B | **LiveView streams, windowed by rows (recommended).** The server holds the full ordered index of compact metadata (about 1.4k × ~300 B ≈ 0.4 MB). The client receives only the rows in a window (initially "now" ± about 150 cards) and loads more through `phx-viewport-top`/`phx-viewport-bottom`. Off-window rows are pruned with stream limits | Small DOM. Edges measured only for rendered cards. Stubs cover off-window ends |
| D-C | A client-side virtual list over a JSON feed | Works, but moves rendering out of LiveView, duplicates presenters, and breaks the server-rendered pattern of the existing grid |

### 4.2 Data source: a new durable history store

The caches available today expire: ResourceStore after 72 h, merges after 100,
telemetry after 30 days (B§4). A new store is needed:

- **Name:** `Aiur.BuildOrder.History` (owner `build-orders`).
- **Contents:** an event-sourced index of every issue `{number, title, state,
  stateReason, createdAt, closedAt, merged_at, labels subset, parent, blocked_by,
  epic, feature}`.
- **Feeds:**
  - the existing ResourceStore deposits and the open-issue poll, at zero extra
    polling;
  - one boot-time "closed since last checkpoint" GraphQL page;
  - a one-time backfill of about 30 points.
- **Persistence:** the JSON store pattern (`JsonStore.write!`).
- **Size:** retention is unbounded in count but small (about 0.4 MB per 1.4k issues).
- **Rules:**
  - It is not a cache of record (`apis/github.md:516`). Every row carries
    `observed_at`.
  - The surface renders `observed_at`, age and freshness (AGENTS.md "computed age").
- **Caps:** `GraphAnalysis`'s 100-node truncation (`graph_analysis.ex:10`) must not
  be reused for the global history. Levelling is done per window and per queue,
  and the edge count is small (73 today).

### 4.3 What the page subscribes to

These are the existing topics (B§2.1):
- TicketActivity, running set, AdHocSource, GraphProjection;
- the MP-E1 queue read model, through its PubSub or facts;
- `Aiur.BuildProgress` for headers.

An update patches only the affected stream items.

---

## 5. Merging the Units page

| Stays page-level | Moves into the ticket/agent modal |
| --- | --- |
| The "now" band, which is the old live scope: running cards marked with an agent-family pill, a progress ring and a live pulse | Unit: agent family, model version, `Cx`, priority |
| The active-agent count and nav badge (`dashboard_live.ex:1152-1154`) | Latest: evidence, progress, runtime, turns, context, resume reason |
| Filters and focus (§6) as URL state; the old `scope`/`conditions` become filter presets | Command: pause/resume/lock (`UnitsControlPolicy`, with its server-side re-check), chat, Remote Control |
| Global controls that already live elsewhere (fleet pause, `max-agents`) | Conversation entry: opens the ConversationDrawer today, and MP-E4's conversation with event anchors later |
| The Tickets panel's actions (Add agent) move to the not-queued section's card menu | Ticket context: Description, Dependencies, Logs, Blocked by/Blocking, feature, epic (with its provenance) |

**Engineering, resolved:**

- **The modal:** extend the shared `TicketContext` with a Units section fed by a
  `UnitsRow` for the ticket. The Units row presenter becomes a per-ticket function,
  not a table.
- **Shared plumbing:** BuildOrderLive (or its successor) must load the units payload
  for in-flight tickets only, through `UnitsPresenter.load`'s sources.
- **Moving the controls:** the pause control, chat drawer and `/chat/...` route move
  out of `DashboardLive` into a shared component that both LiveViews mount. They
  stay inside `dashboard-ui`, so this does not cross component boundaries.
- **A modal URL:** `?ticket=<id>`. It does not exist today (B§2.7), and phone
  notifications (MP-N6) and E4 jump points need a deep link.
- **Past cards** have no runtime, turns, context or live conversation. The modal
  shows "not retained" states, not zeros (AGENTS.md unknown-path rule). It shows
  telemetry attempts if they are within 30 days, and the usage aggregate (tokens
  and cost per ticket) for any age.
- **Dead code to delete in the same feature:** `FleetTable`, `FleetFilters`,
  `Overview.fleet_overview`, and the no-op `toggle-fleet-filter`. `AgentLogModal.build`
  stays, because it feeds the composer.
- **Commands** (`/commands`) are untouched.

---

## 6. Filters: highlight with grey-out and focus

| Dimension | Values | Source |
| --- | --- | --- |
| Ticket type | `bug`, `enhancement`, `refactor`, `documentation`, none | labels |
| Agent type | agent family and model (`UnitsPresentation.agent_family`), `model:*` route label | units payload; labels |
| State | active, alert, paused, stuck, queued, finished (the UnitsPolicy conditions), plus planned and not queued | units payload; queue |
| Epic and feature | any | the §1 rule; the registry |
| Priority and complexity | `priority:N`, `complexity:N` | labels |

- **Behaviour (recommended):**
  - A matching card stays at full opacity. Non-matching cards fade to `.3` and their
    edges to `.12`, as in B§2.6.
  - Combination: OR within a dimension and AND across dimensions (the
    `UnitsPolicy` OR is kept inside the condition dimension).
  - The state lives in the URL. It is computed on the server as a `data-dim`
    attribute per card, so the hook only styles it.
  - Chain-pin hover composes with it: a pinned chain overrides the filter fade.
  - A "hide non-matching" toggle reuses compact mode's gap markers (§2.6). That
    gives one mechanism for both.
- **Engineering, resolved:**
  - A server-side `data-dim` keeps the filter on patches without client state.
  - The forced-colors fallback (dashed outline) is required.

---

## 7. Interactions with other features

- **MP-E1:**
  - Supplies the planned section (rank, state chips, waits-on, attentions) through
    `Aiur.BuildQueue`'s read model.
  - DESIGN-E1 §4 (dashboard view, E1-PLACE) becomes MP-E8's planned section (PQ-9).
  - E1's CLI is unchanged.
  - E1's `agent:queued` marker defines "queued" in §3.3.
- **MP-E4:**
  - The modal's "Open conversation" goes to E4's conversation at the latest anchor.
  - E4's event anchors (PR opened/merged, progress, Commands) can show as small
    ticks on the card's history row.
  - Past tickets have no transcript until E4's durable journal exists. The modal
    shows "not retained" for those tickets.
  - DESIGN-E4's "links in from the units table" (line 54) must be re-pointed to the
    MP-E8 modal.
- **MP-R1:**
  - The history store, the feature registry and the page belong to `build-orders`.
  - The Units presenter, controls and drawer stay in `dashboard-ui` as shared
    components.
  - A new edge, build-orders page → dashboard-ui shared components, must be added
    to the component map and checker.
  - The feature registry may later back a `features` capability.
- **aiur-style (#2792):**
  - The scaffold has no components yet.
  - MP-E8's new primitives are candidates to be built once in aiur-style rather
    than in `dashboard.css`:
    - ticket card;
    - ghost node;
    - gap marker;
    - filter chip with fade;
    - sticky band;
    - modal sections.
  - Ordering risk: if aiur-style lands later, these move twice. Coordinate with the
    #2792 plan's dashboard phase.
- **MP-N1/N3 (mobile):**
  - The phone opens this page in a WebView (DV-P6, at 430 px). A multi-column epic
    DAG does not fit.
  - **Recommended phone layout:** one column in the same row order, with an epic
    chip on each card instead of columns, edges hidden behind a "dependencies"
    sheet, and the filters and feature view unchanged.
  - The Units responsive rules (`css:3638-3720`) are retired with the table.
  - MP-N3's per-root progress can come from the feature registry once every root
    is a feature.
- **Stream Deck:** no change, because it has its own projection (B§3.5).

---

---

Product questions for Kevin and the engineering questions resolved here are in
[questions.md](questions.md).
