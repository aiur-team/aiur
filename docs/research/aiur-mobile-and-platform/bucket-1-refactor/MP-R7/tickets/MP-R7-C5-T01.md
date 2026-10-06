---
ticket_id: MP-R7-C5-T01
feature_id: MP-R7
chunk_id: MP-R7-C5
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: aiur-claude protocol fixture and replay test (detect sibling drift)
status: ready
blocked_by: [DESIGN-R7, MP-R7-C1-T04]
prior_units: [U4]
prior_boundaries: [CLD (22)]
prior_features: []
prior_findings: [MP-R7 plan F7; minimum aiur-claude version resolved here]
size_owner: n/a (test, fixtures and one script)
base_sha: 45a290e3
sibling_ref: "its-everdred/claude-app-server @ b1ea979 (local origin/main == HEAD, 2026-09-18); tag v1.1.0 = 3478281"
researched: 2026-10-06
---

# MP-R7-C5-T01 — aiur-claude protocol fixture and replay test

## Identity and outcome

- Bucket 1, MP-R7, chunk C5, ticket T01.
- **User value:** none visible directly. A sibling `aiur-claude` upgrade that
  renames a method, changes a response shape or drops a notification fails a
  named aiur test instead of stranding headless Claude agents in production.
- **Deliverable:** (1) a recorded NDJSON conversation of every JSON-RPC
  message aiur sends to and expects from `aiur-claude`; (2) a replay test that
  drives `Aiur.Claude.CodingAgent` through it; (3) a re-record script run
  against a sibling checkout; (4) the minimum supported sibling version written
  in the registry comment (no rendered string changes).
- **Non-goals:** no change to the sibling; no change to the install hint text
  (DESIGN-R7 §1: install hints stay identical); no `turn/steer` use.

## Dependencies and blockers

- **DESIGN-R7**; C1-T04 (fixture test joins the characterization suite).
- Concurrent with C1-T01..T03, C2-*.
- Dependents: C5-T02 (cites the advertised `turn/steer`), MP-E7-C4 (sibling
  steer fix must re-record this fixture).

## Verified starting point

aiur side (base `45a290e3`):

| Direction | Method / shape | aiur code |
| --- | --- | --- |
| → | `initialize` with `capabilities.experimentalApi: true`, `clientInfo` | `app_server/messages.ex:80-96` |
| → | `initialized` notification | `app_server/messages.ex:98-101` |
| → | `thread/start` `{permissionMode, cwd, dynamicTools}`; expects `{"thread": {"id"}}` | `claude/coding_agent.ex:227-248` |
| → | `turn/start` `{threadId, input:[{type:text}], cwd, title, model?}`; expects `{"turn": {"id"}}` | `claude/coding_agent.ex:253-282` |
| → | operator `turn/start` `{threadId, input, cwd, model?}` | `claude/coding_agent.ex:114-139` |
| → | `turn/interrupt` `{threadId, turnId}` | `app_server/interrupts.ex:55-73` |
| ← | `turn/completed`, `turn/failed` (+ optional `provider_error`), `item/tool/call` (server request), `rate_limit/update` | `claude/coding_agent.ex:302,316-331,336-363,369` |
| ← | `turn/started`, `item/created`, `item/progress`, `turn/permission_denied`, `initialized` (humanized/transcribed) | `claude/event_humanizer.ex:19-103`, `claude/transcript.ex:43` |
| ← | error `-32003` TurnBusy is handled as "restore, not fail" | `agent_runner/checkpoint_delivery.ex:176` |

Sibling side (`claude-app-server` @ `b1ea979`): dispatch table
`src/server.ts:280-286` (`initialize`, `thread/start|resume|fork`,
`turn/start|steer|interrupt`); `initialize` result advertises
`turns: ["start","steer","interrupt"]` and `dynamicTools: true` (:308-317);
`turn/start` returns `{turn:{id}}` (:509) and rejects a busy thread with
`TurnBusy` (:466-468; code −32003, `src/protocol.ts:57`); error codes
`NotInitialized −32000`, `NoActiveTurn −32004` (`protocol.ts:55,58`). The
sibling's own tests use `test/fixtures/fake-claude.mjs` to stand in for the
`claude` CLI.

**Minimum supported version (resolved):** `aiur-claude` **1.1.0**
(tag `v1.1.0` = `3478281`, 2026-07-28). Earlier history: dynamic tools via MCP
bridge arrived in `72ef959` and the package was renamed to `aiur-claude` in
`1ca1442` (2026-07-16), so no earlier `aiur-claude`-named release serves aiur's
`dynamicTools`. The `turn/failed.provider_error` provenance that aiur reads
first (`claude/notification_policy.ex:59-70`) is only in unreleased `b1ea979`
(`git show v1.1.0:src/server.ts` has no `provider_error`); aiur tolerates its
absence by falling back to legacy classification
(`claude/coding_agent.ex:328-331,422-426`). So 1.1.0 works with degraded
refusal provenance; the next sibling release restores it. Whether npm has a
release after 1.1.0 was not checked (network not used); the implementer must
run `npm view aiur-claude versions` and record it.

## Chosen design

- Fixture `src/test/fixtures/aiur_claude/protocol-1.1.0.ndjson` (PROPOSED):
  one line per message, `{"dir":"out"|"in","msg":{…}}`, with placeholders for
  volatile ids (`"<thread>"`, `"<turn>"`, `"<req>"`). Scenarios: init →
  thread/start → turn/start → item/tool/call round-trip → turn/completed;
  operator turn/start after completion; turn/interrupt mid-turn; turn/failed
  with and without `provider_error`; turn/start rejected −32003.
- Replay test drives the real adapter against a fake app-server process that
  answers from the fixture (reuse the shell fake pattern in
  `claude/coding_agent_test.exs:614-680`, which already scripts responses by
  matching `"turn/start"` etc.), and asserts aiur's outbound frames equal the
  fixture's `out` lines after placeholder normalization.
- Re-record script `scripts/record-aiur-claude-protocol.sh` (PROPOSED): given
  `AIUR_CLAUDE_DIR`, runs the sibling's built server with its
  `fake-claude.mjs`, plays the fixture's `out` lines and writes the observed
  `in` lines to a temp file, then `diff`s against the fixture. Manual, run on
  every sibling upgrade; not in CI (CI has no sibling checkout).
- Registry comment on `providers/claude.ex:19-21`: "requires aiur-claude ≥ 1.1.0;
  provider_error provenance needs > 1.1.0". Comment only.

## Implementation steps

1. Write the fixture from the table above; confirm by running the
   re-record script once against `b1ea979` and once against `v1.1.0`
   (expect the `provider_error` scenario to differ; fixture records the
   `b1ea979` shape and the test accepts both via the legacy fallback).
2. Add `src/test/aiur/claude/protocol_fixture_test.exs` (PROPOSED),
   `@moduletag :r7_characterization`.
3. Add the script and the registry comment.

## Non-happy paths

- Sibling advertises `turn/steer` but it drops text (F7): fixture records the
  advertisement; test asserts aiur never **sends** `turn/steer` (guard until
  MP-E7-C4).
- Unknown inbound notification: aiur emits `:other_message`
  (`app_server/operator_delivery.ex:14-25` for responses); fixture includes one
  unknown notification and asserts no crash.
- TurnBusy (−32003) restores rather than fails the queued item (existing
  `queue_drain_test.exs:418`); referenced, not duplicated.

## Compatibility and rollout

Test, fixture, script and a code comment. No config, flag or string change.

## Verification

Tests (pass at base; regression guards):

- `aiur's outbound frames match the recorded aiur-claude 1.1.0 conversation`
- `aiur accepts every recorded inbound frame without an unexpected error`
- `turn/failed without provider_error still classifies through the legacy path`
- `aiur never sends turn/steer` (guard until MP-E7-C4)

Commands: from `src/`, `mise exec -- mix test test/aiur/claude/protocol_fixture_test.exs`;
manual drift check:
`AIUR_CLAUDE_DIR=/path/to/claude-app-server scripts/record-aiur-claude-protocol.sh`
(expected: empty diff at `b1ea979`).

Mutation witnesses: rename `"permissionMode"` at `claude/coding_agent.ex:232`
→ outbound test fails; change `{"thread" => …}` match at :239 → inbound test
fails; edit the fixture's `turn/start` result to `{"turn_id": …}` (simulated
sibling drift) → inbound test fails.

## Completion and handoff

- [ ] Fixture, replay test, script, registry comment.
- [ ] `npm view aiur-claude versions` output recorded in the PR body.
- [ ] Drift check run against `b1ea979` and `v1.1.0`, outputs in PR body.
- Docs: none user-facing (install hint unchanged by DESIGN-R7).
- Dependents: C5-T02, MP-E7-C4 sibling steer fix (must re-record).
