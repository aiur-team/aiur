---
ticket_id: MP-N4-C3-T06
feature_id: MP-N4
chunk_id: MP-N4-C3
bucket: 3-mobile-watch
title: Privacy guard tests — no summary or identifiers in daemon logs or relay requests
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C3-T03]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: []
prior_findings: [AC-N4-2, contract §1 visibility table, plan §7.6 logging rule]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C3-T06 — Privacy guard tests

## Identity and outcome

Bucket 3, MP-N4, chunk C3. A focused test suite (plus any small production fixes it
reveals) proving AC-N4-2 on the daemon side: the HTTP request push-relay sends to the
relay carries **only** the contract v2 §8 fields, none of which contains repo name,
ticket number, Command id, machine id, instance key, device push secret or summary text
in clear; and daemon logs at every level contain none of those values.

Non-goals: packet capture at the relay and providers (C7 V-P1); relay-side logging
(C2-T01/T04 tests).

## Dependencies and blockers

- C3-T03. DESIGN-N4: no UI. Can run in parallel with C3-T04/T05.

## Verified starting point

- Contract v2 §1 table (relay never sees summary, repo, ticket, Command id, machine id,
  instance key); §8 envelope fields.
- Logger capture: ExUnit `capture_log/2` with `Logger.configure(level: :debug)` inside the
  test (the daemon uses `Logger`; `extra_applications: [:logger]`, `src/mix.exs:150`).

## Chosen design

A fixture intent whose every identifying field is a unique sentinel string
(`"SENTINEL-REPO-…"`, `"SENTINEL-TICKET-4711"`, Command id `"dec_SENTINEL…"`, machine id
sentinel, summary title/body sentinels). The fake relay records raw request bytes. After
a full accept → seal → send → record cycle, and after failure paths (429, 410, timeout,
encode failure), assert:

1. The JSON key set of each request body equals the §8 set exactly.
2. No sentinel appears in any request body, header or URL (the relay URL path contains
   only the handle).
3. No sentinel appears in captured logs at `:debug`.
4. `outbox.ndjson` and `device_state.json` contain no summary sentinel (intent bodies live
   only in `intents/<id>.json`, deleted at terminal state — assert deletion).

## Implementation steps

1. `src/test/aiur/push/privacy_test.exs` (PROPOSED) and a shared sentinel fixture.
2. Fix any leak found (expected: none if C1–C3 followed the contract).

## Non-happy paths

Covered by running the assertions on failure paths too (429/410/timeout/encode error) —
error logs are where leaks usually appear.

## Compatibility and rollout

Tests only (plus fixes). n/a for config.

## Verification

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"relay request body has exactly the envelope fields"` | set equality | add `"instance_id"` to the envelope |
| `"no sentinel in relay requests on success and failure paths"` | 0 matches | log or send `intent.summary` |
| `"no sentinel in debug logs"` | 0 matches | `Logger.debug(inspect(intent))` in Sender |
| `"intent body file deleted after terminal outcome"` | file absent | keep files |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/privacy_test.exs`.

## Completion and handoff

- [ ] Suite green; PR shows each test failing with the named leak injected.
- Dependents: MP-N4-C7 (V-P1 complements this on real traffic).
