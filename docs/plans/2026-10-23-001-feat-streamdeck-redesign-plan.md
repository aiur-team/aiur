---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
title: "feat: Stream Deck redesign on shared view models"
type: feat
date: 2026-10-23
execution: code
feature_slug: streamdeck-redesign
plan_version: 1
researched_commit: 6a7d6b445
---

# feat: Stream Deck redesign on shared view models

## Goal Capsule

**Objective.** The Stream Deck shows the same truth as the Build page. The daemon feeds the
deck from the Build page read models, renders every key and strip image once, and the physical
deck and the `/streamdeck` emulator only show those images and send input back.

**Authority.** Kevin's brainstorm decisions of 2026-10-23 (Product Contract below) and his
instruction "enough scope questions, research, write, queue tickets". Open points are recorded
with a recommended default in `2026-10-23-streamdeck-redesign/questions-or-commands.md`; none
blocks the start.

**Stop conditions.** The feature ends when SD-901 (acceptance on the real deck) merges. Voice
(SD-407/SD-408) may stay open behind MP-E6 without holding acceptance.

**Execution profile.** 25 tickets, 7 phases, critical path 23 complexity points
(SD-101 → SD-102 → SD-103 → SD-406 → SD-407 → SD-408 → SD-901). Phase 1 fixes the four visible
defects on the current renderer before any new view. Scheduling: just before the mobile apps
(MP-N1..N7), after the current build order. All tickets are filed `agent:parked`, `priority:3`.

**Pack index.**

| Artifact | Path |
|----------|------|
| Ticket contracts | `docs/plans/2026-10-23-streamdeck-redesign/tickets/SD-*.md` |
| Typed graph, waves, phases | `docs/plans/2026-10-23-streamdeck-redesign/graph.json` |
| Evidence (file:line grounding) | `docs/plans/2026-10-23-streamdeck-redesign/evidence/{A,B,C,D}-findings.md` |
| Open points with defaults | `docs/plans/2026-10-23-streamdeck-redesign/questions-or-commands.md` |
| Validation report | `docs/plans/2026-10-23-streamdeck-redesign/validation.md` |
| Executor handoff and issue map | `docs/plans/2026-10-23-streamdeck-redesign/handoff.md` |
| Deferred findings | `docs/plans/2026-10-23-streamdeck-redesign/deferred-findings.md` |

---

## Product Contract

### Summary

The deck today has its own copy of fleet logic: its own agent buckets, its own meter
projection, its own log feed and a TypeScript re-classification of provider windows. Each copy
has drifted from the Build page, and the drift is what Kevin sees: "No build order", "543
agents", Claude meters stuck on "Awaiting data", and no API bars. The redesign deletes those
copies. A thin deck adapter reads the same models as the Build page, the server draws the
images, and the deck keeps only layout and input.

### Problem Frame (root causes, verified at `6a7d6b445`)

1. **"No build order."** The daemon never sends build data. The sidecar reads `grid.build`
   (`packages/streamdeck/src/surface.ts:454`), but `StreamDeckGrid.project` has no `build` key,
   and the emulator hard-codes the build bar as unavailable
   (`live/streamdeck_live/screen_components.ex:133`). Evidence: `evidence/A-findings.md`.
2. **"543 agents."** `grid.total` adds running, retrying and every queued ticket with no agent
   (`stream_deck_grid.ex:67-72`). Paging uses the same number. Evidence: `evidence/D-findings.md`.
3. **Claude "Awaiting data".** The daemon renames meter windows to `session`/`weekly` and drops
   `duration_minutes`; `providerSegment.ts` classifies by `duration_minutes` only. Claude sends
   two windows without it, so nothing matches. The TS fixtures include the field, so tests never
   saw the real shape. The deck also reads only the worst account, never the multi-account
   `Build.Usage`.
4. **Missing API bars.** The deck has no source for GitHub core/GraphQL or ElevenLabs; the
   Build page reads them through `Build.Usage.block/3` (`apis`).
5. **Chat squeeze and short logs (#5181).** The deck reads the in-memory `AgentEventFeed`
   (capped at 50 entries) while the desktop modal reads `agent.ndjson` through
   `Conversation.History`. The strip loses 200 px to a summary column.
6. **Three navigation state machines** (`mode.ts` used only by tests, `controller.ts` on the
   deck, `StreamdeckLive` assigns in the emulator) and two renderers kept equal by a parity
   contract (`src/priv/streamdeck/key-face-contract.json`, parity vectors).

### Requirements (settled decisions)

- **R1 Shared view models.** A deck adapter `AiurWeb.Streamdeck.Deck` mounts one section module
  per surface over Build.Payload / IndexReader, Build.NowRows, Build.Usage + UsageAPIs +
  ProviderMeterWindows, Conversation.History / Anchors, BuildProgress / BuildQueue,
  DecisionStore, AgentChat and Aiur.Voice. Delete StreamDeckGrid buckets
  (`AgentEvents.streamdeck_bucket`), `StreamdeckProjection.Meters`, `StreamdeckLogs` on
  `AgentEventFeed`, the TS `providerSegment` re-classification, and the TS counts in
  `surface.ts`.
- **R2 One renderer.** The server renders key and strip images; the sidecar and the emulator
  both show them. No parity contract.
- **R3 Four views** cycled by dial 4: press cycles Ticket → Feature → Epic → Fleet summary, turn
  pages, long press goes back. Dial 1 scrolls lists and chat, dial 2 is priority up/down, dial 3
  switches instance. A key press drills in.
- **R4 Ticket page** with status, PR/CI, agent state, actions (priority, pause/resume, answer
  Commands, open PR or desktop modal), live chat on the strip at full width, and keys paging the
  last N turns from Conversation.History (same model as the desktop modal).
- **R5 Strip counts** for every NowRows category, with the queued backlog shown separately but
  included. Replaces the "543 agents" total.
- **R6 Meters**: one bar per provider for the account closest to its limit; press shows each
  account's 5h and weekly windows; the Fleet page adds GitHub core/GraphQL and ElevenLabs bars.
  Bars show remaining (#5589).
- **R7 Build order** from BuildProgress / Build.Payload.
- **R8 Settings**: remove the test-mic key; settings are mic and speaker device, default view and
  sort, brightness and sleep, instance, and which alerts flash or chime.
- **R9 Voice** through the shared `voice:converse` session after MP-E6 (#4142, #4145, #5729);
  remove the deck's own `voice_*` events and unused TTS code.
- **R10 Multi-instance**: one deck follows one instance, switched by dial 3, on epic #5964.

### Success criteria

- Every number the deck shows matches the Build page at the same instant (SD-901 table).
- Unknown or stale data renders as unknown with its age, never as 0 or as active.
- No deck-only classification code remains (SD-105 grep list).

### Scope boundaries

- Out: Gantt and timeline views (decision 11).
- Out: new read models the Build page does not have. Feature and Epic progress come from
  #5998/#5999, not from deck code.

---

## Implementation

### Architecture

```text
Build read models ──► AiurWeb.Streamdeck.Deck (shell)
                        ├─ Deck.BuildOrder   (SD-101)   ├─ Deck.Tickets   (SD-202)
                        ├─ Deck.Counts       (SD-401)   ├─ Deck.Features  (SD-203)
                        ├─ Deck.Meters       (SD-403/404/405) ├─ Deck.Epics (SD-204)
                        ├─ Deck.TicketPage   (SD-301)   ├─ Deck.Fleet     (SD-205)
                        ├─ Deck.Chat         (SD-303/304) └─ Deck.Nav reducer (SD-201)
                        ▼
                Deck renderer: SVG strings in Elixir (SD-102)
                 ├─► streamdeck channel ─► Node sidecar rasterizes with @napi-rs/canvas (SD-103)
                 └─► /streamdeck LiveView inlines the same SVG (SD-104)
input (keys, dials, long press) ──► Deck.Nav.reduce/3 ──► effects (priority, pause, answer, open)
```

### Key technical decisions

1. **Adapter name and layout.** `AiurWeb.Streamdeck.Deck` in `src/lib/aiur_web/streamdeck/deck.ex`,
   one section per file under `deck/`. Each section read is guarded so one failing source marks
   only its section unknown. One line per section in the shell is the only shared edit.
2. **Phase 1 runs on the current renderer.** SD-101/401/403 feed the existing channel payload
   (`StreamdeckFleet.grid/1`, `StreamdeckLive.Grid.load_grid/0`) with small TS reads, so Kevin
   sees the fixes before SD-102 lands.
3. **Renderer technology.** The daemon builds SVG strings (no new Elixir dependency; `mix.exs`
   has no image library). The sidecar rasterizes to 120×120 JPEG keys and an 800×100 strip with
   `@napi-rs/canvas`, which it already uses for provider logos. The emulator inlines the SVG. All
   text uses JetBrains Mono (fixed width, so the server wraps exactly).
4. **View state lives on the server**, per deck connection, in one pure reducer `Deck.Nav`. The
   sidecar decides press vs long press (500 ms), the mic hold and the instance reconnect.
5. **Chat reads the conversation source**, not `AgentEventFeed`: a small `Deck.Chat` controller
   in the channel process calls `ConversationSource.call/3`, the same seam as the desktop modal
   (`docs/plans/2026-10-21-conversation-read-seam.md`).
6. **Priority** goes through `Aiur.BuildQueue.reorder/2`; it refuses tickets that are not in an
   operator list queue, and the deck says so.
7. **Usage on the deck socket.** `Build.Usage.read` needs a dashboard login context; SD-403
   passes a deck `meter_source:` to `Build.Usage.load` that reads the same projection.

### Ticket map

| ID | Title | Phase | Cx | Hard dependencies |
|----|-------|-------|----|-------------------|
| SD-101 | Deck adapter shell + build order (fixes "No build order") | 1 | 3 | none |
| SD-401 | Strip counts from NowRows replace "543 agents" | 1 | 2 | SD-101 |
| SD-403 | Provider meters from Build.Usage, closest-to-limit account | 1 | 3 | SD-101, #5589 |
| SD-102 | Server-side key and strip renderer | 2 | 4 | SD-101 |
| SD-201 | View state and dial/key input model | 2 | 3 | SD-101 |
| SD-207 | Dial 3 instance switcher | 2 | 3 | #5945 |
| SD-301 | Deck ticket page: status, PR/CI, agent state | 2 | 3 | SD-101 |
| SD-103 | Sidecar shows server images | 3 | 4 | SD-102, SD-201 |
| SD-104 | Emulator shows server images; retire parity contract | 3 | 3 | SD-102, SD-201 |
| SD-202 | Ticket view on the NowRows taxonomy | 3 | 3 | SD-101, SD-102, SD-201 |
| SD-206 | Dial 2 priority up/down | 3 | 2 | SD-201 |
| SD-303 | Live chat on the strip at full width | 3 | 3 | SD-101, SD-301 |
| SD-402 | Strip redesign: category counts + backlog | 3 | 3 | SD-401, SD-102 |
| SD-404 | Meter press: per-account windows | 3 | 3 | SD-403, SD-201, SD-102 |
| SD-203 | Feature view | 4 | 3 | SD-102, SD-201, SD-202, #5998 |
| SD-204 | Epic view | 4 | 2 | SD-102, SD-201, SD-202, #5999 |
| SD-205 | Fleet summary view | 4 | 2 | SD-401, SD-102, SD-201, SD-202 |
| SD-302 | Ticket page actions | 4 | 3 | SD-301, SD-206 |
| SD-304 | Keys page through the last N turns | 4 | 3 | SD-303 |
| SD-406 | Settings page; remove test-mic key | 4 | 4 | SD-201, SD-102, SD-103, SD-207 |
| SD-105 | Delete deck-only logic | 5 | 3 | SD-202, SD-401, SD-402, SD-403, SD-303, SD-304, SD-103, SD-104 |
| SD-405 | Fleet page API bars | 5 | 2 | SD-403, SD-205, SD-102 |
| SD-407 | Deck joins voice:converse | 5 | 4 | SD-406, SD-201, #4142, #4145, #5729 |
| SD-408 | Remove deck voice_* events and TTS code | 6 | 2 | SD-407 |
| SD-901 | Acceptance on the real deck and docs sweep | 7 | 2 | all |

`graph.json` is the source for edges; this table is a generated view. Phase is a rollout hint;
readiness comes from hard dependencies. `serializes_with` edges (hot files: the Deck shell
section list, `streamdeck_channel.ex`, `surface.ts`, `packages/streamdeck/src/main.ts`) are in
`graph.json` and each ticket header.

### Sequencing and first-slot staffing

- Staff **SD-101** first: it unblocks phase 1 and has fan-out 8.
- Then **SD-102** and **SD-201** (fan-out 11 each). They serialize on the shell and
  `streamdeck_channel.ex`; land SD-201 first if both are ready, because it is smaller.
- SD-403 waits on #5589 (PR #5618 changes `acc` to mean remaining). If #5589 is not merged when
  SD-101 lands, ship SD-401 first.
- SD-203/SD-204 wait on the `feature_progress` / `epic_progress` server blocks of #5998/#5999.

### Risks

| Risk | Mitigation |
|------|-----------|
| Skia rejects the variable woff2 font or nested `data:` images | SD-102 verifies on its first slice; fallback is a static TTF and an SVG DeepSeek mark |
| #5181 (in progress, PR #5284) edits the same transcript path as SD-303 | Executor parks #5181 and points PR #5284 at SD-303/SD-304; SD-304 carries its acceptance test |
| SD-105 deletes the public `GET /api/v1/streamdeck/grid` | Named in the PR body and in `docs/streamdeck-channel.md` |
| Flaky focus tests #3539/#3728/#4406 | #3728 dies with the logs push in SD-105; the other two get explicit reply timeouts there |
| Full-frame pushes are too large | Hash dedupe on the device; add deltas only if a measured push exceeds 64 KB |

### Documentation

Each ticket edits `website/docs-app/guide/stream-deck.md` and/or `docs/streamdeck-channel.md`
for the behavior it changes. SD-901 sweeps both pages. `docs/streamdeck-channel.md` is already
out of date (no `grid` in the snapshot, `usage` listed as only `{codex, claude}`); SD-101 fixes
that.
