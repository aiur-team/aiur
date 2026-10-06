# MP-N6 tickets — contextual Command response on phone and watch

Base `45a290e3`, researched 2026-10-06. Plan: [../plan.md](../plan.md); chunks:
[../chunks.md](../chunks.md). Gate: [DESIGN-N6](../../../owner-design-tasks/DESIGN-N6.md)
(with DESIGN-E2, DESIGN-E5 normative; DESIGN-N7 for the watch). Status semantics as in
[MP-N4 tickets/README.md](../../MP-N4/tickets/README.md). DESIGN-N6 releases the device
Command API (C1) before approval: `DESIGN-N6 (no-UI release)`.

## Tickets

| ID | Title | Status | Blocked by (beyond DESIGN-N6) | Wave |
| --- | --- | --- | --- | --- |
| [MP-N6-C1-T00](MP-N6-C1-T00.md) | Post-refactor path refresh | ready | R1-C1, MP-E2-C1-T01, MP-E2-C3-T01, MP-N2-C6-T01 | 0 |
| [MP-N6-C1-T01](MP-N6-C1-T01.md) | Device scope + GET command view | ready | C1-T00, MP-N2-C6-T01, MP-E2-C1-T01/T04, MP-E4-C3, RQ-TRANSPORT | 1 |
| [MP-N6-C1-T02](MP-N6-C1-T02.md) | GET needs_you list | ready | C1-T01, MP-E2-C2-T02 | 2 |
| [MP-N6-C1-T03](MP-N6-C1-T03.md) | POST answer (device actor, D11, replace, retry) | ready | C1-T01, MP-E2-C3-T01, MP-E2-C3-T02 | 2 |
| [MP-N6-C1-T04](MP-N6-C1-T04.md) | Capability gating + typed errors | ready | C1-T03, MP-R1 capability registry | 3 |
| [MP-N6-C2-T01](MP-N6-C2-T01.md) | Pure destination resolver | ready | MP-N4-C4-T02/C5-T02, MP-N2-C5-T05, N1-C3-T01 | 3 |
| [MP-N6-C6-T02](MP-N6-C6-T02.md) | Foreground reconciliation of delivered notifications | ready | C1-T02, MP-N4-C4-T02/C5-T02, RQ-TRANSPORT | 4 |
| [MP-N6-C2-T02](MP-N6-C2-T02.md) | Tap landing (cold/warm, no audio) | **blocked** | **DESIGN-N6 landing states**, DESIGN-N1, C2-T01, N1-C6-T01, N1-C4-T01 | 4 |
| [MP-N6-C2-T03](MP-N6-C2-T03.md) | Existing conversation + anchor scroll | **blocked** | **DESIGN-N1 surface, DESIGN-E4**, C2-T02, MP-E4-C3/C5 | 5 |
| [MP-N6-C3-T01](MP-N6-C3-T01.md) | Phone Command screen | **blocked** | **DESIGN-N6 §3, DESIGN-E2 §4.1–4.2/D-4**, DESIGN-N1, C1-T01, C2-T02, N1-C4-T01, RQ-TRANSPORT | 5 |
| [MP-N6-C3-T02](MP-N6-C3-T02.md) | Outcome states + Replace | **blocked** | **DESIGN-E2 §4.4, DESIGN-N6**, C3-T01, C1-T03 | 6 |
| [MP-N6-C3-T03](MP-N6-C3-T03.md) | Unreachable/offline + draft retention | **blocked** | **DESIGN-N6 D-1 (OQ-N6-1)**, C3-T01, N1-C5-T01, RQ-TRANSPORT | 6 |
| [MP-N6-C4-T01](MP-N6-C4-T01.md) | Mic button + Dictate/Converse sheet | **blocked** | **DESIGN-E5, DESIGN-N6**, C3-T01, N1-C3-T02, C1-T04 | 6 |
| [MP-N6-C4-T02](MP-N6-C4-T02.md) | Dictate via device voice path | **blocked** | **DESIGN-N6**, **MP-E5-C8-T01 (RC-16)**, DESIGN-E5, C4-T01, RQ-TRANSPORT | 7 |
| [MP-N6-C4-T03](MP-N6-C4-T03.md) | Converse with Command context | **blocked** | **DESIGN-N6**, **MP-E6-C7-T01, MP-E6-C5-T05 + E6-OQ9 spike**, DESIGN-E5/E6, C4-T02, MP-E5-C8-T01, RQ-TRANSPORT | 8 |
| [MP-N6-C4-T04](MP-N6-C4-T04.md) | Mic permission + cloud-voice disclosure | **blocked** | **DESIGN-N6**, **DESIGN-E5**, C4-T01 | 7 |
| [MP-N6-C5-T01](MP-N6-C5-T01.md) | Watch Command card | **blocked** | **DESIGN-N6 §3/D-4/D-5, DESIGN-N7**, MP-N7 apps, MP-N4-C6-T01 | 8 |
| [MP-N6-C5-T02](MP-N6-C5-T02.md) | Watch mic or hand-off | **blocked** | **DESIGN-N7 D-N7-3/D-N7-4 (OQ-N6-3)**, DESIGN-N6, DESIGN-E5, N7-C4 | 9 |
| [MP-N6-C5-T03](MP-N6-C5-T03.md) | Open on phone hand-off | **blocked** | **DESIGN-N7**, C5-T01, C2-T01, N7-C1 | 9 |
| [MP-N6-C6-T01](MP-N6-C6-T01.md) | Live sync on open screen (polling v1) | **blocked** | **DESIGN-N6 §5 stale states**, C3-T02, RQ-TRANSPORT | 7 |

Totals: 20 tickets — C1 5, C2 3, C3 3, C4 4, C5 3, C6 2. **Ready 7, blocked 13.**
Every user-visible ticket is blocked by design content (DESIGN-N6/E2/E5/N7), as the brief
requires; the server API (C1), the resolver (C2-T01) and the foreground reconciliation
(C6-T02) are specified and buildable once their predecessors land.

## Order

```text
C1-T00 ─► C1-T01 ─► {C1-T02, C1-T03} ─► C1-T04
MP-N4 acceptance ─► C2-T01 ─► C2-T02 ─► {C2-T03, C3-T01} ─► {C3-T02, C3-T03, C4-T01} ─► {C4-T02, C4-T03, C4-T04, C6-T01}
C1-T02 ─► C6-T02 ;  MP-N7 + C1-T03 ─► C5-T01 ─► {C5-T02, C5-T03}
```

## May run concurrently

C1-T02 ∥ C1-T03; C2-T01 ∥ C1 (different packages); C3-T02 ∥ C3-T03 ∥ C4-T01;
C4-T02 ∥ C4-T04; the watch chunk C5 ∥ phone C4 once MP-N7 exists.

## Boundary with MP-N1

MP-N1 owns OS notification-tap callbacks (MP-N1-C6-T01 `onNotificationOpened`), the in-app route table and `aiur://`
scheme (N1-C4-T01), the reachability probe (N1-C5-T01) and the capability affordance
resolver (N1-C3-T02). MP-N6 owns the destination resolver, the choice of landing screen and
its states, the Command screen, mic entry, the watch card content and reconciliation.

## Changes to plan/chunks made in Phase C

- Custom response limit is **4,000** characters (`Aiur.DecisionAnswer` `@response_max`,
  `decision_answer.ex:15`), not the 7,800-char dispatch cap the Phase B plan cited.
- Stale version arrives from the store as `{:answer_invalid, {:stale_version, e, c}}`
  (today a 422 on the supervisor API); the device API maps it to `409 stale_version`.
- Device routes: own scope before the `/api/v1/:issue_identifier` catch-alls; device auth +
  `x-aiur-request` header + `:require_writable` for answers (not `:api_write`, whose
  origin check rejects native clients).
- Destination uses `instance_id` (RC-02); RQ-TRANSPORT (RC-15) and the MP-E5 device voice
  path (RC-16) added as dependencies.
- C6-T01 decides polling (10 s, foreground) for v1; the events feed is a later switch after
  MP-R2-C7-T05.

## Changes made in Phase D (fix pass, 2026-10-06)

- Every design-blocked ticket now names its files, test files, test names keyed to the
  plan §5.5 state keys (`S01`–`S18`, DESIGN-N6 §5 order), the exact command, a "Must fail
  without" column and a docs line. Only copy and layout stay design-pending (review T-1, T-5, T-6).
- C4-T03 (phone Converse) has a per-code state table driven by voice-session §8.1 and the
  shared fixture `fixtures/contract/voice/end-reasons.json`; it reuses C4-T02's
  `deviceVoiceClient` and now depends on C4-T02 (feasibility M2, M7).
- A Converse draft is confirmed only by the Confirm button; voice answers carry a "via
  voice" tag (security m4). Phones keep no Command or transcript text on disk (security M5).
- Wire keys `option_id` / `custom_response` (X-13); `push` is optional for the Command
  screen (X-56); the watch late-answer path is the deliberate exception to OQ-N6-1
  (feasibility m6, plan §6).

Contract requests: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).
