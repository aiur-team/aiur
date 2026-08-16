---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
created: 2026-08-13
title: "feat: Stream Deck logs jump-to-event transcript"
---

# feat: Stream Deck logs jump-to-event transcript

## Goal Capsule

On the Stream Deck logs surface, pressing an event key scrolls the touch-strip
transcript to the point where that event was published; the LIVE key jumps to
the newest entry; dial A still scrolls freely from wherever the jump landed.
The strip must render the daemon's three transcript shapes distinguishably.

Spec: `docs/design/streamdeck/README.md` lines 80-99 and
`docs/design/streamdeck/streamdeck.design.js` (`sdRenderLogKeys`,
`sdBuildLogStrip`, `sdBuildFlat`, `sdEvStart`, `sdChatIdx`).

## Problem Frame

`packages/streamdeck/src/controller.ts` already derives `eventStarts` from
transcript entries whose `kind === "event_header"` and jumps `chatOffset` there
on a key press. Everything downstream of that jump is missing:

- The transcript is flattened to `entry.line ?? entry.body ?? "[INFO]"`, so a
  `diff` entry (which has no `line` and no `body`) prints the literal string
  `[INFO]`, and the badge/role/counts never reach the renderer.
- `art/segments.ts` paints the `chat` segment as one plain string, so the three
  shapes are indistinguishable and the jump target is unreadable.
- `demo.ts` ships a flat list of pre-rendered strings with no `event_header`
  rows, so `eventStarts` is empty in demo mode and jump-to-event cannot be
  demonstrated on-device.

## Requirements

- R1. Pressing event key `n` positions the transcript at that event's header.
- R2. Pressing LIVE (event index 0) positions the transcript at the newest
  entry (offset 0 — the daemon flattens newest event first).
- R3. Dial A continues to scroll the transcript from the jumped-to position.
- R4. Transcript entries stay structured (`event_header` / `diff` / `message`)
  from the channel payload through to the segment renderer.
- R5. The strip renders each shape distinguishably, using colours from
  `packages/streamdeck/src/key-face-contract.json` only.
- R6. The demo fixture contains several events, each an `event_header` followed
  by that event's entries, newest event first.
- R7. The focused agent's transcript reaches the device on focus and on refocus.

## Key Technical Decisions

- **KTD1. Derive jump targets on the client from `event_header` positions**
  rather than consuming the daemon's `event_starts` map. The daemon flattens
  `[event_header | entries]` per event (`StreamdeckLogs.flatten/1`), so the
  header positions *are* the starts; deriving them keeps the client correct
  even when a payload omits `event_starts`, and avoids a string-keyed map
  round-trip. Event key `n` maps to `eventStarts[n - 1]` because key 0 is LIVE.
- **KTD2. Name the client row type `TranscriptRow`, not `TranscriptEntry`.**
  `src/logs.ts` already exports a `TranscriptEntry` and `src/index.ts` re-exports
  both modules with `export *`; reusing the name is a duplicate-export error.
- **KTD3. Diff tinting uses `direction_badges.CONSUME` (`#88e0a6`) for additions
  and the `stuck` state accent (`#ff9a90`) for deletions.** Those are exactly
  the mock's `.add` / `.del` colours (`streamdeck.design.css` line 123) and both
  already live in the key-face contract, so no second colour table appears.
- **KTD4. Server side needs no production change.** `StreamdeckChannel` pushes a
  per-agent `logs` frame (with the flattened transcript) inside `handle_in
  ("focus", …)` and again on every relay flush, and only for the focused
  identifier. The gap is test coverage: no test proves the *logs* frame
  re-scopes when focus moves (the existing test only proves the `transcript`
  frame does). Add that regression test.

## Implementation Units

### U1. Structured transcript rows on the wire boundary

**Goal:** Model the daemon's three transcript shapes as a client type and stop
collapsing them to strings.
**Requirements:** R4.
**Files:** `packages/streamdeck/src/channel.ts`,
`packages/streamdeck/src/controller.ts`, `packages/streamdeck/test/controller.test.ts`.
**Approach:** Add `TranscriptRow` (KTD2) to `channel.ts` as a discriminated union
over `event_header` / `diff` / `message`, plus the live `transcript` channel
event carrying `{role, body}` instead of a bare body string. In `controller.ts`,
normalise each payload row with a `toTranscriptRow` beside `toEventKey`,
rename `ControllerState.transcriptLines` to `transcriptRows`, and keep
`eventStarts` derived from `event_header` positions (KTD1).
**Patterns to follow:** `toEventKey` / `asString` in `controller.ts`.
**Test scenarios:**
- A `diff` row with a null `line` yields `{kind:"diff", path, additions,
  deletions, line:null}` and never the string `[INFO]`.
- An unknown `kind` degrades to a `message` row rather than throwing.
- `event_header` rows keep badge, body and timestamp.

### U2. Event key press maps to that event's transcript position

**Goal:** Prove and harden the jump behaviour, including LIVE.
**Requirements:** R1, R2, R3.
**Dependencies:** U1.
**Files:** `packages/streamdeck/src/controller.ts`,
`packages/streamdeck/test/controller.test.ts`.
**Approach:** Keep the existing `pressKey` logs branch; confirm the
`eventOffset + index` → `eventStarts[position - 1]` mapping holds when the key
window is scrolled with dial D, and that the jump clamps to `chatMaxOffset`.
**Test scenarios:**
- With a transcript of three events, pressing key 1/2/3 sets `chatOffset` to
  each event header's index.
- Pressing LIVE sets `chatOffset` to 0.
- After a dial-D page, pressing key 1 jumps to the event now under that key,
  not the first event in the feed.
- After a jump, a dial-A detent moves one row from the jumped-to position.
- Pressing a key whose slot is empty is a no-op.

### U3. Render the three shapes on the touch strip

**Goal:** Make the jumped-to position readable.
**Requirements:** R4, R5.
**Dependencies:** U1.
**Files:** `packages/streamdeck/src/touchStrip/stripLayout.ts`,
`packages/streamdeck/src/art/segments.ts`, `packages/streamdeck/src/surface.ts`,
`packages/streamdeck/src/main.ts`,
`packages/streamdeck/test/touchStrip/stripLayout.test.ts`,
`packages/streamdeck/test/art/segments.test.ts`,
`packages/streamdeck/test/surface.test.ts`.
**Approach:** `LogsData.lines: string[]` becomes `rows: TranscriptRow[]`;
`SegmentContent`'s `chat` case carries `row: TranscriptRow | null`.
`drawSegmentContent` paints: header = badge in its contract colour + body +
relative age; diff = path with `+adds` / `-dels` tinted per KTD3 and the changed
line in the matching tint; message = role label in a contract colour + body.
**Patterns to follow:** `resetLabel` for the relative-age helper;
`directionBadgeColor` / `bucketContract` for colour lookup.
**Test scenarios:**
- `composeStrip` in logs mode yields `chat` segments carrying the row objects,
  and `null` rows past the end of the window.
- A diff row draws both counts and never the text `[INFO]`.
- An unknown badge falls back to the `INFO` colour.

### U4. Demo transcript with real event boundaries

**Goal:** Demonstrate jump-to-event on-device with no daemon.
**Requirements:** R6.
**Dependencies:** U1.
**Files:** `packages/streamdeck/src/demo.ts`, `packages/streamdeck/test/demo.test.ts`.
**Approach:** Build `demoLogs()` from a single event list — badge, text, time and
that event's entries — so the event keys and the flattened transcript cannot
drift. Newest event first, `event_header` then entries, matching
`StreamdeckLogs.flatten/1`.
**Test scenarios:**
- Every non-LIVE event key has a matching `event_header` row, in the same order.
- The fixture contains at least one diff row and one message row.

### U5. Server regression: the logs frame follows focus

**Goal:** Lock in that the per-agent transcript re-scopes when focus changes.
**Requirements:** R7.
**Files:** `src/test/aiur_web/streamdeck_channel_test.exs`.
**Approach:** Two agents with distinct issue-log transcripts; focus the first,
assert its logs frame; focus the second, assert the next logs frame carries the
second agent's entries and none of the first's.
**Test expectation:** regression coverage only — no production change (KTD4).

## Verification Contract

From `packages/streamdeck`: `npm run typecheck`, `npx vitest run`, `npm run lint`.
From `src`: `mix test test/aiur_web/streamdeck_channel_test.exs`.

## Definition of Done

R1-R7 hold, all four commands above are green, and no existing test was weakened.
