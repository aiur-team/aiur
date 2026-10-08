---
ticket_id: MP-N5-C4-T03
feature_id: MP-N5
chunk_id: MP-N5-C4
bucket: 3-mobile-watch
title: Settings offline, stale, save-conflict and unpaired states
status: blocked
blocked_by: [DESIGN-N5 (§4 states), MP-N5-C4-T01, MP-N1-C5-T01, RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1, MP-N2]
prior_findings: [N5 plan §6, client rule "reachability is separate" (identity-and-capabilities §3 rule 4)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C4-T03 — Settings failure states

## Identity and outcome

Bucket 3, MP-N5, chunk C4. Implement the DESIGN-N5 §4 states on the settings screens:
loading, saving, saved, save conflict (`409` → reload, keep the user's change, ask to
re-apply), instance offline (last-fetched options shown as stale with age, save disabled
for that instance's overrides), machine/gateway unreachable (defaults read-only), device
unpaired (`401 device_revoked` → pairing screen, wipe cached settings for that machine).

## Dependencies and blockers

**Blocked** on DESIGN-N5 §4 state designs; C4-T01; N1-C5-T01 (reachability probe that
distinguishes unreachable / stale / revoked without collapsing causes); RQ-TRANSPORT.

## Verified starting point

C1-T03 error shapes; pairing contract §4.2 (`401 device_revoked`), §9 (gateway offline
shown as "Gateway offline", not "no instances").

## Chosen design (fixed parts)

Stale data always shows its age (AGENTS.md "If a surface computes an age, it renders the
age"); unreachable ≠ unavailable ≠ stale (identity-and-capabilities §3 rule 4).

## Implementation steps

Build the state machine and tests now; only the copy and layout of each state wait for
DESIGN-N5 §4.

1. `packages/aiur-mobile/src/screens/notifications/settingsState.ts` (PROPOSED): pure
   reducer over events `load_start | load_ok | load_err(cause) | save_start | save_ok |
   save_conflict(current) | save_err(cause) | reachability(probe)`, states keyed by the
   DESIGN-N5 §4 names: `loading`, `loaded`, `saving`, `saved`, `save_conflict`,
   `instance_offline{observed_at}`, `machine_unreachable{observed_at}`,
   `os_denied` (from C4-T02), `option_unavailable` (per row, C4-T01), `device_unpaired`.
   Causes stay distinct: `unreachable`, `stale`, `revoked`, `unknown` (N1-C5-T01 probe;
   identity §3 rule 4) — no shared "error" state.
2. `save_conflict`: on `409` re-fetch, keep the user's pending patch, show the server
   value beside it, require an explicit re-apply (never auto-merge).
3. `device_unpaired` (`401 device_revoked`): wipe cached settings for that machine and
   route to the pairing screen.
4. Ages: every stale value renders `observed_at` as a relative age (AGENTS.md computed-age
   rule) via the shared N1 age formatter.

## Non-happy paths

This ticket is the non-happy paths. Additionally: a `load_err` whose cause the probe
cannot classify → `unknown` with the raw code, never folded into `machine_unreachable`.

## Compatibility and rollout

n/a — app-only.

## Verification

`packages/aiur-mobile/test/screens/notifications/settingsState.test.ts` (PROPOSED). One
test per DESIGN-N5 §4 state:

| Test | Expected | Must fail without |
| --- | --- | --- |
| `§4 instance offline: offline instance disables save and shows age` | `save` disabled for that instance; age text present | render the live toggle enabled / drop the age |
| `§4 machine unreachable: defaults read-only with age` | read-only | allow edits |
| `§4 save conflict: keeps user change and asks to re-apply` | pending patch kept; no second PATCH until re-apply | last-writer-wins resend |
| `§4 device unpaired: 401 device_revoked wipes cache and routes to pairing` | cache empty; route `pairing` | show "offline" |
| `§4 unknown cause is not collapsed into unreachable` | state `unknown` | `_ -> machine_unreachable` (AGENTS.md collapsed-cause rule) |
| `§4 saving → saved` | transitions | skip `saving` |

Commands: `npm --prefix packages/aiur-mobile test -- test/screens/notifications/settingsState.test.ts`.

## Completion and handoff

- [ ] Every DESIGN-N5 §4 state has a test. Dependents: C5-T01.
- Docs: covered by the MP-N5-C5-T01 guide page (states listed there); no separate page.
