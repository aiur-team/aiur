# Researcher brief (Stream Deck redesign, plan_version 1)

Researched commit: `6a7d6b445` (origin/main, 2026-10-23). Read from the planning worktree.
Read only from that worktree (or `git show`).
Never `cd`; use absolute paths. Do NOT run `mix`, `npm`, builds or tests: the machine is loaded.

## Settled decisions (Product Contract, from Kevin 2026-10-23)

1. Shared view models. The daemon adds a thin deck adapter over the SAME read models the Build
   page uses: Build.Payload / IndexReader, Build.NowRows (9-state taxonomy), Build.Usage +
   UsageAPIs + ProviderMeterWindows, Conversation.History / Anchors, BuildProgress / BuildQueue,
   DecisionStore, AgentChat, Aiur.Voice. Delete deck-only logic: StreamDeckGrid buckets
   (AgentEvents.streamdeck_bucket), StreamdeckProjection.Meters, StreamdeckLogs on
   AgentEventFeed, the TS providerSegment re-classification, the TS counts in surface.ts.
   The deck keeps only layout and input.
2. Server renders key and strip images once. The physical deck (Node sidecar) and the browser
   /streamdeck emulator both show those images: one renderer, no parity contract.
3. Four views cycled with dial 4 (bottom right): press cycles Ticket -> Feature -> Epic -> Fleet
   summary; turn pages. Ticket view = today's view with the 9-state taxonomy. Feature view = one
   key per feature with % progress, press drills into its tickets (same data as #5998). Epic view
   = remaining work per epic, press drills in (same data as #5999). Fleet summary. Dial 1 scrolls
   lists and chat; dial 2 = priority up/down on the selected ticket; dial 3 = instance switcher.
   Key press drills in; long press on dial 4 goes back.
4. Ticket press opens a deck ticket page: status, PR/CI, agent state; actions: priority up/down
   (build queue), pause/resume, answer Commands, open PR / desktop modal. Live chat: touch strip
   scrolls the latest agent message/tool call/reply at full width (fixes left-edge squeeze,
   #5181); keys page through the last N turns from Conversation.History, same model as the
   desktop ticket modal.
5. Bottom strip: counts for every agent and ticket category from NowRows (live agents, awaiting
   CI, usage limited, paused, parked, blocked, ...). Non-agent tickets (queued backlog) shown
   separately but included. Replaces the "543 agents" total. Redesign the strip for it.
6. Meters: one bar per provider showing the account closest to its limit (multi-login aware);
   press shows each account's 5h and weekly windows. Fleet page adds GitHub core/GraphQL and
   ElevenLabs API bars. Fixes Claude "awaiting data" and missing API bars; follows #5589 (bars
   show remaining).
7. Fix "No build order" by wiring BuildProgress / Build.Payload into the deck adapter.
8. Settings: remove the standalone test-mic key. Settings: mic and speaker device, default view
   and sort, brightness and sleep (dim when idle), which instance plus which alerts flash/chime.
9. Voice (after MP-E6 #4142, #4145, #5729): deck joins the shared voice:converse session: hold a
   key to talk to the Executor or a ticket agent; replies on PC speakers with barge-in. Remove
   the deck's own voice_* events and unused TTS code.
10. Multi-instance: one deck follows one instance at a time, dial-3 switcher, built on epic #5964.
11. Out of scope: Gantt/timeline views.
12. Order: phase 1 fixes visible defects on shared models first (no build order, 543 agents,
    missing meters, Claude awaiting data) and must be visible on the CURRENT TS renderer, before
    server-side rendering lands.

## Ticket ID skeleton (stable logical IDs; refine titles/scope, add or merge only with reason)

Group A (adapter + rendering) SD-101..SD-1xx:
- SD-101 Deck adapter shell over shared read models + build order from BuildProgress/Build.Payload (fixes "No build order")
- SD-102 Server-side key and strip image renderer (daemon)
- SD-103 Node sidecar shows server-rendered images (physical deck)
- SD-104 Browser /streamdeck emulator shows server-rendered images; retire parity contract
- SD-105 Delete deck-only logic (grid buckets, projection meters, StreamdeckLogs, TS providerSegment, surface.ts counts)
Group B (views + navigation) SD-201..:
- SD-201 View state + dial/key input model (dial 4 press cycle / turn page / long press back; dial 1 scroll; key drill-in)
- SD-202 Ticket view on the NowRows 9-state taxonomy
- SD-203 Feature view with % progress + drill-in (#5998 data)
- SD-204 Epic view with remaining work + drill-in (#5999 data)
- SD-205 Fleet summary view
- SD-206 Dial 2 priority up/down on the selected ticket (BuildQueue)
- SD-207 Dial 3 instance switcher (#5964)
Group C (ticket page) SD-301..:
- SD-301 Deck ticket page: status, PR/CI, agent state
- SD-302 Ticket page actions: priority, pause/resume, answer Commands, open PR / desktop modal
- SD-303 Live chat on the strip at full width from Conversation.History (#5181)
- SD-304 Keys page through the last N turns (shared conversation model with the desktop modal)
Group D (strip, meters, settings, voice) SD-401..:
- SD-401 Strip counts from NowRows replace the "543 agents" total (phase 1, current renderer)
- SD-402 Strip redesign: category counts + separate queued backlog (server-rendered)
- SD-403 Provider meters from Build.Usage/ProviderMeterWindows, closest-to-limit account (fixes Claude awaiting data) (phase 1)
- SD-404 Meter press: per-account 5h and weekly windows
- SD-405 Fleet page API bars: GitHub core/GraphQL, ElevenLabs
- SD-406 Settings page redesign; remove test-mic key
- SD-407 Deck joins voice:converse (hold to talk, barge-in)
- SD-408 Remove deck voice_* events and unused TTS code
Capstone SD-901 (planner-owned, do not write): feature acceptance on the real deck + docs sweep.

Suggested adapter shape (VERIFY against code and rename if a better home exists): a shell module
(e.g. `AiurWeb.Streamdeck.DeckView`) that mounts one module per section (build order, counts,
meters, views, ticket page) so tickets touch separate files and can run in parallel.

## What to produce

For each ticket in your group write
`docs/plans/2026-10-23-streamdeck-redesign/tickets/<ID>.md` using this template (fill every
section; implementation pointers must name real files/modules/functions at `6a7d6b445`):

```markdown
# <ID> — <title>

**Complexity:** <1-5>
**Phase hint:** <n>
**Area:** area:ui | area:daemon | area:voice
**Depends on:** <logical IDs and/or #issue numbers, each with a one-line reason; or none>
**Serializes with:** <IDs sharing a hot file, or none>

## Outcome
## Context and evidence
## Scope
## Non-goals
## Existing owner and reuse target
## Contract and invariants
(include one worked data shape)
## Refreshable implementation notes
(files touched, functions, patterns to copy — at 6a7d6b445)
## Acceptance criteria
1. ... (numbered, testable)
## Test that fails without the change
## Docs to update
(website/docs-app/guide/stream-deck.md and/or docs/streamdeck-channel.md, specific sections)
## First slice to try on the real deck
## Open points
(each with a recommended default; or none)
```

Also write `docs/plans/2026-10-23-streamdeck-redesign/evidence/<group-letter>-findings.md`: short
grounding notes with file:line pointers (what exists, what is broken and why, e.g. why "No build
order" / "543 agents" / Claude "awaiting data" happen today).

Do not edit any other files. Do not commit. Your final reply: a compact table
(ID | title | complexity | phase | depends on | serializes with) plus at most 10 lines of key
findings and open points. Keep it short.
