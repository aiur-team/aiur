---
ticket_id: MP-N6-C1-T03
feature_id: MP-N6
chunk_id: MP-N6-C1
bucket: 3-mobile-watch
title: POST /api/v1/device/commands/:id/answer — device actor, D11 outcomes, replace, idempotent retry
status: ready
blocked_by: [DESIGN-N6 (no-UI release), MP-N6-C1-T01, MP-E2-C3-T1, MP-E2-C3-T2]
prior_units: []
prior_boundaries: [DEC #27, WEB #34]
prior_features: [MP-E2, MP-N2]
prior_findings: [decision_store.ex:183-193 (actor is trusted runtime identity), D11, A-E2-4]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C1-T03 — Device answer endpoint

## Identity and outcome

Bucket 3, MP-N6, chunk C1. `POST /api/v1/device/commands/:decision_id/answer` with body
`{expected_version, idempotency_key, option_id | custom_response, replace: false|true,
via: "tap"|"dictate"|"converse", surface: "phone"|"watch"}`. It records the answer with
`actor = %{kind: :operator, id: "device:" <> device_id}` where `device_id` comes from the
device token (never from the body), and maps every store result to one stable JSON
outcome. `replace: true` calls the human supersede path (D11).

## Dependencies and blockers

- C1-T01 (scope with `:device_auth`, `:device_write`, `:require_writable`).
- **MP-E2-C3-T1**: winner summary on `{:conflict, {:already_decided, _}}` and the guard
  that an Executor never supersedes a human. **MP-E2-C3-T2**: the human supersede API path
  (today supersede exists only for the Executor CLI; command contract §6 rule 3).
- DESIGN-N6 no-UI release. Outcome **copy** is DESIGN-E2 §4.4 (client side).

## Verified starting point

- `Aiur.DecisionStore.answer/5` (`decision_store.ex:190`): "`opts[:actor]` is trusted
  runtime identity; actor fields in the payload are ignored" (`:183-187`).
  `supersede/5` (`:287`): refusals `{:conflict, :answer_delivered}`,
  `{:conflict, :answer_in_flight}`, `{:not_decided, status}`, `{:conflict, status}`
  (`:265-281` moduledoc).
- Replay semantics (`evaluate_answer_replay/4`, `decision_store.ex:1539-1559`): same key and
  content → `{:ok, %{status: :duplicate, …}}`; same key other content →
  `{:conflict, {:idempotency_conflict, action_id}}`; other key →
  `{:conflict, {:already_decided, action_id}}`.
- `Aiur.DecisionAnswer` payload keys `idempotency_key` (≤ 200), `expected_version`,
  `option_id` (≤ 200), `custom_response` (≤ **4,000** chars, `@response_max`,
  `decision_answer.ex:15,55-59`); version mismatch →
  `{:stale_version, expected, current}` (`:158-159`), surfaced as
  `{:answer_invalid, {:stale_version, …}}`; option and custom together → `{:response,
  :ambiguous}`. The N6 Phase B plan cited the 7,800-char dispatch cap
  (`decision_dispatch.ex:22`); the binding limit for an answer is the 4,000 validation cap.
- Retired Commands: `{:conflict, status}` for `:expired | :moot | :resolved`
  (`decision_store.ex:1440-1441`).
- Actor precedent: Stream Deck answers as `%{kind: :operator, id: "streamdeck"}`
  (`streamdeck_commands.ex:15-19`); dashboard as `DecisionCommands.actor/0`
  (`decision_commands.ex:82-83`).

## Chosen design

| Store result | HTTP | Body |
| --- | --- | --- |
| `{:ok, %{status: :duplicate}}` | 200 | `{"outcome":"duplicate", "delivery": …}` |
| `{:ok, accepted}` | 200 | `{"outcome":"accepted","delivery":{"status": …}}` |
| `{:error, {:conflict, {:already_decided, _}}}` | 409 | `{"error":"decision_conflict","reason":"already_decided","winner":{actor_kind,accepted_at,summary,delivery_status},"replaceable":bool}` |
| `{:error, {:conflict, {:idempotency_conflict, _}}}` | 409 | `reason: "idempotency_conflict"` |
| `{:error, {:conflict, :answer_in_flight}}` | 409 | `reason: "answer_in_flight"` |
| `{:error, {:conflict, :answer_delivered}}` | 409 | `reason: "answer_delivered"` |
| `{:error, {:answer_invalid, {:stale_version, e, c}}}` | 409 | `reason: "stale_version", "current_version": c` |
| `{:error, {:conflict, s}}` for `s in [:expired, :moot, :resolved]` | 409 | `reason: "withdrawn", "status": s` |
| `{:error, {:not_decided, _}}` on replace | 409 | `reason: "nothing_to_replace"` |
| other `{:answer_invalid, _}` | 422 | `{"error":"invalid_request","field": …}` |
| `custom_response` > 4,000 chars | 422 | `field: "custom_response", "max": 4000` (checked before calling the store) |
| store unavailable | 503 | `decision_service_unavailable` |

- `replaceable` = winner is undelivered and not in flight and the caller is human (always
  true for devices) — D11 for an Executor winner, command contract §6 rule 5 for a human
  winner.
- When MP-E2 adds `client: {surface, device_id}` to the answer (command contract §6), pass
  it from the token and `surface`; until then the `actor.id` carries `device:<id>`.
- `via` is recorded in the answer's `rationale`-free metadata only if E2 provides a field;
  otherwise dropped (never put into `custom_response`).

## Implementation steps

1. `answer/2` in `DeviceCommandController`; `DeviceCommandOutcome.to_json/1` (PROPOSED)
   pure mapper.
2. Tests (store started with a temp `decision_state_dir`).

## Non-happy paths

- Network failure after submit → the app retries with the **same** `idempotency_key`;
  the store returns `duplicate` (AC-N6-5).
- Two devices answer concurrently → exactly one `accepted`, the other `already_decided`
  naming the first (AC-N6-3).
- Read-only dashboard (`dashboard_writable: false`) → `403 {"error":"dashboard is
  read-only"}` from `:require_writable` (`router.ex:230-241`); capability
  `commands.answer` reports `unavailable/disabled` (MP-R1).
- Device revoked mid-flight → `401`, nothing recorded.

## Compatibility and rollout

New route. Rollback: remove; no data migration (answers are ordinary DecisionStore
records).

## Verification

`src/test/aiur_web/controllers/device_command_controller_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"forged actor in body is ignored; recorded actor is the device"` (AC-N6-8) | stored `actor.id == "device:<token device>"` | take actor from body |
| `"concurrent answers: one accepted, one already_decided with winner"` (AC-N6-3) | as stated | drop winner mapping |
| `"retry with same key is duplicate"` (AC-N6-5) | 200 `duplicate`, one record | new key per request server-side |
| `"replace supersedes an undelivered Executor answer"` (AC-N6-4) | `accepted`; worker receives only the human answer (dispatch fake) | call `answer/5` for replace |
| `"replace after delivery is answer_delivered"` | 409 | map to 503 |
| `"stale version is 409 with current_version"` | 409 | leave as 422 |
| `"custom_response over 4000 chars is 422 before the store"` | 422, store untouched | rely on 7,800 |
| `"read-only dashboard refuses device answers"` | 403 | skip `:require_writable` |

Commands (from `src/`): `mise exec -- mix test test/aiur_web/controllers/device_command_controller_test.exs`.

## Completion and handoff

- [ ] AC-N6-3/4/5/8 covered; outcome table mirrored in contract A-E2-4 (no change needed).
- Dependents: C3-T02, C5-T01.
