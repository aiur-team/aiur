# MP-N7-ACC — MP-N7 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-N7-C2-T06, MP-N7-C5-T02, MP-N7-C6-T02

## Outcome

The Executor proves MP-N7 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-N7/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (25)

- MP-N7-C1-T01 — Watch-link protocol v1 schemas, fixtures and cross-language decode check
- MP-N7-C1-T02 — iOS watch broker (WatchConnectivity) serving get_command, answer and snapshot in native code
- MP-N7-C1-T03 — Android watch broker (Wearable Data Layer) serving get_command, answer and snapshot in native code
- MP-N7-C1-T04 — Late-answer guard for queued watch answers (Swift and Kotlin, shared fixtures)
- MP-N7-C1-T05 — Snapshot push triggers and debounce (phone to watch)
- MP-N7-C2-T01 — watchOS SwiftUI target via config plugin, WCSession client, shared models only
- MP-N7-C2-T02 — watchOS compact instance list and instance detail (open Commands) from the snapshot
- MP-N7-C2-T03 — watchOS Command card with options and answer outcome states
- MP-N7-C2-T04 — Apple Watch notification open routing to the Command card (forwarded iPhone notifications)
- MP-N7-C2-T05 — watchOS interactive-control inventory test (no orchestration controls, AC6)
- MP-N7-C2-T06 — Per-Command option buttons in the Apple Watch long-look (conditional on DV-W10)
- MP-N7-C3-T01 — Wear OS Gradle project (non-standalone, Compose for Wear) with Data Layer client and CI build
- MP-N7-C3-T02 — Wear OS compact instance list and instance detail from the snapshot
- MP-N7-C3-T03 — Wear OS Command card with options and answer outcome states
- MP-N7-C3-T04 — Wear OS Command notifications posted by the Wear app (bridging disabled for the Command tag) with dismissal sync
- MP-N7-C3-T05 — Wear OS interactive-control inventory test (no orchestration controls, AC6)
- MP-N7-C4-T01 — Watch mic choice sheet (Dictate or Converse, D16) on watchOS and Wear OS, no recording before a choice
- MP-N7-C4-T02 — Dictate with the system recognizer (D-sys) on both watches, review before Send, provider disclosure
- MP-N7-C4-T03 — Watch audio capture to a 16 kHz mono PCM file and transfer to the phone, with deletion after use
- MP-N7-C4-T04 — Phone-side relay of watch voice turns to the daemon's device-authenticated voice path
- MP-N7-C4-T05 — Turn-based Converse on the watch through the phone (MP-E6), with reply playback and session end
- MP-N7-C5-T01 — watchOS WidgetKit complication with total blocking count and oldest blocker age (conditional on OQ-N7-4)
- MP-N7-C5-T02 — Wear OS Tile with total blocking count and oldest blocker age (conditional on OQ-N7-4)
- MP-N7-C6-T01 — Apple Watch physical-device validation (DV-W1..W6, W9..W13)
- MP-N7-C6-T02 — Wear OS physical-device validation (DV-W2..W8, W12, W13 Wear columns)

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
