# DESIGN-N3 — Kevin: design and approve the phone meta-dashboard and per-instance navigation

- **Status:** open. **Implementation blocked until Kevin approves this task explicitly.**
- **Blocks:** MP-N3-C4 (app screen). MP-N3-C1 (summary provider), C2 (gateway fan-out),
  C3 (view model) and C5 (fixture) may proceed; they encode the data rules below, not the
  layout.
- **Blocks — final ticket IDs (Phase D; tickets whose `blocked_by` names DESIGN-N3):** MP-N1-C4-T06, MP-N3-C1-T01, MP-N3-C1-T02, MP-N3-C1-T03, MP-N3-C1-T04, MP-N3-C1-T05, MP-N3-C2-T01, MP-N3-C2-T02, MP-N3-C3-T01, MP-N3-C3-T02, MP-N3-C4-T01, MP-N3-C4-T02, MP-N3-C4-T03, MP-N3-C4-T04, MP-N3-C4-T05, MP-N3-C4-T06, MP-N3-C5-T01, MP-N5-C1-T05, MP-N5-C4-T01, MP-N7-C2-T02, MP-N7-C3-T02.
- **Linked:** DESIGN-N1 (native list versus WebView), DESIGN-N2 (device list, machine
  states), DESIGN-E3 (Executor chat surface that the secondary button opens), DESIGN-N5
  (app badge), DESIGN-N7 (compact watch list uses the same row states).
- **References:** [MP-N3 plan](../bucket-3-mobile-watch/MP-N3/plan.md), contract §7 in
  [pairing-and-instance-registry.md](../contracts/pairing-and-instance-registry.md).

## What to design

1. **The instance list:** grouping by machine (or merged), row order, and what is shown on
   one row:
   - repository (with a disambiguator when two clones share a repo)
   - active agents (with paused shown as paused)
   - Executor state: active, idle, stalled, expired, none or unknown
   - the Commands count. The existing terms are "units awaiting commands" and aria
     "Commands awaiting you"; show "≥ N" when the count is partial. **Which Commands count
     is defined by [DESIGN-E2 §6 item 2](DESIGN-E2.md#6-decisions-that-need-kevin)**
     (proposed: every open Command is visible, only "Needs you" Commands count). This
     gate does not redefine it; the meta-dashboard number follows E2's answer.
   - build-order progress (only when the instance has build orders)
   - background agents (only when the Executor reports them)
2. **Tap behaviour:** a row opens the instance dashboard. The Executor chat button is
   secondary and appears only when supported. The design shows what happens when the
   dashboard is not reachable from the phone (loopback-only, or the dashboard is off).
3. **Per-instance navigation back to the list:** how the user returns from the WebView
   dashboard, and whether the Commands count on the dashboard links to its own `/commands`
   inbox. The inbox stays per instance; there is no combined inbox.
4. **Refresh affordances:** pull to refresh, and the "updated <age> ago" display.

## Decisions Kevin must make

- Q1. Group rows by machine, or show one list sorted by urgency (Commands, then stalled
  Executor)? Sorting by count is allowed; merging Commands into one list is not.
  Recommended: **one list sorted by urgency, with the machine label on each row**, because
  the question on opening the app is "where am I needed", not "which machine".
- Q2. Field order and density on a row. Which fields are dropped first on a small screen?
  Recommended: **repository, Commands count, Executor state, active agents, build %,
  background agents; drop background agents first, then build %**, because the first
  three decide whether to tap the row.
- Q3. Build-order figure when an instance has several open build orders. Options: the most
  recently active one with "+N more"; the lowest progress; a count only. Recommended:
  **most recently active, with "+N more"**, because it names the build the operator is
  following.
- Q4. Do stopped or crashed instances stay in the list, and for how long? **Answered in
  [DESIGN-N2 Q6](DESIGN-N2.md#decisions-kevin-must-make)** (recommended 7 days); this gate
  only designs how such a row looks.
- Q5. App icon badge with the total of Commands awaiting across instances. **Answered in
  [DESIGN-N5 D-9](DESIGN-N5.md#3-decisions-that-need-kevin)**, which owns badge settings;
  this gate only shows the count it reflects.
- Q6. The wording for "unavailable", "stale" and "unreachable". It must be distinct from 0
  and from idle, and consistent with the dashboard's "Command counts unavailable".
  Recommended: **reuse the dashboard's "unavailable" and the CLI freshness terms
  ("stale, updated N min ago"; "can't reach <machine>")**, so one word means one thing on
  every surface.

## States to cover

| State | Notes |
| --- | --- |
| Loading (first fetch per machine) | |
| Empty: no machines paired | Links to the pairing flow (DESIGN-N2) |
| Empty: machine paired, no instances | Not an error |
| Offline: machine unreachable | Last-known values with their age, never zeros |
| Gateway offline / mobile disabled on the machine | |
| Permission denied: device revoked | Machine moves to a removed state |
| Error: summary unsupported (older aiur) | Identity only, plus an update hint |
| Stale instance (old heartbeat or summary) | Values with an age |
| Instance crashed / stopped | |
| Field unavailable versus disabled versus 0 | Per field |
| Partial Commands count ("≥ N") | |
| Global pause | "Paused", not "0 active" |
| Success: live | |

## Acceptance conditions

- Every state above has an approved visual and copy, including the per-field unavailable,
  disabled and zero distinction.
- Q1–Q3 and Q6 are answered in this file; Q4 and Q5 are answered in their owning gates
  (DESIGN-N2 Q6, DESIGN-N5 D-9).
- The design contains no combined inbox and no "ping Executor" action on the count.
- Kevin records "approved" with a date. Until then MP-N3-C4 stays blocked.
