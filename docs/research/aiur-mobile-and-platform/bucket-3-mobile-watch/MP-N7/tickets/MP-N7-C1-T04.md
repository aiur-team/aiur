---
ticket_id: MP-N7-C1-T04
feature_id: MP-N7
chunk_id: MP-N7-C1
bucket: 3-mobile-watch
title: Late-answer guard for queued watch answers (Swift and Kotlin, shared fixtures)
status: blocked
blocked_by: [DESIGN-N7, DESIGN-N6, MP-N7-C1-T01, MP-N6-C1-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-E2, MP-N6]
prior_findings: ["framework-evidence S6: background transfers are not delivered immediately"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C1-T04 — Late-answer guard

## Identity and outcome

- Bucket 3, MP-N7, chunk C1.
- **User value:** an answer tapped on the watch while the phone was away can never land
  later on a question that has changed or gone stale.
- **Deliverable:** a pure function `LateAnswerGuard.check(answer, currentCommand, now,
  budget) → .submit | .stale(reason)` in both native cores (`AiurClientKit`,
  `aiur-client-core`), driven by one fixture table, called by both brokers before every
  answer submit.
- **Non-goals:** server-side concurrency (the server enforces `expected_version` itself,
  `contracts/command-request-and-resolution.md` §2/§6); UI copy (DESIGN-N7 "stale" state).

## Dependencies and blockers

- DESIGN-N7 and DESIGN-N6 (the stale budget is a product number; the default below is a
  proposal for those gates to confirm).
- MP-N7-C1-T01 (answer model has `created_at`, `expected_version`), MP-N6-C1-T01 (the read
  endpoint that supplies the current `version` and `status`).
- Concurrent with C1-T02/T03 (they call the guard through an interface; a stub returning
  `.submit` is not allowed in merged code: the brokers' tests depend on the real guard).

## Verified starting point

- Server-side optimistic concurrency exists: every write carries `expected_version`
  (`command-request-and-resolution.md` §2 "`version` … existing"); terminal statuses
  `expired`, `moot`, `resolved` refuse answers (`decision_store.ex:1440-1443`, cited in
  that contract §6 rule 6).
- Why a client guard is still needed: the server accepts an answer whose
  `expected_version` matches even if the human's choice was made long ago. A
  `transferUserInfo` answer queued on the watch may be delivered "not … immediately"
  (framework-evidence S6), possibly hours later.
- Nothing exists in client code at `45a290e3`.

## Chosen design

Inputs: the queued `answer` (`created_at`, `expected_version`), the Command freshly
fetched by the broker (never a cached copy), `now` from the phone clock, and
`budget_seconds` (default **600 s**, proposal for DESIGN-N6/N7, equal to the client
capability model's write-staleness reasoning: a 10-minute-old intent is no longer a live
decision).

```text
if command.status in {resolved, expired, moot}      → stale(resolved_elsewhere)
if command.version != answer.expected_version       → stale(question_changed)
if now - answer.created_at > budget_seconds         → stale(too_old)
if answer.created_at > now + 120 s                  → stale(clock_skew)     # watch clock ahead
else                                                → submit
```

- Applies to **both** paths (immediate `sendMessage` and queued `transferUserInfo`), so the
  rule is uniform; on the immediate path the age check is trivially satisfied.
- Fetch failure (unreachable) is not a guard decision: the broker returns `failed
  {unreachable}` and keeps nothing queued; the watch shows "Not confirmed. Check on phone."
  (plan §8). The guard never submits without a fresh fetch.
- `stale` results are returned to the watch as `answer_result.outcome = stale` with the
  reason; the watch then shows the current card if it can fetch it.

## Implementation steps

1. `fixtures/watch-link/late-answer-guard.json`: rows `{answer, command, now, expected}`.
2. Swift `LateAnswerGuard` in `native/apple-core/Sources/AiurClientKit/WatchLink/` (PROPOSED).
3. Kotlin `LateAnswerGuard` in `native/android-core/.../watchlink/` (PROPOSED).
4. Table-driven tests in both languages reading the same fixture.
5. Brokers (C1-T02/T03) call `check` between fetch and submit.

## Non-happy paths

- Clock skew phone vs watch: `created_at` is stamped by the watch; a watch clock ahead by
  more than 120 s yields `stale(clock_skew)` rather than a negative age passing the check.
- Command deleted on the server (404 from MP-N6-C1-T01, distinct from `withdrawn`): broker
  maps to `stale(resolved_elsewhere)` only if the read API says `withdrawn`; a bare 404 is
  `unknown` (never guessed as resolved).
- Duplicate queued deliveries: same `idempotency_key`; server returns `:duplicate`.

## Compatibility and rollout

Pure client logic, no config. Budget is a constant until DESIGN-N6/N7 asks for a setting.

## Verification

```text
xcodebuild test -scheme AiurClientKit -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:AiurClientKitTests/LateAnswerGuardTests
packages/aiur-mobile/native/android-core/gradlew -p packages/aiur-mobile/native/android-core test --tests '*LateAnswerGuardTest'
```

| Fixture row | Expected | Must fail without |
|---|---|---|
| version 4 vs expected 3 | `stale(question_changed)` | the version comparison (the mutation named in chunks.md) |
| status `resolved` | `stale(resolved_elsewhere)` | the status check |
| age 601 s | `stale(too_old)` | the age check |
| age 599 s, same version | `submit` | — (positive control) |
| created 5 min in the future | `stale(clock_skew)` | the skew check |

## Completion and handoff

- [ ] Guard in both cores; shared fixture; both suites pass and each row fails with its
  branch removed.
- [ ] Docs: none.
- Dependents: MP-N7-C1-T02, MP-N7-C1-T03, MP-N7-C6 (DV-W4 late variant).
