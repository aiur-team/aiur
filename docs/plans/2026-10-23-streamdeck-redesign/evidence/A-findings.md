# Group A findings — deck adapter, rendering, deletion (at `6a7d6b445`)

Paths are relative to the worktree root. Read only; no build or test was run.

## 1. Why the deck shows "No build order"

The daemon never sends build progress. Both renderers fall back to the empty state.

- Sidecar: `packages/streamdeck/src/surface.ts:451-455` calls
  `summaryModel(live, remaining, grid.build)`. The comment at `surface.ts:448-450`
  expects `grid.build` "straight from the projection". `summarySegment.ts:68-72` returns
  `build: null` when the value is absent, so `art/segments.ts:77-81` draws "No build order".
- The projection has no `build` key. `AiurWeb.StreamDeckGrid.project/2`
  (`src/lib/aiur_web/stream_deck_grid.ex:56-64`) returns only `agents, total, columns_per_page,
  rows_per_column, agents_per_page, windows, max_column_offset`. `AiurWeb.StreamdeckFleet.grid/1`
  (`streamdeck_fleet.ex:21-26`) adds nothing to it. The TS type `StreamDeckGrid`
  (`packages/streamdeck/src/channel-types.ts:35-40`) does not declare `build` either.
- Emulator: the build mini-bar is hard-coded as unobserved. See
  `src/lib/aiur_web/live/streamdeck_live/screen_components.ex:133-139`
  (`data-observed="false"`, `aria-label="Build progress unavailable"`, empty `<i>`).
  `Surface.screen_descriptors/4` (`live/streamdeck_live/surface.ex:77`) has no build field.
- Nothing in the deck calls `Aiur.BuildProgress`, `Aiur.BuildQueue` or `AiurWeb.Build.*`.

**Shared source to use.** `Aiur.BuildQueue.show/0` (`src/lib/aiur/build_queue.ex:22-34`) is a
`GenServer.call` with a 1 s timeout. It never raises: noproc gives `ReadModel.unavailable/1` and
a timeout gives the last model. It returns `queues: [%{queue_id, set_rank, kind, root, name,
held, progress: %{completed, resolved, total, percent, resolution}, progress_reasons, items}]`
(`build_queue/read_model.ex:337-360`). For `kind: :build_order` lanes, `progress` comes from
`BuildProgress` facts. `Aiur.BuildOrder.ProgressObserver` publishes these facts with
**`completed: nil`** and a `percent` (`build_order/progress_observer.ex:57-68`). The focus lane
is the lowest `{set_rank, queue_id}` (`ReadModel.focus_starvation/1`, `read_model.ex:70-73`).

The dashboard Build Queue panel reads the same model and the same topics:
`AiurWeb.BuildQueue.Runtime` (`build_queue/runtime.ex:17-20`) subscribes to
`"build_queue:changed"` and `"build_progress"` (messages `{:build_queue_changed, _}` and
`{:build_progress_changed, fact}`). `AiurWeb.BuildQueue.Copy.progress/1` (`copy.ex:99-106`)
holds the wording.

**TS trap.** `toBuildProgress` computes the fraction from `completed/total` only. A
build-order lane has `completed: nil`, so it would draw 0% even with a real `percent`. The
phase-1 fix must read `percent` when it is present.

**ETA.** No shared model has a build-order ETA. Build.Index has per-row `est` and
`capacity`, but nothing reduces them to a lane ETA. Send `eta_seconds: nil`. The TS painter
already hides the ETA when it is null (`segments.ts:86-88`).

## 2. "543 agents" (for SD-401, group D)

`grid.total` counts every running, retrying **and idle-dispatchable** ticket
(`stream_deck_grid.ex:67-72`, `idle` → `:queued`). The label is
`` `${grid.total} Agents` `` (`surface.ts:467`). "remaining" is `total - running`
(`surface.ts:453`). The emulator copies the same arithmetic (`live/streamdeck_live/surface.ex:77`).
The queued backlog is therefore counted as agents.

## 3. Claude "awaiting data" (for SD-403, group D; pointers only)

The deck reads `ProviderMeterProjection.snapshot/0`, which has one view per provider family
(`streamdeck_projection.ex:168-170`). It then re-normalises that view in
`StreamdeckProjection.Meters` (`streamdeck_projection/meters.ex`). The TS
`providerSegment.ts` then re-classifies windows by duration again (see its header comment,
lines 34-45). "Awaiting data" is drawn when `!row.model.hasData`
(`art/segments.ts:97`). The deck never reads `AiurWeb.Build.Usage`, which is multi-account
aware. Group D owns the root cause.

## 4. Channel payload assembly (where SD-101 plugs in)

- `StreamdeckChannel.join/3` (`streamdeck_channel.ex:20-42`) subscribes to the fleet, provider
  meters, Commands and financial config. It then sends `:streamdeck_snapshot`, which pushes
  `StreamdeckProjection.snapshot/0` (`streamdeck_projection.ex:12-25`):
  `{version, fleet, grid, usage, decisions, voice}`.
- Fleet changes are coalesced for 250 ms by `StreamdeckFleetUpdates.schedule/flush`
  (`streamdeck_fleet_updates.ex:13-29`). The flush pushes `"fleet"` with
  `StreamdeckProjection.fleet_with_grid/1`, which reaches `StreamdeckFleet.with_grid/2`, which adds `"grid"`.
- Meter changes push `"usage"` (`streamdeck_channel.ex:271-274`).
- The emulator does not use the channel. `AiurWeb.StreamdeckLive.Grid.load_grid/0`
  (`live/streamdeck_live/grid.ex:177-198`) calls `StreamDeckGrid.project/1` directly, and
  `refresh_meters/1` calls `StreamdeckProjection.provider_meters/0`.
- **The common point for both surfaces is `StreamdeckFleet.grid/1` plus `StreamdeckLive.Grid.load_grid/0`.**
  A deck adapter function called from both feeds the TS sidecar and the emulator together.
- Doc drift: `docs/streamdeck-channel.md` § Events lists the snapshot as
  `{version, fleet, usage, decisions, voice}` without `grid`, and `usage` as `{codex, claude}`.
  In the code, `usage` has every provider family.

## 5. How images are drawn today (two renderers plus a parity contract)

- **Sidecar** (Node, `@napi-rs/canvas` `^0.1.100`, `packages/streamdeck/package.json`):
  `rasterizer.ts` draws `KeyDescriptor`s and `SegmentContent` on canvas and encodes them as
  JPEG at quality 90 (`rasterizer.ts:38,60`). It keeps an LRU of 512 entries keyed by content. Key art:
  `key-face.ts` + `keys/keyFace.ts`. Strip art: `art/segments.ts`, `art/segmentPanels.ts`,
  `art/chat-readout.ts`. Icons are canvas paths (`art/icons.ts`). Provider marks are loaded as
  **SVG files through `loadImage`** (`art/vendorMark.ts`, assets in
  `packages/streamdeck/assets/vendor/*.svg`, plus `deepseek.png`). The sidecar therefore
  rasterises SVG with Skia today.
- Transport: keys use `0x07` JPEG chunks of 1016-byte payload (`keys/keyImage.ts`), queued by
  `keys/writeQueue.ts`. The strip uses `0x0C` partial-region JPEG writes
  (`imageWriter/headerGenerator.ts`). `touchStrip/panelCache.ts` and `keys/keyCache.ts` skip
  unchanged bytes.
- **Emulator** (LiveView): the key faces are HEEx plus CSS
  (`live/streamdeck_live/components.ex:72-115`, `screen_components.ex`,
  `priv/static/css/52/54/56/58-streamdeck-*.css`, 1,470 lines). Epic icons are inlined Heroicons
  (`components/operator_control_center/build_order_epic_icon.ex`).
- **Parity contract**: the canonical files are `src/priv/streamdeck/key-face-contract.json` and
  `key-face-parity-vectors.json`. `AiurWeb.StreamdeckKeyFaceContract` validates them at compile time
  (`streamdeck_key_face_contract.ex:10-53`). Byte mirrors are in `packages/streamdeck/src/`.
  These tests guard them: `src/test/aiur_web/streamdeck_key_face_contract_test.exs`,
  `packages/streamdeck/test/key-face-contract.test.ts`, `packages/streamdeck/test/protocol-mirror.test.ts`
  and `scripts/test-check-components.sh:193-195` (it refuses an Elixir resource read from the package).
  The contract still has the 5 old buckets (`alert stuck running paused queued`).

## 6. Physical geometry (verified)

| Item | Value | Source |
| --- | --- | --- |
| Keys | 8, in 4 columns × 2 rows, column-major paging | `keys/keyImage.ts:65`, `stream_deck_grid.ex:15-17` |
| Key image | 120×120 JPEG, rotation 0, no flip, zero-based chunks | `keys/keyImage.ts:11-17,68` |
| Strip | 800×100, written in `0x0C` regions (any rect); the project splits it into four 200×100 segments | `touchStrip/geometry.ts:4-28`, `imageWriter/headerGenerator.ts:13-14,54` |
| Dials | 4 (A to D) | `dial.ts`, guide § Drive the four modes |

## 7. Server-side rendering recommendation

Build **SVG strings in Elixir** (iodata, no new dependency). The two consumers then rasterise them as follows:
- The sidecar rasterises with the installed `@napi-rs/canvas`. `loadImage(svgBuffer)` is already
  used for vendor marks, then `drawImage` and `toBuffer("image/jpeg", 90)` into the existing writers.
  The `Image.src` type in the installed 0.1.100 accepts "a SVG string"
  (`node_modules/@napi-rs/canvas/index.d.ts:510`).
- The emulator inlines the same SVG in the key `<button>`. The page already loads JetBrains Mono and
  Space Grotesk (`priv/static/aiur-style/fonts/*.woff2`).

Rejected options:
- Rasterising in Elixir needs a new native dependency (vix/libvips or resvg). `mix.exs` has none.
- Sending canvas draw commands to TS keeps two renderers.
- A headless browser is heavy.

The server cannot measure proportional glyphs. Use **JetBrains Mono** for all deck text. Its
advance is a fixed 0.6 em, so the server can wrap and truncate exactly. The sidecar registers
the same woff2 through `GlobalFonts.registerFromPath` (`index.d.ts:875`).
**Open point:** whether Skia loads the woff2 variable font, or needs a static TTF. Default:
try the woff2 on the first slice and vendor a static TTF only if it fails.

## 8. Deletion inventory (SD-105) — callers and tests

| Target | Production callers | Tests that go or change |
| --- | --- | --- |
| `Aiur.AgentEvents.streamdeck_bucket/1` (`agent_events.ex:298`) | `stream_deck_grid.ex:49` only | `test/aiur/agent_events_test.exs:149-170` (describe block) |
| `AiurWeb.StreamDeckGrid` (bucket ranking) | `streamdeck_fleet.ex:3,23-26`, `live/streamdeck_live/grid.ex:196`, `ObservabilityApiController.streamdeck_grid` (`GET /api/v1/streamdeck/grid`, `routes/api.ex:48,54`) | `test/aiur_web/stream_deck_grid_test.exs`, `operator_control_center/units_presenter/freshness_test.exs:5,52` |
| `AiurWeb.StreamdeckProjection.Meters` + `AiurWeb.StreamdeckMeterRetention` | `streamdeck_projection.ex:4,93,104-105` only | `test/aiur_web/streamdeck_projection_test.exs:66-330` (meter tests), `test/aiur/provider_meter_probe_accounts_test.exs:79`, channel usage tests `streamdeck_channel_test.exs:403-450` |
| `AiurWeb.StreamdeckLogs` (+ `StreamdeckLogs.Rows`) over `Conversation.History`/`Anchors` (`streamdeck_logs.ex:44,489-496`) | `streamdeck_channel.ex:261,296,411-413`, `streamdeck_strip.ex:15,100-108`, `live/streamdeck_live.ex:27,83,151,279`, `live/streamdeck_live/components.ex:15,203`, `live/streamdeck_live/grid.ex:128-142` | `streamdeck_logs_test.exs`, `streamdeck_logs_rows_test.exs`, `test/aiur/agent_event_feed_test.exs:7,19,88`, `live/streamdeck_live_logs_test.exs`, the channel logs tests (`streamdeck_channel_test.exs:194,257`) |
| TS `touchStrip/providerSegment.ts` | `src/index.ts`, `touchStrip/providerPanel.ts` | `test/touchStrip/providerSegment.test.ts`, `providerPanel.test.ts`, `stripLayout.test.ts`, `stripRenderer.test.ts`, `demo.test.ts`, `test/art/segmentFixtures.ts` |
| TS `surface.ts` counts (`surface.ts:451-467`, `summarySegment.ts`, `pagerSegment.ts`) | `surface.ts`, `touchStrip/stripLayout.ts`, `src/index.ts` | `test/touchStrip/summarySegment.test.ts`, `pagerSegment.test.ts`, `stripLayout.test.ts`, `stripRenderer.test.ts`, `test/surface.test.ts` |

After SD-103 and SD-104, the whole TS drawing stack has no caller: `rasterizer.ts`, `art/*`,
`key-face*.ts`, `keys/keyFace.ts`, `touchStrip/*` (except `geometry.ts`), and the descriptor
building in `surface.ts`. The emulator face markup, most of the CSS in 52-58, and the parity
contract also lose their callers.

**Flaky focus-reply tests.**
- #3728 (`the logs frame re-scopes to the newly focused agent`, `streamdeck_channel_test.exs:257`)
  tests the `logs` push. It **dies** with `StreamdeckLogs`.
- #3539 (`a joined channel survives a financial-data read while focused` :54,
  `a transcript burst is coalesced` :385) and #4406 (`a tagged event from the old focus cannot be
  relabeled after refocusing` :354) test `focus` and the transcript relay. `focus` survives as
  the ticket-page entry, so these tests stay.

In all three tests, the mailbox competitor was the `logs` push sent on focus
(`streamdeck_channel.ex:261`). SD-105 removes that push. The root cause is not proven, so the
tests are not closed automatically (see SD-105 Open points).
