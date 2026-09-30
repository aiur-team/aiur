# U0 owner-map review: Stream Deck sidecar slice at `main@b4bc11f`

This is a static source review of eight `split` rows in the frozen
[oversized-file owner map](oversized-file-owner-map.csv). I checked the file blobs
against `b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f`; this research branch
does not change these paths. The map's generic `Stream Deck package` owner is a
reasonable umbrella, but it does not identify the server/browser contracts or
the packaged runtime that a split must preserve. These are proposed U0
assignment corrections, not evidence of a working device or line savings.

The release path is concrete: the sidecar's package is `private: true` and
builds `dist` from `src` (`packages/streamdeck/package.json:2-11`,
`tsconfig.json:5-19`). `scripts/build-package.mjs:47-67` accepts only Linux x64,
copies `dist`, assets, native dependencies and bundled Node, and invokes
`app/dist/main.js` from `bin/aiur-streamdeck`. The dedicated workflow installs,
builds, prunes dev dependencies, checks the archive, and attaches a
content-addressed asset to a commit or `v` release
(`.github/workflows/streamdeck-package.yml:34-84,99-114,122-151`). The normal
CI job also runs lint, coverage tests and build
(`.github/workflows/ci.yml:645-680`). A green package test does not establish
physical-device behavior; the source itself assigns that acceptance to a real
Stream Deck + (`packages/streamdeck/src/main.ts:1-18`).

| Frozen row | Proposed assignment correction and source evidence | Gate before splitting |
| --- | --- | --- |
| `packages/streamdeck/src/main.ts` (row 210) | Assign the process entry to **sidecar runtime and USB integration**, with a shared Phoenix-channel reviewer. It imports `usb`, `startRuntime`, `connectStreamDeckChannel`, `createPhysicalSurface`, and `createPhysicalController` (`main.ts:29-44`), then connects the channel and starts the runtime (`main.ts:500,611,683`). It is excluded from Vitest coverage (`vitest.config.ts:14-23`), so the map's generic source split lacks an entry-point witness. | Keep `dist/main.js` as the archive executable; pass the clean-install package smoke and a real-device connect, unplug/replug and shutdown run before moving wiring. Record unsupported hardware/platform scope rather than assuming a unit fake covers it. |
| `packages/streamdeck/src/channel.ts` (row 286) | Assign to the **sidecar/server channel contract**, jointly with `src/lib/aiur_web/streamdeck_channel.ex`. The client requests a token and joins a Phoenix v2 socket (`channel.ts:366-394,383-486`); the server handles focus, control, commands, speech and voice and pushes snapshots/logs (`streamdeck_channel.ex:19-42,45-58,78-124,129-230,233-301`). The client is excluded from Vitest coverage (`vitest.config.ts:20-23`). | Preserve wire event names, authorization, token refresh/reconnect and voice frame behavior with client/server contract tests plus an installed sidecar connecting to a running daemon. A transport-only file split cannot silently change server semantics. |
| `packages/streamdeck/src/controller.ts` (row 99) | Assign to **physical input and operator-control semantics**, with a server-control reviewer. `createPhysicalController` is the runtime's input path (`controller.ts:312`; `main.ts:500`); the tests include Implement-key behavior (`test/controller.test.ts:1313-1369`), whose server action is handled in `streamdeck_channel.ex:107-124`. | Split by control mode only after preserving report-to-action behavior for pause/resume, Implement, Commands and voice, and checking those actions through the authenticated server channel. The controller is also excluded from Vitest coverage (`vitest.config.ts:20-23`), so retain focused behavioral tests rather than treating the coverage percentage as sufficient. |
| `packages/streamdeck/src/rasterizer.ts` (row 280) | Assign to **physical rendering and shared visual contract**. `surface.ts:352-353` constructs the rasterizer; it imports `KEY_FACE_CONTRACT` and `drawSegmentContent` (`rasterizer.ts:23-33`), then emits the segment pixels (`rasterizer.ts:512,528`). `StreamdeckKeyFaceContract` reads the same JSON on the server (`src/lib/aiur_web/streamdeck_key_face_contract.ex:3-23`). | Compare representative key faces and segment pixels against the browser emulator and shared contract, then verify JPEGs through the built sidecar. The rasterizer is excluded from Vitest coverage (`vitest.config.ts:20-23`); package smoke alone does not prove visual parity. |
| `packages/streamdeck/src/art/segments.ts` (row 94) | Assign to **touch-strip visual models and accessibility/age semantics**, paired with the emulator owner. `drawSegmentContent` is called by the rasterizer (`segments.ts:1096`; `rasterizer.ts:512`), while the file explicitly cites shared state colors and emulator log palette (`segments.ts:216-221,472-475,550-551,644-646`). | Split by segment kind while preserving unknown versus zero, stale/relative-age and direction color distinctions in rendered pixels. Review the browser emulator's corresponding labels and colors before claiming parity. |
| `packages/streamdeck/test/controller.test.ts` (row 73) | Assign test groups to the **same input/control owners as `controller.ts`**, not to a freestanding test-scenario owner. The suite drives `createPhysicalController` from input reports (`test/controller.test.ts:2,23-112`) and exercises voice and Commands/Implement flows (`:919,1175,1313`). | After splitting, each moved group must still fail when its specific production control branch is reverted, and the complete `npm test` suite must pass. Keep one end-to-end server-action check for actions that cross the channel boundary. |
| `packages/streamdeck/test/art/segments.test.ts` (row 97) | Assign to the **touch-strip rendering owner**. The test's `render` helper captures actual Canvas text and pixels (`test/art/segments.test.ts:64-92`) and covers summary, provider, pager, detail, voice, settings and Commands panels (`:521,548,589,733,760,868,986,1022`). | Keep pixel/text assertions per segment after splitting; a file-count reduction that turns visual checks into model-only checks does not preserve this test's role. Recheck emulator parity for any shared palette edits. |
| `packages/streamdeck/test/dial.test.ts` (row 313) | Assign to the **cross-surface dial contract**, jointly with the emulator hook owner. It reads `src/priv/static/streamdeck-emulator-hook.js` directly and compares drag/press constants (`test/dial.test.ts:35-53`); it is not only a sidecar unit test. | Keep the source-path read or replace it with a shared versioned contract; run the Stream Deck suite and browser emulator tests together when either side changes. Preserve physical rotation/press semantics as a separate hardware acceptance check. |

The row numbers refer to the frozen CSV order, not ticket priorities. No
runtime incident count, hardware run, packaged install, or browser comparison
was performed here. Recount and reassign on the actual release-main tree before
turning these suggestions into U0 implementation tickets.
