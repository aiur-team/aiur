---
feature_id: MP-N6
base_main_sha: 45a290e3
date: 2026-10-06
---

# MP-N6 chunks

**Phase C (2026-10-06):** full ticket docs in [tickets/](tickets/README.md). Changes: the
answer limit is 4,000 characters (not 7,800); C1 device routes get their own scope (device
auth + `x-aiur-request` + `:require_writable`); C6-T01 polls in v1; RQ-TRANSPORT (RC-15)
and the MP-E5 device voice path (RC-16) are explicit dependencies.

**Phase D (2026-10-06):** blocked tickets carry concrete test files, commands and state
keys (plan §5.5); C4-T03 handles every voice end reason (voice-session §8.1). See
[tickets/README.md](tickets/README.md) "Changes made in Phase D".

| Chunk | Outcome | Depends on | Design gate |
| --- | --- | --- | --- |
| MP-N6-C1 | Device Command API (read, list needs-you, answer with D11 outcomes) | MP-E2 answer contract, MP-N2 device auth plug, MP-R1 web-shell | none (no UI) |
| MP-N6-C2 | Destination resolver and app routing (cold/warm start, existing conversation) | MP-N4-C4/C5 (tap payload), MP-N2 registry, MP-E4 anchors | blocked-by-design |
| MP-N6-C3 | Phone Command response screen and outcome states | C1, C2, MP-N1 shell | blocked-by-design (DESIGN-N6 + DESIGN-E2) |
| MP-N6-C4 | Mic entry: Dictate/Converse choice, permission, provider disclosure | C3, MP-E5 device voice path, MP-E6 component | blocked-by-design (DESIGN-E5) |
| MP-N6-C5 | Watch Command card and phone handoff | C1, MP-N7 app, MP-N4-C6 | blocked-by-design (DESIGN-N6 + DESIGN-N7) |
| MP-N6-C6 | Live resolution sync on open screens and notification cleanup | C3, MP-N4 retraction, MP-R2 external events or polling | blocked-by-design |

---

## MP-N6-C1 — Device Command API

- MP-N6-C1-T00 Plan refresh to post-refactor web-shell/commands paths.
- MP-N6-C1-T01 `GET /api/v1/device/commands/:id` view model from the E2 presentation
  fields (DESIGN-E2 §4.1–4.2), routing state, version, requester, anchor ref; 404 vs
  `withdrawn` distinction.
- MP-N6-C1-T02 `GET /api/v1/device/commands?state=needs_you` for reconciliation on app
  open (counts used by MP-N3 meta-dashboard too).
- MP-N6-C1-T03 `POST …/answer` mapping to E2 answer with `actor = device` from the
  credential; outcome table plan §5.2; 4,000-char `custom_response` limit
  (`decision_answer.ex:15`); stale version → 409; idempotency replay; `replace` → human
  supersede.
- MP-N6-C1-T04 Capability gating (`commands.read`, `commands.answer`) and revoked-device
  behaviour (no data leak).

Tests: forged-actor test (AC-N6-8); concurrent answers (AC-N6-3); supersede window
(AC-N6-4); idempotent retry (AC-N6-5); revoked (AC-N6-6). Each test reverts-to-fail per
`AGENTS.md`.

## MP-N6-C2 — Destination resolver and routing

- MP-N6-C2-T01 Pure resolver implementing contract §3.1 degrade rules with fixtures for
  every missing level.
- MP-N6-C2-T02 Notification-tap handling (iOS `UNUserNotificationCenter` response,
  Android pending intent) → resolver; no audio session created.
- MP-N6-C2-T03 Existing-conversation detection and anchor scroll (MP-E4).

## MP-N6-C3 — Phone response screen

- MP-N6-C3-T01 Context block, options (2–3, recommended first), custom response, disclosure
  of option details (DESIGN-E2 §4).
- MP-N6-C3-T02 Outcome states and Replace flow (plan §5.2).
- MP-N6-C3-T03 Unreachable/offline with draft retention and Retry.

## MP-N6-C4 — Mic entry

- MP-N6-C4-T01 Mic button availability from capabilities; choice sheet (D16).
- MP-N6-C4-T02 Dictate path via the MP-E5 service with review-before-send per DESIGN-E5.
- MP-N6-C4-T03 Converse path launching MP-E6 seeded with Command context; confirm-to-answer.
- MP-N6-C4-T04 OS mic permission flow and cloud-provider disclosure line.

## MP-N6-C5 — Watch card

- MP-N6-C5-T01 Compact card + option buttons + outcome line (MP-N7 app).
- MP-N6-C5-T02 Mic choice on watch or handoff, per OQ-N6-3.
- MP-N6-C5-T03 "Open on phone" handoff to the same Command.

## MP-N6-C6 — Live resolution sync

- MP-N6-C6-T01 While a Command screen is open, observe state changes (MP-R2 external
  subscription when available; else 10 s polling while foregrounded only).
- MP-N6-C6-T02 On app foreground, reconcile delivered notifications against
  `needs_you` and remove resolved ones (complements MP-N4 retraction).

Device tests: V-N1..V-N4, V-M1..V-M3, V-W2 in [../MP-N4/device-validation-plan.md](../MP-N4/device-validation-plan.md).
