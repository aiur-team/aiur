# SD-406 implementation

Source contract: `docs/plans/2026-10-23-streamdeck-redesign/tickets/SD-406.md`.

## Decisions

Keep settings per daemon instance, using a mode-0600 temporary file and rename before acknowledging changes. Preserve a missing device's saved id and resolve fallback on the PC. Render section/choice screens in the existing server SVG pipeline; the sidecar only sends inventory/input and applies settings. Keep brightness null until saved so the environment remains the default. Use the existing instance registry, transmitting names only, never credentials.

## Units

1. Daemon persistence and navigation (`src/lib/aiur_web/streamdeck/deck/settings*.ex`, `render/settings.ex`, channel/frame updates). Support eight sections, dial 1 choice scroll/select, dial 4 hold back and a reachable settings entry. Validate all settings at the channel boundary. Cover persistence/reload, failed-write preservation, permissions/clamping, missing-device labels, input selection and rendered frames in new focused ExUnit files.
2. Sidecar application (`packages/streamdeck/src/audio/devices.ts`, runtime, channel and main). Add speaker discovery, join/change inventory, one-time legacy mic migration, settings pushes, instance following and resolved audio selection. Fake-clock runtime tests cover dim at five seconds, wake on input, zero timeout and brightness updates. Discovery and channel tests cover inventory and settings delivery.
3. Remove TestMic from legacy settings/controller/strip and emulator, and update operator/channel docs. Update focused legacy tests to constrain its absence and inventory mapping.

Units 1 and 2 agree on wire events: `devices` carries `mics`, `speakers`, `instances` (name strings), optional `legacy_mic_id`; `settings_set` carries a settings patch; daemon `settings` pushes the full settings map. `brightness: null` means use sidecar environment default. Units otherwise own separate files; unit 3 avoids channel/main/runtime and daemon settings files.

## Risks and verification

Do not grow files already over 500 lines; move new logic into small modules. A write failure must retain both previous persisted and visible settings and display “not saved”. Reconnection must reapply the daemon's settings, with stale instance events guarded. Never transmit instance authentication. Hardware brightness, idle wake and audio routing remain named post-deploy checks. Run scoped TS/ExUnit coverage, isolated production-revert checks, required lint and structural/pre-PR gates before a ready PR.
