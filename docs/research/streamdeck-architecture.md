# Stream Deck integration — research pack

Synthesized 2026-07-30 from five research streams (SDK survey + revision, HID
protocol deep dive, design extraction, Aiur surface map, monorepo/CI). This is
the canonical context for tickets #1342–#1356. Implementing agents should not
need further research.

## Decision: direct-HID Node sidecar (revised)

**Architecture:** `@elgato-stream-deck/node` 7.6.3 sidecar process in
`packages/streamdeck/` ↔ WebSocket/HTTP ↔ Phoenix.

Ranking: **(b) Node sidecar → (a) OpenDeck plugin host → (c) streamdeckd →
(d) Elixir-native HID (last)**.

The earlier recommendation (official `.sdPlugin` under OpenDeck) was reversed
after static source analysis of OpenDeck v2.14.0:

- The Elgato desktop app has **no Linux build** (manifest `OS.Platform` enum
  admits only `"mac"`/`"windows"`), so the official plugin runtime does not
  exist on Arch. OpenDeck re-implements it.
- OpenDeck's SD+ touch-strip rendering merged **2026-06-16** (PR #356) — six
  weeks old, three user-visible bugs closed in one June week (#375, #371,
  #364), then an architectural rewrite (PR #385, 2026-07-06). It is the
  newest code in that project and exactly the path we depend on most.
- `setFeedback` constrains us to bar/gbar/pixmap/text in a 200×100 per-dial
  tile; direct `fillLcdRegion` gives the whole 800×100 strip as one canvas —
  strictly better for a live dashboard.
- Only one process can sensibly own the device (hidraw opens are not
  exclusive); a sidecar makes ownership unambiguous.
- We were writing the plugin either way; OpenDeck buys rendering/hotplug at
  the cost of a Rust host between us and the hardware, plus silently-dropped
  events (`setTriggerDescription`, `switchToProfile`, `setResources`,
  `getSecrets`) and a DRM wall on Marketplace plugins (#193: "can never be
  supported").

OpenDeck remains the fallback **if the LCD write path misbehaves on our
firmware** — its renderer is known-working on `Kind::Plus`.

Elixir-native HID is ruled out as core infrastructure on evidence: hex `hid`
is from 2016, `hidraw` 2019. One real reference exists —
[lawik/streamdex](https://github.com/lawik/streamdex) (SD+ supported, pushed
2026-04-20, not on hex.pm, 17 stars, sits on a self-patched `hid` 0.1.4).
Read it; don't build on it.

**Caveat: nothing above was tested on real SD+ hardware.** The spike
(#1342) exists precisely to close that gap.

## Spike order (#1342, ~1 day)

1. **udev + enumeration (30 min).** Install rules, **physically replug**
   (logind ACLs apply reliably only on a real add event), run the
   `@elgato-stream-deck/node` example. Failure here is permissions, not
   architecture.
2. **Input + output round-trip (1–2 h) — the go/no-go.** Log
   `rotate`/`down`/`up`/`lcdShortPress`; write full-width `fillLcd()` and a
   `fillLcdRegion()` tile. Region misbehaves → fall back to full-strip.
   LCD takes no images at all → **switch to OpenDeck**.
3. **Suspend/resume (30 min).** `systemctl suspend`; confirm a
   write-heartbeat detects the dead handle and reopens. Unrecoverable →
   strongest argument for OpenDeck.
4. **Phoenix wiring (half day).** PubSub → sidecar → repaint; dial → API →
   state → repaint. Coalesce `ticks`.

Sub-check: whether `node-hid`'s hidraw backend can send **feature reports**
(brightness/reset/serial/firmware are all feature reports; hidraw
historically could not, which is why python-elgato-streamdeck hard-codes
`libhidapi-libusb.so`). Decides libusb-vs-hidraw. Record kernel version.

## Device facts (official spec: docs.elgato.com/streamdeck/hid/)

Elgato now **officially publishes** the HID protocol — direct HID is
implementing a vendor spec, not reverse engineering.

- VID `0x0fd9`, **Stream Deck + PID `0x0084`**. 8 keys (4×2), 4 dials,
  800×100 touch strip. Read length 14 bytes incl. report ID. Poll ~50 ms;
  **read timeout = "no event pending", not an error or disconnect.**
- **Keys: 120×120 JPEG, rotation 0, no flip, RGB** (the easy case — XL/MK.2
  flip both axes; Mini/Original are BMP). Report 1024 B, header 8:
  `[0x02, 0x07, key, is_last, count u16LE, page u16LE (zero-based), payload ≤1016]`.
- **Touch strip: 800×100 JPEG via partial-region cmd `0x0C`**, report
  1024 B, header 16:
  `[0x02, 0x0C, x u16LE, y u16LE, w u16LE, h u16LE, is_last, page u16LE (unaligned @11), count u16LE @13, 0x00, payload ≤1008]`.
  There is **no hardware per-dial region grid** — segment geometry
  (x=0/200/400/600 × 200) is our choice, not spec. Python's inline offset
  comments for this path are transposed/wrong; trust the table.
- **Input report `0x01`**, class discriminator at stripped index 1:
  `0x00` keys (states at 3..10), `0x02` touchscreen (type at 3: 1 tap /
  2 long / 3 drag; coords u16LE at 5,7 and drag-end 9,11), `0x03` dials
  (subtype at 3: `0x00` press bitmap one **byte** per dial at 4..7,
  `0x01` rotation **signed int8** delta, positive = clockwise).
  Rust indices are +1 (it keeps the report-ID byte; node/python strip it) —
  pick one convention and document it.
- **Feature reports (32 B padded):** brightness `[0x03,0x08,pct]`, reset
  `[0x03,0x02]`, key RGB fill `[0x03,0x06,i,r,g,b]` (index base disputed:
  node raw vs rust +key_count — verify on hardware), firmware read `0x05`,
  serial read `0x06` (SD+ string offsets disputed 2/6 vs 5/5 — parse
  defensively).

## Known failure modes (each maps to ticket acceptance)

1. **No exclusive access on hidraw** — concurrent writers corrupt multi-chunk
   transfers rather than failing. Take an advisory lock (flock pidfile or
   abstract unix socket). (#1354)
2. **Suspend/resume zombie handle** — the #1 long-running failure
   (python #78 open since 2021; streamdeck-ui #155/#184; companion #2795).
   Device resets on resume, read thread dies, handle still reports
   connected, device ID unchanged. **Never trust a connected flag; use a
   write-based heartbeat** (repaint/brightness) and treat write failure as
   the disconnect signal. Brightness resets on resume → reapply in
   reconnect. On a laptop this happens daily. (#1354)
3. **USB throughput dominates, not CPU** (python #36/#25: pre-rendering gave
   minimal improvement). Serialize all writes (Julusian wraps everything in
   p-queue), cache encoded JPEGs, dirty-track per key, use the RGB fill fast
   path for solid colours. (#1355)
4. **Device wedge**: Elgato states a botched partial transfer typically
   stops the device responding until replug. All-or-nothing writes;
   recovery = key-stream reset (1024 B report of only `0x02`) then device
   reset. (#1354/#1355)
5. **Clean shutdown**: Elgato recommends "Show Logo" before closing; wire to
   SIGTERM/SIGINT or the deck freezes on the last frame. (#1354)
6. **udev on Arch**: no plugdev group; `TAG+="uaccess"` grants only the
   active-seat user — a systemd **system** unit needs explicit `GROUP=`.
   Rules need both `SUBSYSTEM=="usb"` and `KERNEL=="hidraw*"` lines for
   VID 0fd9; reload + **physical replug**. (#1354, #1357)
7. **Hotplug**: no reference library implements it; use udev events
   (`SUBSYSTEM=="hidraw"`, `ATTRS{idVendor}=="0fd9"`), not enumerate-polling.
   JPEG quality: python 100 / node 95 / rust 90; artefacts reported below
   100 (streamdeck-ui #52) — configurable knob.

## Three-layer architecture and the ticket map

The design (Claude Design "Aiur Operator Control Center", `assets/` +
panel JS ~lines 3625–4256) is a faithful SD+ **emulator**; full logic and
CSS are extracted into the ticket bodies.

| Layer | Tickets | Hardware? |
|---|---|---|
| Gate | #1342 spike · #1343 monorepo scaffold | spike only |
| Elixir surface | #1344 pause/resume HTTP · #1345 grid projection · #1346 Phoenix Channel · #1347 event feed | no |
| Core logic (pure TS) | #1348 mode machine · #1349 dials/paging · #1350 key content model · #1351 event flattening | no |
| Emulator | #1352 LiveView page · #1353 interaction hooks | no |
| Device | #1354 transport/lifecycle · #1355 key pipeline · #1356 touch strip · (input decoding folded into #1354; #1357 packaging/udev/systemd pending) | yes |

11 of the tickets need no hardware; the emulator doubles as the permanent CI
harness for the device layer. If #1342 fails outright, core + emulator still
ship as a dashboard page.

Key numbers embedded in tickets: column-major grid
`agents[(colOffset+col)*2+row]`; `maxOffset = ceil(n/2)-4`; windows
`ceil(n/8)`; dials 0–100 over a 270° sweep (drag `/2.7`, wheel/keys step 4);
press = pointer-up with <8° accumulated rotation; dial 0 press = BACK,
dial 3 press = cycle window; progress hue `(pct/100)*125` →
`hsl(h 72% 50%)`; five buckets rank `alert<stuck<running<paused<queued`,
queued-ready first.

## Aiur surface facts (for the Elixir tickets)

- Snapshot: `GET /api/v1/state` (presenter.ex) over
  `Orchestrator.snapshot/2`; per-agent `GET /api/v1/:id`.
- No HTTP pause/resume today — only `Orchestrator.pause_agent/1`,
  `resume_agent/1` (pause_resume.ex:82–93). #1344 adds routes.
- PubSub: `agents:running`, `agents:status`, `agent:<id>` (transcript,
  alerts, control), `provider_meters:observed`, `decisions:changed`.
  External processes can't reach PubSub → #1346 bridges via a Channel.
- Transcripts: `IssueLog.history/2` (memory) / `read_tail/2` (disk,
  `<workspace>/<id>/agent_events.jsonl`), roles
  user/assistant/system/command/alert/reasoning/tool. No emit/consume
  taxonomy exists — #1347 defines the derivation. Beware #1231
  (unbounded AlertFeed scans).
- Buckets: `agent_events.ex:57-71` canonical; `work_state` atoms at
  :189-212. The design's `alert`/`stuck` need an explicit documented
  mapping (#1345).
- opencode bridge (127.0.0.1:4097/4098) is an LLM proxy, **not** a control
  channel.

## Monorepo facts (#1343)

- Use `packages/streamdeck/`, standalone package.json + lockfile (matches
  src/browser, website); **not** `apps/` (umbrella connotation), no
  workspace/task-runner for one package.
- Nested `mise.toml` with only `[tools] node = "24"` needs **no mise trust**
  (safe-config carve-out) and mise-action's cache key already globs
  `**/mise.toml`.
- CI: add a `streamdeck` job; prefer always-run over paths-filter to avoid
  the required-check-stuck-pending footgun; keep JS coverage separate —
  built-in Mix cover has no LCOV emitter, so blending would force an
  ExCoveralls migration that replaces the existing 85% gate
  (`src/mix.exs` `test_coverage: [summary: [threshold: 85]]`).
- No dependabot/renovate config exists at all (pre-existing gap; Renovate
  fits better if ever closed — mix manager auto-discovers, documented
  mix.lock maintenance).
