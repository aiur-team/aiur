---
ticket_id: MP-N6-C3-T02
feature_id: MP-N6
chunk_id: MP-N6-C3
bucket: 3-mobile-watch
title: Phone outcome states and the Replace flow (D11)
status: blocked
blocked_by: [DESIGN-N6 (§3 outcome states, §5), DESIGN-E2 §4.4 (outcome copy), MP-N6-C3-T01, MP-N6-C1-T03]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-E2]
prior_findings: [N6 plan §5.2 outcome table, D11]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C3-T02 — Outcome states and Replace

## Identity and outcome

Bucket 3, MP-N6, chunk C3. Map every C1-T03 outcome to a phone state: accepted →
delivering → delivered (live, C6-T01); `duplicate` → same as original; `already_decided`
→ who/when/what, with **Replace** only when `replaceable` (confirmation per DESIGN-N6
§3); `answer_in_flight` → "Delivering now — can't replace"; `answer_delivered` → as
already decided without Replace; `stale_version` → reload, keep draft/selection if option
ids still exist; `withdrawn` → "No longer needed: <status>", form disabled;
`idempotency_conflict` → error, no auto-retry; `401 device_revoked` → pairing screen and
wipe cached data for that machine; typed capability errors (C1-T04) → "answer from the
dashboard" state.

## Dependencies and blockers

**Blocked** on DESIGN-E2 §4.4 copy and DESIGN-N6 placement and Replace confirmation;
C3-T01; C1-T03.

## Verified starting point

C1-T03 outcome table (HTTP + body); command contract §6 rules 1–5.

## Chosen design (fixed parts)

- Replace sends `replace: true` with a **new** idempotency key and the current
  `expected_version`.
- `outcomeToState(httpStatus, body) → StateKey` is a pure, total function over the C1-T03
  table (plan §5.5 keys):

| C1-T03 response | State |
| --- | --- |
| 200 `accepted` | S04 → S05 when `delivery.status` becomes delivered (C6-T01) |
| 200 `duplicate` | same as the original outcome |
| 409 `already_decided`, `replaceable: true` | S07 (Replace offered, confirmation per DESIGN-N6) |
| 409 `already_decided`, `replaceable: false` | S06 (who / when / what from `winner`) |
| 409 `answer_in_flight` | S08 "Delivering now — can't replace" |
| 409 `answer_delivered` | S06 without Replace |
| 409 `stale_version` | S10: refetch, keep draft and selection if option ids still exist |
| 409 `withdrawn` (`status`) | S09 "No longer needed: <status>", form disabled |
| 409 `nothing_to_replace` | refetch → S02 |
| 409 `idempotency_conflict` | error state, no auto-retry |
| 401 `device_revoked` / `device_auth_disabled` | S12 pairing screen; wipe that machine's drafts and in-memory data |
| `capability_unavailable` (C1-T04) | S17 "Answer from the dashboard" |
| network error | S11 (C3-T03), same key on Retry |
| anything else | generic conflict + refresh; never success |

- The winner's actor kind is shown as-is (`operator`, `operator_relayed`, `executor`); a
  relayed answer is labelled as relayed (RC-41), never as the user's own.

## Implementation steps

1. `packages/aiur-mobile/src/commands/outcomeToState.ts` (pure).
2. `packages/aiur-mobile/src/commands/OutcomeBanner.tsx` and `ReplaceConfirm.tsx`.
3. Wire into `commandViewModel.submit` (C3-T01).
4. Docs: none beyond the C3-T01 guide section, because the outcomes are part of the same
   "Answering a Command" page (add one paragraph on Replace there, same PR).

## Non-happy paths

This ticket is the non-happy paths of submission (table above).

## Compatibility and rollout

Unknown `reason` from a newer daemon → generic conflict state + refresh (never treated as
success). Copy is DESIGN-E2 §4.4 (design-pending).

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/commands/outcomeToState.test.ts test/commands/OutcomeBanner.test.tsx
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `outcomeToState: each C1-T03 row` (`it.each` over a fixture copied from the C1-T03 table) | the state in the table | each row (replace with one generic conflict → fails) |
| `S07_replaceOnlyWhenReplaceable` | Replace shown only for `replaceable: true` | the flag check |
| `replaceUsesNewKeyAndCurrentVersion` | body `replace: true`, new key, current version | key regeneration |
| `S10_staleKeepsDraftWhenOptionsSurvive` | selection kept when option id still exists, dropped otherwise | the keep rule |
| `S12_revokedWipesMachineData` | drafts for that machine deleted | the wipe |
| `unknownReasonIsNeverSuccess` | unknown reason → generic conflict | default branch (map to S04 → fails) |
| `relayedWinnerLabelledRelayed` | winner `operator_relayed` → relayed label | the label |

Device: V-M2, V-M3.

## Completion and handoff

- [ ] Each test fails with its hunk reverted in a worktree.
- Dependents: MP-N4-C7-T02 (V-M1..V-M3), C6-T01.
