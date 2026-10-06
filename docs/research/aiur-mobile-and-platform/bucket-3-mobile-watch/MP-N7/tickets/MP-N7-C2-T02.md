---
ticket_id: MP-N7-C2-T02
feature_id: MP-N7
chunk_id: MP-N7-C2
bucket: 3-mobile-watch
title: watchOS compact instance list and instance detail (open Commands) from the snapshot
status: blocked
blocked_by: [DESIGN-N7, DESIGN-N3, MP-N7-C2-T01, MP-N7-C1-T05, MP-N3-C3-T01, MP-N3-C3-T02]
prior_units: []
prior_boundaries: []
prior_features: [MP-N3, MP-N1]
prior_findings: ["overview.ex wording", "client-capability-model §7"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C2-T02 — watchOS instance list

## Identity and outcome

- Bucket 3, MP-N7, chunk C2.
- **User value:** a glance at the wrist shows which instance needs attention, with honest
  freshness; one tap shows that instance's open Commands.
- **Deliverable:** SwiftUI `InstanceListView` and `InstanceDetailView` rendering the
  stored snapshot (screens 1 and 2 of DESIGN-N7 §4).
- **Non-goals:** the Command card (C2-T03), any control besides navigation (AC6), any
  combined inbox (brief §3: the detail view lists one instance's Commands only).

## Dependencies and blockers

- DESIGN-N7 (layout, short labels D-N7-7), DESIGN-N3 (row-state vocabulary Q6).
- MP-N7-C2-T01 (PhoneLink/SnapshotStore), MP-N7-C1-T05 (snapshots arrive),
  MP-N3-C3-T01 (`MetaRow` state priority; the watch renders the `row_state` already
  computed by the phone, it does not recompute it).

## Verified starting point

- Wording sources at `45a290e3`: "1 unit awaiting commands" / "N units awaiting commands"
  (`src/lib/aiur_web/components/operator_control_center/overview.ex:168-169`), aria
  "N Commands awaiting you, M blocking" (`overview.ex:53`).
- Field rules: plan.md §6 (this feature), MP-N3 plan §5 per-field rules, capability model §7.

## Chosen design

Row content (final layout from DESIGN-N7):

| Field | Render rule |
|---|---|
| `repository_label` (+ `machine_label` when > 1 machine) | always |
| `executor_state` | `active/idle/stalled/expired/absent` as DESIGN-N7 short labels; `unknown` → "?" with a legend, never "idle" |
| `active_agents` Fact | `available` → number; `available` + paused → "Paused"; `unavailable` → "—" with accessibility label naming the reason; `disabled` → hidden; `unknown` → "?" |
| `awaiting`/`awaiting_blocking` Facts | number; `lower_bound` → "≥ N"; unavailable → "—"; disabled → hidden |
| `build_progress` Fact | only when present and `available`; never 0 for absent |
| freshness | `as_of` age always visible; if `PhoneLink.phoneReachable == false` → "Needs iPhone nearby" + age; if machine unreachable per snapshot → per-row "Unreachable" + last-seen age |

Row states from `row_state` (`live, starting, stale, unreachable, gateway_offline, crashed,
stopped, unsupported, removed`; the closed set of MP-N7-C1-T01, RC-38; `starting` renders as
"Starting" with its age, never as live) map one-to-one to DESIGN-N7 visuals; an unrecognised value renders
as "Unknown" (never as live).

Detail: list of that instance's `open_commands` (short summary, blocking marker, age),
ordered as DESIGN-E2 orders them; when `open_commands` is absent → "Open on iPhone to
load" (distinct from "No Commands waiting"). Tapping a Command → C2-T03.

Empty states (DESIGN-N7 §5): no snapshot yet → "Open aiur on iPhone"; snapshot with zero
instances → "No instances"; instance with `awaiting` available 0 → "No Commands waiting".

## Implementation steps

1. `InstanceListView.swift`, `InstanceDetailView.swift`, `RowPresenter.swift` (pure:
   snapshot row → display strings and accessibility labels).
2. Age formatter shared with C2-T03 (`AgeText`), updated every 30 s via `TimelineView`.
3. Snapshot tests from fixtures (`fixtures/watch-link/valid/snapshot-*.json`). `RowPresenterTests`
   also iterate the shared MetaRow fixtures `packages/aiur-mobile/fixtures/meta-row/` (MP-N3-C3-T02)
   so the phone list and the watch list cannot disagree on a row state.

## Non-happy paths

- Stale snapshot after relaunch: rendered with its age; no spinner pretending to refresh.
- Watch app opened with the phone unreachable: list shows stored data + "Needs iPhone nearby";
  tapping a Command still opens the card in a disabled state (C2-T03).
- Accessibility: every "—"/"?" has a VoiceOver label with the reason.

## Compatibility and rollout

Watch-only UI.

## Verification

```text
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme AiurWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' -only-testing:AiurWatchTests/RowPresenterTests
```

| Test | Expected | Must fail without |
|---|---|---|
| `testUnavailableAgentsRendersDashNotZero` | Fact unavailable → "—", label has reason | the unavailable branch (replace with `0` → fails; AGENTS.md unknown-path rule) |
| `testUnknownExecutorIsNotIdle` | `unknown` → "?" | the unknown branch (replace with "Idle" → fails) |
| `testPausedShowsPaused` | `globally_paused` → "Paused" | pause rule |
| `testLowerBoundShowsAtLeast` | "≥ 3" | lower-bound rule |
| `testDisabledBuildProgressHidden` | no build field | disabled rule |
| `testStartingRowIsNotLive` | `row_state: "starting"` → "Starting" + age | the `starting` branch (map it to live → fails) |
| `testUnknownRowStateRendersUnknown` | `row_state: "future_state"` → "Unknown" | default branch (replace with live → fails) |
| `testNeedsIPhoneWhenUnreachable` | phoneReachable false → banner + age | reachability rule |
| `testAbsentOpenCommandsIsNotEmpty` | absent list → "Open on iPhone to load" | omit-vs-empty rule |
| `testTruncatedCountShown` | `truncated: 2` → "+2 more on iPhone" | the truncation banner (drop it → fails) |

Device rows: DV-W3 (MP-N7-C6-T01).

## Completion and handoff

- [ ] Both views match approved DESIGN-N7 screens 1–2 in small (41 mm) and large (46/49 mm) sizes.
- [ ] Tests pass; each fails with its branch reverted.
- [ ] Docs: none beyond C2-T01's guide note.
- Dependents: MP-N7-C2-T03, MP-N7-C2-T05.
