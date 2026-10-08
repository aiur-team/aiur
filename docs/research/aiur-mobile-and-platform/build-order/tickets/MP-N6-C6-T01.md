---
ticket_id: MP-N6-C6-T01
feature_id: MP-N6
chunk_id: MP-N6-C6
bucket: 3-mobile-watch
title: Live resolution sync on an open Command screen (foreground polling; export feed later)
status: blocked
blocked_by: [DESIGN-N6 (§5 stale/resolved states), MP-N6-C3-T02, MP-N6-C1-T01, RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-R2 (C7-T05 paired-device read scope, later)]
prior_findings: [events-and-replay §7.2 (external clients reconcile by snapshot), identity-and-capabilities §3 rule 5]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C6-T01 — Live sync while open

## Identity and outcome

Bucket 3, MP-N6, chunk C6. While a Command screen is foregrounded, refresh the view every
10 s (`GET /api/v1/device/commands/:id`, compare `version`/status/delivery) and move the
screen to the right state when the Command is answered elsewhere, superseded, withdrawn or
delivered. Polling stops in background. When MP-R2-C7-T05 (paired-device read scope on the
events feed) lands, switch to the feed with polling as fallback — a separate follow-up, not
this ticket.

## Dependencies and blockers

**Blocked** on DESIGN-N6 §5 presentation of "answered elsewhere"/"stale" while the user is
mid-edit (keep draft vs discard is a design call); C3-T02; RQ-TRANSPORT.

## Verified starting point

Events-and-replay §7.2: clients bootstrap from snapshots and treat events as "refresh the
object"; R2-C7-T05 is blocked on MP-N2 today.

## Chosen design (fixed parts)

Decision: polling in v1 (10 s, foreground only) because the paired-device feed scope is
not yet specified (R2-C7-T05 blocked on MP-N2); cost ≤ 6 requests/minute per open screen.

- `pollCommand(id, {intervalMs: 10000})` runs only while the screen is focused and the app
  is `active` (`AppState`), and stops on blur, background and terminal status.
- Transition rule on change while the user is mid-edit: the draft is kept and the screen
  moves to the new state with the draft visible (S06/S07/S09/S10); whether a kept draft is
  shown or collapsed is DESIGN-N6 §5 (design-pending). The rule "never auto-submit a kept
  draft" is fixed.
- Failure: keep the last state, show its age (`observed_at`, AGENTS.md age rule), back
  off to 30 s; never render "no change" for an unknown age.

## Implementation steps

1. `packages/aiur-mobile/src/commands/pollCommand.ts` (injected clock and fetch).
2. Hook into `commandViewModel` (C3-T01); reuse `outcomeToState` (C3-T02) for status →
   state.
3. Age label in `CommandScreen` header when the last poll failed.
4. Docs: none, because polling is internal; the "answered elsewhere" states are already
   in the C3-T01/T02 guide section.

## Non-happy paths

Poll failure → keep state, show age, back off to 30 s. `401 device_revoked` during a poll →
S12 and wipe (C3-T02). Command purged → S13.

## Compatibility and rollout

v1 polling; the feed switch after MP-R2-C7-T05 is a follow-up.

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/commands/pollCommand.test.ts
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `S06_answeredElsewhereTransitionsWithinOnePoll` | fake clock +10 s → S06 with winner | the poll |
| `S09_withdrawnDisablesForm` | status `expired` → S09 | the terminal mapping |
| `pollStopsInBackground` | `AppState` background → no fetch for 60 s fake time | the stop |
| `failureShowsAgeAndBacksOff` | failed fetch → age label, next poll at 30 s | the age render (plausible default "just now" → fails) |
| `keptDraftNeverAutoSubmits` | after S10 the draft is visible and no answer request is made | the guard |
| `S12_revokedDuringPollWipes` | 401 → S12, drafts deleted | the revoke branch |

Device: V-M1, V-M2.

## Completion and handoff

- [ ] Each test fails with its hunk reverted in a worktree.
- [ ] Follow-up recorded for the feed switch after R2-C7-T05.
