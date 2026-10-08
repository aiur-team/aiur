---
ticket_id: MP-N5-C4-T01
feature_id: MP-N5
chunk_id: MP-N5-C4
bucket: 3-mobile-watch
title: Phone notification settings — machine defaults, per-instance overrides, unavailable reasons
status: blocked
blocked_by: [DESIGN-N5 (surfaces §2, D-7 wording, D-8), DESIGN-N1, DESIGN-N3, MP-N5-C1-T03, MP-N1-C4-T01, MP-N1-C3-T02, RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1, MP-N3]
prior_findings: [capability-matrix rule 1, AC-N5-7]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C4-T01 — Settings screens

## Identity and outcome

Bucket 3, MP-N5, chunk C4. Phone screens (native per MP-N1 surface boundary, since
settings are a native surface there) for: machine-level notification defaults, the
per-instance override screen (reached from the instance, DESIGN-N3), the progress step
picker (off / 10 / 25 / 50 %) and completion toggle, the opt-in list, and "unavailable"
rows (disabled control + reason + optional "how to enable") driven by the
`notification-options` API (C1-T03). Saves via the gateway `PATCH` with
`expected_version`.

## Dependencies and blockers

**Blocked on DESIGN-N5 content**: every surface in its §2, option wording and reason copy
(D-7), whether queue milestones get their own toggle (D-8). Also DESIGN-N1 (native vs
WebView), DESIGN-N3 (entry point), N1-C4-T01 (navigation), N1-C3-T02 (affordance resolver),
C1-T03 (API), RQ-TRANSPORT (the phone must reach gateway and instances).

## Verified starting point

No mobile code at `45a290e3`. API contract: C1-T03. Capability affordance rules:
`contracts/client-capability-model.md` (MP-N1 owns).

## Chosen design (fixed parts)

- Unavailable options are rendered from `state: unavailable` + `reason` — never as a
  working toggle and never as "off" (AC-N5-7).
- Machine defaults are saved through the gateway; per-instance overrides also go through
  the gateway (single writer) — the instance API is read-only.

## Implementation steps

Build the structure and tests now; only option wording, reason copy and layout wait for
DESIGN-N5 (D-7, §2). Copy lives in one file so the approved text is a one-file change.

1. `packages/aiur-mobile/src/api/notificationSettings.ts` (PROPOSED): typed client for
   gateway `GET/PATCH /v1/notification-settings` (with `expected_version`) and instance
   `GET /api/v1/device/notification-options` (C1-T03); types generated from
   `aiur-contracts` (MP-N1-C2-T04).
2. `packages/aiur-mobile/src/screens/notifications/settingsModel.ts`: pure view model
   `buildRows(options, prefs, scope: "machine" | {instance_id}) → Row[]`, where
   `Row = {id, kind: "toggle" | "step" | "unavailable", value?, reason?, howTo?}`.
   An option with `state: "unavailable"` always becomes `kind: "unavailable"` carrying the
   reason code; `unknown` becomes `unavailable/unknown` (never a toggle).
3. `packages/aiur-mobile/src/screens/notifications/MachineSettingsScreen.tsx`,
   `InstanceOverrideScreen.tsx`, `StepPicker.tsx` (off / 10 / 25 / 50, completion toggle),
   `OptInList.tsx`, `UnavailableRow.tsx`.
4. `packages/aiur-mobile/src/screens/notifications/copy.ts`: option labels and reason
   strings keyed by option id / reason code, placeholders marked `// DESIGN-N5 D-7
   pending`. The reminder option (`commands_reminder_minutes`, MP-N5-C1-T01) appears only
   if DESIGN-N5 D-2 adopts reminders.
5. Routes `aiur://settings/notifications` and `…/instance/<instance_id>` in the N1-C4-T01
   route table.

## Non-happy paths

Covered in C4-T03 (offline, stale, conflict, unpaired). Here: an option id the app does
not know is skipped (newer daemon); a reason code the app does not know renders the
generic "Unavailable on this instance" row with the raw code, never a toggle.

## Compatibility and rollout

Unknown option ids from a newer daemon are ignored (N5 plan §6).

## Verification

`packages/aiur-mobile/test/screens/notifications/settingsModel.test.ts` and
`MachineSettingsScreen.test.tsx` (PROPOSED, Jest `jest-expo`). Test names carry the
DESIGN-N5 surface or decision:

| Test | Expected | Must fail without |
| --- | --- | --- |
| `§2 unavailable row: build orders absent shows disabled row with reason` (AC-N5-7) | `kind: "unavailable"`, `reason: "build_orders_not_installed"`, no switch rendered | render an `off` toggle (unknown-path mutation) |
| `§2 unavailable row: unknown capability is unavailable, not off` | `reason: "unknown"` | default to `off` |
| `§2 queue absent, build orders present: progress picker still enabled` (RC-40) | `bo:` step picker enabled | gate on `build_queue` |
| `§2 progress step picker offers off/10/25/50 only` | four choices | free numeric field |
| `§2 per-instance override saves to the gateway with expected_version` | one `PATCH /v1/notification-settings` with `instance_overrides["<instance_id>"]` | `PATCH` to the instance |
| `§2 commands_needs_you is shown locked on` | no switch, "always on" row | render a switch |
| `unknown reason code renders generic unavailable row` | generic row with code | crash or toggle |

Commands: `npm --prefix packages/aiur-mobile test -- test/screens/notifications/`.
Mutation check: revert each "Must fail without" hunk in a worktree and report the
command in the PR. Device: settings round-trip on the V-PR1 run (MP-N4-C7).

## Completion and handoff

- [ ] DESIGN-N5 approved copy replaces the placeholders in `copy.ts`. Dependents: C4-T02,
  C4-T03, C5-T01.
- Docs: `website/docs-app/guide/` notifications page (owned by MP-N5-C5-T01) shows the
  settings screens and the meaning of each unavailable reason.
