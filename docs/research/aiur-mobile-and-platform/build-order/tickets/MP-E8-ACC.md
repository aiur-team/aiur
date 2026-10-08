# MP-E8-ACC — MP-E8 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-E8-C2-T02, MP-E8-C5-T04, MP-E8-C11-T10, MP-E8-C12-T02, MP-E8-C13-T02, MP-E8-C13-T03, MP-E8-C14-T02, MP-E8-C14-T03, MP-E8-C14-T04

## Outcome

The Executor proves MP-E8 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-E8/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (76)

- MP-E8-C1-T01 — Design fixture exporter
- MP-E8-C1-T02 — Side-by-side screenshot parity runner
- MP-E8-C1-T03 — Motion and interaction parity scripts
- MP-E8-C2-T01 — Tokens, Gruvbox palette, body wash, self-hosted fonts
- MP-E8-C2-T02 — App shell restyle (top bar, cog menu, sidenav)
- MP-E8-C2-T03 — Static assets and the four-place hook registration
- MP-E8-C2-T04 — Consolidated home stylesheet from build.css
- MP-E8-C3-T01 — BuildLive, DataSource behaviour, fixture source, seam scan
- MP-E8-C3-T02 — Payload schema v1, diff and resync protocol
- MP-E8-C3-T03 — Server-owned URL state and legacy URL presets
- MP-E8-C4-T01 — Aiur.BuildOrder.History store
- MP-E8-C4-T02 — One-time history backfill (about 42-45 GraphQL points)
- MP-E8-C4-T03 — Steady-state history feed and boot catch-up
- MP-E8-C4-T04 — Start and end times for Gantt
- MP-E8-C4-T05 — Historic edges, children index, order violations
- MP-E8-C5-T01 — Epics config section and docs
- MP-E8-C5-T02 — Epic resolver
- MP-E8-C5-T03 — Epic override registry and batch CLI
- MP-E8-C5-T04 — Skill and prompt guidance for categories and estimates
- MP-E8-C6-T01 — Feature registry and membership journal
- MP-E8-C6-T02 — feature label projection and reconciliation
- MP-E8-C6-T03 — Build Order roots imported as features
- MP-E8-C6-T04 — aiur feature CLI and the agent aiur_feature tool
- MP-E8-C6-T05 — Feature statistics
- MP-E8-C7-T01 — Planned rows, waves and cues from the build queue
- MP-E8-C7-T02 — Unfiled planning-pack items as planned rows
- MP-E8-C7-T03 — Estimates, overrides, CLI and ETA
- MP-E8-C7-T04 — Not-queued rows
- MP-E8-C8-T01 — Now-band rows and agent-state mapping
- MP-E8-C8-T02 — Usage strip data
- MP-E8-C8-T03 — Daemon, freshness and offline signals
- MP-E8-C8-T04 — Ticket index assembler, live diffs, history by day
- MP-E8-C9-T01 — Hook shell, scrollbar, payload intake, URL bridge
- MP-E8-C9-T02 — Timeline layout and density tiers
- MP-E8-C9-T03 — Virtualised rendering and history paging
- MP-E8-C9-T04 — Dynamic epic columns
- MP-E8-C9-T05 — Ticket cards in four tiers
- MP-E8-C9-T06 — Agent indicators (logo, glow, stuck, idle)
- MP-E8-C9-T07 — Dependency edges
- MP-E8-C9-T08 — Now band, live snap and jump to live
- MP-E8-C9-T09 — Gantt mode
- MP-E8-C9-T10 — Span, zoom and calendar controls
- MP-E8-C9-T11 — Dependency chains, lock tab, whole-tree view
- MP-E8-C9-T12 — List view
- MP-E8-C9-T13 — Loading, empty and stale board states
- MP-E8-C10-T01 — Toolbar and status line
- MP-E8-C10-T02 — Filters, popovers and the not_planned default
- MP-E8-C10-T03 — Feature header, focus and compact modes
- MP-E8-C10-T04 — Usage strip
- MP-E8-C11-T01 — Modal frame, ?ticket= deep link, navigation
- MP-E8-C11-T02 — Issue view for tickets without an agent
- MP-E8-C11-T03 — Conversation read seam and wave-0b adapter
- MP-E8-C11-T04 — Event rows in the conversation
- MP-E8-C11-T05 — Minimap preview sidebar, live tail, typing
- MP-E8-C11-T06 — Composer: send to the agent
- MP-E8-C11-T07 — Pause, resume and "Open in Conversations
- MP-E8-C11-T08 — Command answer card
- MP-E8-C11-T09 — Dictation button
- MP-E8-C11-T10 — Units fields in the modal (only if OQ-E8-5 says yes)
- MP-E8-C12-T01 — Cutover: / is home, Units retired, rollback route
- MP-E8-C12-T02 — Build Order routes retire to feature focus
- MP-E8-C12-T03 — Dead-code deletion after the home-page cutover
- MP-E8-C12-T04 — Phone width and WebView
- MP-E8-C12-T05 — Accessibility pass (keyboard, screen reader, live region, forced colours, axe)
- MP-E8-C12-T06 — Performance budget and measurement
- MP-E8-C12-T07 — Documentation: the Build home page, the build-history concept page, and the docs screenshots
- MP-E8-C12-T08 — DESIGN-E8 sign-off package
- MP-E8-C13-T00 — Measure the history classification cost before the backfill runs (instrumentation)
- MP-E8-C13-T01 — aiur history export for classification
- MP-E8-C13-T02 — Optional paced label writes for classifications
- MP-E8-C13-T03 — Unconfirmed classification display and confirm
- MP-E8-C13-T04 — Backfill runbook and the agent run
- MP-E8-C14-T01 — Conversation reads from the MP-E4 journal
- MP-E8-C14-T02 — Delivery receipts in the composer
- MP-E8-C14-T03 — "Open in Conversations" to the full view
- MP-E8-C14-T04 — Command answers through the MP-E2 contract

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
