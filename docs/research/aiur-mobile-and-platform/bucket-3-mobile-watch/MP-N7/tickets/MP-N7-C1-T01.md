---
ticket_id: MP-N7-C1-T01
feature_id: MP-N7
chunk_id: MP-N7-C1
bucket: 3-mobile-watch
title: Watch-link protocol v1 schemas, fixtures and cross-language decode check
status: blocked
blocked_by: [DESIGN-N7, MP-N1-C1-T01, MP-N1-C2-T04]
prior_units: []
prior_boundaries: ["SD #35 (precedent: hardware client that consumes daemon projections)"]
prior_features: [MP-N1, MP-N3, MP-E2]
prior_findings: ["baseline N7: no watch code exists"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C1-T01 — Watch-link protocol v1 schemas and fixtures

## Identity and outcome

- Bucket 3, feature MP-N7, chunk C1 (phone watch broker and watch-link protocol).
- **User value:** the phone and both watches agree, byte for byte, on what they send each
  other. Every later broker and watch ticket tests against the same files, so the Apple
  and Wear implementations cannot drift.
- **Deliverable:** JSON Schemas for every watch-link message in
  [../plan.md §4](../plan.md) (`snapshot`, `get_command`, `get_command_result`, `answer`,
  `answer_result`, `voice_turn`, `voice_result`, `voice_session_end`, and the Wear-only
  `notify`/`notify_cancel` added by the N7-RQ2 resolution, see MP-N7-C3-T04), a fixture set
  (valid and invalid examples), and a CI check that decodes every valid fixture and
  rejects every invalid one in Swift and in Kotlin.
- **Non-goals:** no broker logic, no transport code, no UI. The watch-link protocol is
  internal to `packages/aiur-mobile`; it is **not** a daemon contract and is never
  served over HTTP.

## Dependencies and blockers

- **Design gate:** DESIGN-N7 (field set of the snapshot and card depend on D-N7-7 and
  D-N7-8).
- **Predecessors:** MP-N1-C1-T01 (package skeleton), MP-N1-C2-T04 (model generator and
  the cross-language fixture decode harness; this ticket adds a fixture directory to it).
- **Contracts consumed:** `contracts/client-capability-model.md` §7 (snapshot affordance
  shape), `contracts/command-request-and-resolution.md` §6 (answer fields),
  `contracts/voice-session.md` §3.2–3.3 (voice turn fields), MP-N3 plan §5 row states
  (via MP-N3-C3 `MetaRow`).
- **Concurrent:** may run alongside MP-N1-C3 and MP-N3-C3. Nothing else in MP-N7 can
  start before it.

## Verified starting point

- Nothing exists: `git ls-tree -r 45a290e3` has no `watch`/`wear` client paths (only
  unrelated names such as `src/lib/aiur/launcher_watchdog.ex`).
- The Command fields the card needs exist in the store model:
  `context.short_summary` (`src/lib/aiur/decision.ex:25,124`), `options`
  (`decision.ex:125`), `recommendation` (`decision.ex:126`), `urgency`/`blocking`
  (`decision.ex:120-121`).
- Count wording: "N units awaiting commands"
  (`src/lib/aiur_web/components/operator_control_center/overview.ex:168-169`), aria
  "Commands awaiting you" (`overview.ex:53`).
- Precedent for a standalone TS package with its own tests:
  `packages/streamdeck/package.json` (vitest, eslint, typecheck scripts).
- PROPOSED paths (none exist): `packages/aiur-mobile/fixtures/watch-link/`,
  `packages/aiur-mobile/fixtures/watch-link/schema/*.schema.json`.

## Chosen design

Every message is a JSON object (WatchConnectivity dictionaries and Data Layer byte
payloads both carry the UTF-8 JSON encoding of it, under one key `m` for WCSession
dictionaries) with a common envelope:

```json
{ "v": 1, "type": "answer", "id": "<uuid>", "sent_at": "2026-10-06T16:00:00Z", "body": { } }
```

| `type` | Body (required fields in bold) |
|---|---|
| `snapshot` | **`as_of`**, **`phone_reachable_to_machine`** `{machine_id: "reachable"|"unreachable"}`, **`instances[]`**: `{instance_id, machine_label, repository_label, row_state, executor_state, active_agents: Fact, awaiting: Fact, awaiting_blocking: Fact, build_progress: Fact?, background_agents: Fact?, affordances}`; **`open_commands[]`** capped at 10 per instance: `{instance_id, decision_id, short_summary, urgency, blocking, created_at}` |
| `get_command` | **`instance_id`**, **`decision_id`** |
| `get_command_result` | **`outcome`** ∈ `ok | not_found | unreachable | revoked | unknown`; `card` when ok: `{decision_id, version, short_summary, excerpt_lines[≤2], options[≤3]{id,label}, recommended_option_id?, status, resolved?{by_surface, at, summary}}` |
| `answer` | **`instance_id`**, **`decision_id`**, **`expected_version`**, **`idempotency_key`**, **`created_at`**, exactly one of `selected_option_id` / `custom_response` |
| `answer_result` | **`idempotency_key`**, **`outcome`** ∈ `delivered | duplicate | conflict | stale | failed | unknown`, `winner?`, `reason?` |
| `voice_turn` | **`session`**, **`seq`**, **`mode`** ∈ `dictate | converse`, **`target`** `{instance_id, decision_id?}`, **`audio`** `{format: "pcm_s16le_16k_mono"|"aac_lc", file_ref}` |
| `voice_result` | **`session`**, **`seq`**, **`outcome`**, `transcript?`, `reply_text?`, `reply_audio_ref?` |
| `voice_session_end` | **`session`**, **`reason`** |
| `notify` (Wear only, phone → watch) | **`instance_id`**, **`decision_id`**, **`title`**, **`short_summary`**, **`dismissal_id`** (`<instance_id>:<decision_id>`), `urgency` |
| `notify_cancel` (Wear only) | **`dismissal_id`**, **`reason`** ∈ `resolved | revoked | superseded` |

`Fact` is the MP-N3 summary envelope (`contracts/pairing-and-instance-registry.md` §7):
`{status: available|unavailable|disabled|unknown, value?, observed_at, age_ms, reason?}`.
`value` is present only when `status == available`.

Invariants (encoded in schemas and in negative fixtures):

1. Unknown `v` major → reject; unknown fields → ignore (forward compatibility).
2. `snapshot` never contains question text beyond `short_summary`, never transcript
   text, tokens, URLs or `device_id`. Max encoded size 32 KiB (a Data Layer item is limited
   to 100 KB, <https://developer.android.com/training/wearables/data/data-items>, accessed
   2026-10-06, page updated 2026-09-22; WatchConnectivity application-context size is not
   documented, so the budget is set by us and enforced by test).
3. `answer` has exactly one of `selected_option_id`/`custom_response`; `custom_response`
   ≤ 4,000 characters (the E5 dictated-field cap, `MP-E5-C4-T3`).
4. `outcome` values are closed sets; a client receiving an unlisted value treats it as
   `unknown` (AGENTS.md "a collapsed cause names the collapse at the source").

## Implementation steps

1. Add `packages/aiur-mobile/fixtures/watch-link/schema/` with one JSON Schema (draft
   2020-12) per message and `envelope.schema.json`.
2. Add `fixtures/watch-link/valid/*.json` (at least one per type, plus: snapshot with every
   `row_state`; Fact in each status; answer with option and with custom text) and
   `fixtures/watch-link/invalid/*.json` (both answer fields; neither; `v: 2`; Fact
   `unavailable` carrying `value: 0`; oversize snapshot generated by a script).
3. Generate Swift `Codable` and Kotlin `kotlinx.serialization` models with the generator
   pinned by MP-N1-C2-T04 into `native/apple-core/Sources/AiurClientKit/WatchLink/` and
   `native/android-core/src/main/kotlin/.../watchlink/` (PROPOSED).
4. Add Swift `WatchLinkFixtureTests` and Kotlin `WatchLinkFixtureTest` that iterate the
   directory: valid → decode and re-encode equal (key order ignored); invalid → decode
   or validation fails.
5. Add a TS schema test (vitest + ajv, both already common in the npm ecosystem; pin
   versions in `package.json`) so the phone JS side (snapshot debugging screen only) agrees.

## Non-happy paths

- **Version skew** between phone and watch app builds: phone and watch ship together
  (watchOS app inside the iOS bundle; Wear app same application ID), but Wear updates can
  lag. Rule 1 lets a v1 watch read a v1.x phone. A `v: 2` message gets an `answer_result`
  `failed{reason: "watch_link_version"}` and the watch shows "Update the watch app".
- **Privacy:** invariant 2 is tested by a fixture scanner that fails on any key named
  `token`, `url`, `device_id`, `question`, `transcript`.

## Compatibility and rollout

New files only. No daemon change, no config, no flag. Rollback = delete the directory.

## Verification

Commands (PROPOSED, defined by MP-N1-C1/C2):

```text
npm --prefix packages/aiur-mobile test -- watch-link
xcodebuild test -scheme AiurClientKit -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:AiurClientKitTests/WatchLinkFixtureTests
packages/aiur-mobile/native/android-core/gradlew -p packages/aiur-mobile/native/android-core test --tests '*WatchLinkFixtureTest'
```

| Test | Expected | Must fail without |
|---|---|---|
| `WatchLinkFixtureTests.testValidFixturesRoundTrip` (Swift, Kotlin twin) | every valid fixture decodes and re-encodes | the generated models (delete one field from a model → fails) |
| `testInvalidFixturesRejected` | every invalid fixture fails | the "exactly one of" validator (remove it → `answer-both.json` decodes → fails) |
| `testUnavailableFactCarriesNoValue` | `fact-unavailable-with-zero.json` rejected | the Fact `value` presence rule |
| `testSnapshotSizeBudget` | generated 33 KiB snapshot rejected; 31 KiB accepted | the size check |
| `watch-link.privacy.test.ts` | no forbidden key in any valid fixture | the scanner list |

Mutation check: run each "must fail without" by reverting the named hunk in a worktree
(AGENTS.md "Tests must fail without the production change they guard").

## Completion and handoff

- [ ] Schemas and fixtures for all ten types; decode tests green in TS, Swift, Kotlin.
- [ ] CI job from MP-N1-C1-T02 runs the three commands.
- [ ] Docs: none (internal protocol; no CLI, config or user surface).
- Dependents: MP-N7-C1-T02, C1-T03, C1-T04, C1-T05, C2-T02, C3-T02, C4-T03.
