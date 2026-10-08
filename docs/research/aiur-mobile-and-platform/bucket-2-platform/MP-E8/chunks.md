---
feature_id: MP-E8
artifact: chunks
base_main_sha: 58854d4c8
design_source: design-source/ (etag 1791431544512943, imported 2026-10-08)
date: 2026-10-07
owner_gate: DESIGN-E8
---

# MP-E8 chunks

Plan: [plan.md](plan.md). Ticket work-order: [tickets/README.md](tickets/README.md).

**Every MP-E8 ticket is blocked on DESIGN-E8** (Kevin's explicit go plus the
open sign-off items in [../../owner-design-tasks/DESIGN-E8.md](../../owner-design-tasks/DESIGN-E8.md)).
Some tickets follow the default of a numbered owner question in
[questions.md](questions.md) (OQ-E8-n) or a sign-off item (S-n). That is a
default to follow, not a blocker; only C13-T03 truly waits (on S-8).

Abbreviations: `J` = `design-source/assets/build.js`, `C` = `design-source/assets/build.css`,
`H` = `design-source/Aiur Dashboard.html`. Line numbers are in the imported copy.

There are 14 chunks and 76 tickets. Chunk order is the build order inside E8,
except C4–C8 (server data), which run in parallel with C2, C3 and C9–C11 (client).
Six client tickets still wait on server tickets (tickets/README.md lists them).

| Chunk | Name | Tickets | Runs in |
| --- | --- | --- | --- |
| C1 | Parity harness and design fixtures | 3 | wave 0b, first |
| C2 | Shell, tokens, palette, fonts, assets, CSS | 4 | wave 0b |
| C3 | Home LiveView, data seam, payload protocol, URL state | 3 | wave 0b |
| C4 | Durable history store | 5 | wave 0b |
| C5 | Epics | 4 | wave 0b |
| C6 | Features | 5 | wave 0b |
| C7 | Planned, not-queued and estimates | 4 | wave 0b (after MP-E1) |
| C8 | Live state, usage, daemon status, ticket index | 4 | wave 0b |
| C9 | Client timeline engine (port of build.js) | 13 | wave 0b |
| C10 | Toolbar, filters, feature header, usage strip | 4 | wave 0b |
| C11 | Ticket modal and agent chat (read and write) | 10 | wave 0b |
| C12 | Cutover, retirement, mobile, accessibility, performance, docs, sign-off | 8 | wave 0b, last |
| C13 | History classification backfill (E8-D10) | 5 | after cutover |
| C14 | Later-wave upgrades (E4, E7, E2) | 4 | waves 2–3 |

---

## MP-E8-C1 — Parity harness and design fixtures

**Purpose.** "Pixel-perfect" needs a machine check, or it is only a hope. This
chunk makes the design file and the product render the same data at the same
clock, and compares them. Every visual ticket proves itself with this harness.

**Contents.**
- An exporter that runs the unmodified `build.js` data generator (`build(kind)`,
  `dataFor`, J:113–297) in a Node VM with a fixed `NOW` (J:11) and writes the five
  datasets (`live`, `dense`, `newrepo`, `noqueue`, `offline`) as JSON fixtures in
  the product's payload schema. The design file is never edited (IMPORTED.md).
- A Playwright side-by-side screenshot runner: the design HTML served as static
  files with `?example=<dataset>`, the product at its fixture route, at fixed
  viewports (1440, 1024, 390 px), light and dark, frozen clock, fixed time zone,
  local fonts.
- Motion and interaction scripts: the live-band snap (J:583–602, 1234–1241), the
  modal open (`tkin`, H:1599) and close, column enter and leave (J:795–804), view
  switches, the grain (C:1126–1139), the minimap drag.

**Predecessors.** DESIGN-E8 only. Reuses the existing browser harness
(`src/test/browser/`, `src/test/support/browser_harness/`) and
`website/tests/visual.spec.ts` as the pattern.

**Design gate.** DESIGN-E8 acceptance is Kevin's side-by-side sign-off. C1 produces
the evidence for it.

## MP-E8-C2 — Shell, tokens, palette, fonts, assets, CSS

**Purpose.** The design is a whole-dashboard file. Around `#build-root` it changes
the shared shell: the `.ax-top` bar with the settings cog (pause all, theme,
palette), the draggable and collapsible `.sidenav` with tab counts, the decisions
banner, the page head, the Gruvbox palette (the design default) and new tokens.
The home page cannot match the design inside today's `DashboardShell` chrome.

**Contents.**
- Tokens and palettes: the `:root` and `html[data-theme="light"]` tokens (H:22–124),
  the Gruvbox palette (C:1027–1076, 1141–1154), the body wash (H:128–139,
  C:1069–1075), token aliases (`--block*`, `--attn*`, `--board-bg`).
- Self-hosted fonts (Space Grotesk, JetBrains Mono; Bungee is already shipped). No
  Google Fonts or d3 CDN at run time.
- The shell restyle of `AiurWeb.OperatorControlCenter.DashboardShell` to `.ax-top`,
  `.ax-brand`, `.ax-set`/`.ax-menu`, `.sidenav`/`.snav`, `--navw` drag, keeping its
  server-owned collapse state (#1306) and writable-gated pause.
- Assets into `src/priv/static`, and one consolidated stylesheet for the home page
  built from `build.css` with dead rules removed and no change to computed styles.

**Predecessors.** C1-T02 (the parity check) for C2-T01, C2-T02 and C2-T04;
C2-T03 is level 0. Cross-feature: none. The shell change touches every dashboard
page (OQ-E8-1).

**Design gate.** DESIGN-E8 sign-off items S-1 (app-wide shell and palette) and S-2
(Khala nav item).

## MP-E8-C3 — Home LiveView, data seam, payload protocol, URL state

**Purpose.** One LiveView owns the page, authorization, URL state and every write.
A JavaScript hook, ported from `build.js`, owns layout and drawing. A behaviour
(`DataSource`) is the seam MP-R1 later moves without a rewrite (E8-D14).

**Contents.**
- `AiurWeb.BuildLive` (PROPOSED) at a temporary route behind no config key, the
  `AiurWeb.Build.DataSource` behaviour, and a fixture implementation that serves the
  C1 fixtures.
- Payload schema v1: compact ticket rows, epics, features, order, counts, usage,
  daemon status; diffs by ticket id with a generation number; full resync on a
  gap or a rejoin; size budget.
- Server-side URL state: every design parameter (`view`, `span`, `feature`, `fmode`,
  `epic`, `model`, `tstate`, `astate`, `live`, `trees`, `ticket`; J:304–328) parsed and
  validated in `handle_params`; the hook patches the URL with LiveView, not with a
  bare `history.replaceState`.
- A source-scan test and a component-map request.

**Predecessors.** C1-T01, C2-T03. Cross-feature: none. MP-R1 later moves this seam.

**Design gate.** DESIGN-E8.

## MP-E8-C4 — Durable history store

**Purpose.** Today no cache keeps closed tickets: ResourceStore expires after 72 h,
merges after 100 rows, telemetry after 30 days (baseline §4). The page needs every
closed ticket with its start, end, epic signals and edges.

**Contents.**
- `Aiur.BuildOrder.History` (PROPOSED, owner `build-orders`): an event-sourced,
  persisted index of every issue with `observed_at` on every row.
- A one-time, daemon-owned, paced, resumable backfill (about 30 GraphQL points,
  measured 2026-10-06).
- A steady-state feed from existing deposits and polls plus one "closed since the
  checkpoint" page per boot.
- Start and end derivation (Gantt), with "start unknown" as an explicit value.
- Historic `blocked_by` edges, the children index, and order-violation edges.

**Predecessors.** DESIGN-E8 (only for the visible "start unknown" state). Reads
`website/docs-app/apis/github.md` rules. Cross-feature: none.

**Design gate.** DESIGN-E8 sign-off item S-5 (start-unknown Gantt card).

## MP-E8-C5 — Epics

**Purpose.** Every ticket has exactly one epic (E8-D1). About 90 % of history has
no epic signal (baseline §5), so a rule, a per-repository config and an easy
override with provenance are needed (E8-D9).

**Contents.**
- A config section with the default general epics Bugs, Design, Infra, Docs and
  their label matchers. Never the `epic:` prefix: `IssueSync` treats it as
  deliberate parking (options §1.2).
- A pure resolver: feature epic, then override, then first matching general epic,
  then Unsorted.
- An override registry with who, when and source, and a batch CLI that agents can
  call.
- Skill and prompt guidance (aiur-build, aiur-run, aiur-agent, planner prompts).

**Predecessors.** None for C5-T01..T03; C5-T04 waits on C6-T04 and C7-T03.
Cross-feature: none.

**Design gate.** DESIGN-E8 (epic hues and icons come from the design: `GENERAL`,
J:96).

## MP-E8-C6 — Features

**Purpose.** A feature is a named, growing package of tickets with its own epics
(E8-D2), one owning feature per ticket plus "also affects" links (E8-D11), and
original-versus-added scope.

**Contents.**
- `Aiur.BuildOrder.Features` (PROPOSED) registry and membership journal (join and
  leave events with source and actor), baseline, also-affects links, feature epics.
- The `feature:<slug>` label projection and its reconciliation.
- Existing Build Order roots imported as features, with no label writes.
- A `aiur feature` CLI.
- Feature statistics (port of `featStats`, J:343–352): done/total, weighted %,
  original → now, the daily scope series, the also-affects count.

**Predecessors.** C5-T02 (feature epics feed the resolver); C4-T01 (C6-T05).
Cross-feature: none.

**Design gate.** DESIGN-E8 (feature hues: the design assigns them in `addF`, J:118;
OQ-E8-6 asks how a real feature gets its hue).

## MP-E8-C7 — Planned, not-queued and estimates

**Purpose.** The forward part of the page: the planned section in MP-E1 queue
order with dependency waves and cues, unfiled planning-pack items, the not-queued
section, and estimated hours with recorded overrides (E8-D3, E8-D7). This chunk
replaces MP-E1-C8 (E8-D14).

**Contents.**
- Planned rows from `Aiur.BuildQueue.show/1` (MP-E1-C6-T01): queue position,
  waves, cues (promoted age, held by and why, waits on, prerequisite failed with
  the tickets it blocks, prerequisite chain failed, estimate overridden).
- "Planned · not filed" rows from planning packs (`AiurWeb.BuildOrder.PlanningSource`).
- Estimates: a default from complexity, an override store with reason and actor,
  a CLI, and the ETA figure.
- Not-queued rows.

**Predecessors.** C4-T01. Cross-feature: MP-E1-C6-T01, MP-E1-C7-T02,
MP-E1-C5-T02, MP-E1-C6-T02 (for "Add to queue", consumed by C11-T02).

**Design gate.** DESIGN-E8; OQ-E8-7 (estimate source).

## MP-E8-C8 — Live state, usage, daemon status, ticket index

**Purpose.** Build the one ticket index the page renders, and keep it live.

**Contents.**
- Now-band rows from the per-ticket Units row: model and harness to logo, agent
  state to the six design states (`AST`, J:88–91), progress, start, estimate.
- Usage strip data from the existing provider meters and the GitHub budget.
- Daemon and freshness signals (live, stale, offline, cached time).
- The index assembler: joins C4–C8 sources, subscribes to the existing PubSub
  topics, coalesces changes into diffs, and serves history by day.

**Predecessors.** C3-T02, C4-T03, C5-T02, C6-T05, C7-T01, C7-T04.

**Design gate.** DESIGN-E8.

## MP-E8-C9 — Client timeline engine (port of build.js)

**Purpose.** The page's layout and drawing, ported from `build.js` with the mock
data removed and the real payload put in its place. The port keeps the DOM, class
names, constants and timings, so the parity harness can pass.

**Contents.** One ticket per subsystem: hook shell and scrollbar; timeline layout
and density tiers; virtualised rendering and history paging; dynamic epic columns;
cards; agent indicators; edges; the now band with its snap; Gantt; span and zoom;
dependency chains and the whole-tree view; the list view; loading, empty and stale
states.

**Predecessors.** C2-T04, C3-T02, C3-T03; C4-T04 (C9-T09); C8-T03 (C9-T13).

**Design gate.** DESIGN-E8; S-3 (`?trees=1` only), S-4 (agent-state glyph absent),
S-5 (start unknown), S-9 (unavailable vs empty), S-13 (unknown model logo),
S-17 (`not_planned` look).

## MP-E8-C10 — Toolbar, filters, feature header, usage strip

**Purpose.** The controls above the board.

**Contents.** View switcher and right tools; the status line without the demo
selector; the five filter groups and their popovers; the feature header with focus
and compact modes (gap markers and ghosts); the usage strip.

**Predecessors.** C9-T01, C9-T05, C9-T09; C8-T04 (C10-T02), C6-T05 (C10-T03),
C8-T02 (C10-T04).

**Design gate.** DESIGN-E8; OQ-E8-4 (type filter absent), OQ-E8-8 (models counter),
S-17 (`not_planned` look).

## MP-E8-C11 — Ticket modal and agent chat (read and write)

**Purpose.** The ticket/agent modal with `?ticket=`, the issue view for tickets
without an agent, and the conversation with its minimap preview sidebar, composer,
Command answer card, pause and resume, and dictation. This is the read and write
path to every agent chat.

**Contents.**
- The modal frame and deep link; the doc variant; the conversation read seam with
  a wave-0b adapter over today's transcript source; events in the log; the
  minimap; the composer through today's send path; pause and resume; the Command
  answer card; the microphone.

**Predecessors.** C3-T03, C9-T05 (C11-T01); C7-T01 and MP-E1-C6-T02 (C11-T02).
Cross-feature consumed later by C14. C11-T10 is conditional on OQ-E8-5.

**Ownership.** E8 owns the modal's chat UI and its wave-0b data adapters. MP-E4
owns the journal, history API, anchors and the full conversation page. MP-E7 owns
send routing. See plan §6.

**Design gate.** DESIGN-E8; S-6 (conversation not retained), S-7 (send failure
states), S-10 (ticket not found), S-11 (mic without voice), S-14 (Add to queue
states), S-15 (loading older entries), OQ-E8-5 (Units fields the design drops),
OQ-E8-10 (parked send).

## MP-E8-C12 — Cutover, retirement, mobile, accessibility, performance, docs, sign-off

**Purpose.** Make the page `/`, retire Units and the Build Order nav, prove it on a
phone, with a keyboard and with thousands of tickets, document it, and package the
sign-off.

**Contents.** Route cutover with legacy redirects and a rollback route; Build
Order route retirement; dead-code deletion; mobile and WebView; accessibility;
performance budget; docs; the final parity package.

**Predecessors.** C9, C10, C11-T01..T08 and C11-T10 on real data (C8-T04).
C11-T09 is not a cutover blocker.

**Design gate.** DESIGN-E8 acceptance (Kevin's side-by-side sign-off); S-12
(focus rings); S-16 (Reconnect states).

## MP-E8-C13 — History classification backfill (E8-D10)

**Purpose.** Put past tickets into epics and features with an agent, slowly and
under a budget cap, after the page has shipped.

**Contents.** An export CLI first; then a cost measurement on real exported
tickets; an agent runbook that uses the C5 and C6 batch CLIs with source
`backfill-agent`; optional paced label writes; the display and confirmation of
unconfirmed classifications (DESIGN-E8 item 10).

**Predecessors.** C12-T01, C5-T03, C6-T04.

**Design gate.** DESIGN-E8 sign-off item S-8 (how unconfirmed classifications look).

## MP-E8-C14 — Later-wave upgrades

**Purpose.** Swap the wave-0b adapters for the later contracts without changing
the UI.

**Contents.** Conversation reads from `Aiur.Conversation.History` and anchors
(MP-E4); delivery receipts and overlay (MP-E4-C6-T01, MP-E7-C3-T04); "Open in
Conversations" to `ConversationLive`; Command answers through the MP-E2 contract.

**Predecessors.** The named MP-E4, MP-E7 and MP-E2 tickets.

**Design gate.** DESIGN-E8 plus DESIGN-E4 and DESIGN-E7 for their own copy.
