# SD-406 implementation

Source: `docs/plans/2026-10-23-streamdeck-redesign/tickets/SD-406.md`.
The Executor's [binding frame contract](https://github.com/aiur-team/aiur/issues/6046) supersedes the earlier separate-settings-frame design.

## Decisions

Persist preferences per daemon instance using private atomic writes. Preserve an unplugged device's saved id; resolve capture/playback fallback on the PC. Keep brightness null until saved so the environment remains the default. Send instance names without credentials.

Store section, cursor, return surface and notice on `Deck.Nav`. Both browser and physical navigation use `FrameUpdates.transition/3`; `FrameUpdates.frame/5` constructs settings context for `Render.Views` / `Render.compose`. Settings produces shared Card faces and strip parts, never a separate frame painter.

Both surfaces apply save results through `SettingsUpdates.apply_result/3`, including the persisted default view, failure notice and toast. Rendering and emulator identifier resolution share `FrameUpdates.prepare_grid/1` for normalization and sorting. Existing focus, log and command loading remain owned by their separate channel workflow.

Keep preferences and the last connected PC inventory in a bounded supervised `SettingsSnapshot` owner. Load preferences at mount/join and after writes, outside rendering. Monitor the inventory's reporting process; a disconnect makes inventory unavailable on both surfaces. Start this owner before HTTP accepts requests, with an explicit child-order dependency exception.

Input acknowledgements contain navigation only. Schedule settings, inventory and status redraws through the existing fleet coalescer. Frames reach the physical deck only as pushed `frame` events. No reply embeds an image.

## Implementation units

1. Store and snapshot owner: private atomic persistence, validated patches, once-only mic migration, retained inventory, failed-write preservation, bounded cache and owner-down unavailability.
2. Shared navigation and rendering: eight settings sections, dial 1 scroll/select, dial 4 hold back, missing-device labels, canonical state ordering and stable priority groups. Browser and physical frames must be byte-identical for the same Nav and data.
3. Sidecar application: join/change inventory, saved microphone/speaker resolution, brightness, idle dim/wake, instance following, local alert choices and existing-protocol dial-3 dictation. No conversation or spoken replies.
4. Integration: remove TestMic, update operator/protocol docs, wire browser controls and the browser fixture's required service with a temporary settings path.

## Verification

Keep these main tests unchanged and green:

- `src/test/aiur_web/streamdeck_flood_test.exs`
- `src/test/aiur_web/streamdeck/ticket_pubsub_test.exs`
- `src/test/aiur_web/streamdeck_channel_frame_test.exs`

Assert actual pushed frames after input, navigation-only acknowledgements, one queued refresh, and browser/physical SVG parity. Unknown inventory must remain nil/unavailable rather than a fabricated empty count. Verify microphone persistence and actual write-failure preservation using temporary paths. Fake clocks cover idle dimming, wake and repeated unchanged settings.

Run relevant sidecar and browser specs, backend mirrors, compile/format, full-source strict lint, Dialyzer, structural and handoff guards. The required browser fixture wiring touches shared test support, so run the full ExUnit suite once; run only affected browser specs locally. Serialize BEAM validation against this checkout's shared build artifacts.

Every new behavior test must fail under a targeted production mutation in a clean isolated worktree, then pass restored. Record exact commands and unrun hardware checks in the PR body. Hardware/real CLI checks are exact post-deploy steps for the Executor and physical Stream Deck +.
