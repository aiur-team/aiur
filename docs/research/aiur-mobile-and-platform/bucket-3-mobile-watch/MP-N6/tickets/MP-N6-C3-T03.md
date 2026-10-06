---
ticket_id: MP-N6-C3-T03
feature_id: MP-N6
chunk_id: MP-N6-C3
bucket: 3-mobile-watch
title: Unreachable/offline Command screen — sealed summary, draft retention, manual Retry
status: blocked
blocked_by: [DESIGN-N6 (D-1 / OQ-N6-1, unreachable state), MP-N6-C3-T01, MP-N1-C5-T01, RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1, MP-N4]
prior_findings: [AC-N4-6, V-R3, V-R4]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C3-T03 — Unreachable and offline

## Identity and outcome

Bucket 3, MP-N6, chunk C3. When the instance cannot be reached (machine offline, tailnet
off, transport error), show the sealed summary from the notification plus "Can't reach
<machine>" and Retry; keep the draft (text, selected option, idempotency key) on device;
do **not** queue the answer for automatic later send unless DESIGN-N6 D-1 says so.

## Dependencies and blockers

**Blocked on DESIGN-N6 D-1 (OQ-N6-1)**: "queue offline answers for later automatic send?"
changes what is built (a durable client outbox and its staleness handling) — proposal is
"no". Also N1-C5-T01 (reachability classification: unreachable vs revoked vs TLS mismatch
without collapsing causes) and RQ-TRANSPORT.

## Verified starting point

MP-N4 AC-N4-6, V-R3, V-R4; pairing contract §9 (machine unreachable → last-known with age).

## Chosen design (fixed parts, valid for D-1 = no)

Draft stored in the app's encrypted storage keyed by `(instance_id, decision_id)`; Retry
re-fetches the view first (the Command may have resolved) and only then offers Send.

Fixed now:

- The draft (option id, typed text, `idempotency_key`, `expected_version`) is kept in
  secure storage (C3-T01 `draftStore`); Command text is not (plan §5.6).
- S11 shows the sealed summary from the tapped notification (if any) with "Can't reach
  <machine>" and the age of the last successful contact; never an empty form.
- Retry = refetch the view (C1-T01) first; if the version or status changed, go to the
  matching state (S06/S09/S10) with the draft kept; only an unchanged view re-enables Send,
  which then reuses the stored key (AC-N6-5).
- D-1 = no (proposal): nothing is sent automatically. If D-1 = yes, an automatic send uses
  the same refetch-first rule and the same key; that branch adds one test
  (`autoSendRefetchesFirst`) and nothing else.
- The watch `transferUserInfo` late answer is the deliberate exception (plan §6); it does
  not use this phone path.

## Implementation steps

1. `packages/aiur-mobile/src/commands/retryPolicy.ts` (pure: view diff → next state).
2. `S11` view in `CommandScreen` using the reachability probe (MP-N1-C5-T01).
3. Draft expiry: discard when the Command's `expires_at` has passed, with a note.
4. Docs: one paragraph in the "Answering a Command" section of
   `website/docs-app/guide/mobile.md` (answers are not queued; Retry checks first).

## Non-happy paths

- Draft older than the Command's `expires_at` → discarded with a note.
- Machine revoked this device while offline → first Retry gets 401 → S12 and wipe.
- Network error after submit (unknown whether recorded) → Retry with the same key → the
  store answers `duplicate` if it was recorded.

## Compatibility and rollout

Copy is DESIGN-N6 (design-pending); the D-1 branch is a constant.

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/commands/retryPolicy.test.ts test/commands/draftStore.test.ts
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `S11_draftSurvivesAppRestart` | draft restored after a simulated cold start | secure storage |
| `retryRefetchesBeforeSubmitting` | Retry → fetch before any answer request | the refetch-first rule (Retry submits directly → fails) |
| `retryReusesStoredKey` | answer after an unchanged view carries the stored key | key reuse |
| `changedViewGoesToStateWithDraftKept` | version change → S10 with draft; resolved → S06/S09 | the diff branch |
| `S11_showsAgeOfLastContact` | age label from `observed_at` | the age render (plausible default "just now" → fails) |
| `expiredDraftDiscardedWithNote` | `expires_at` passed → draft deleted, note shown | expiry |

Device: V-R3, V-R4, DV-P10 (Wi-Fi → cellular during submit: one recorded answer).

## Completion and handoff

- [ ] D-1 recorded; each test fails with its hunk reverted in a worktree.
