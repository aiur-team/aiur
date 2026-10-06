---
ticket_id: MP-E6-C3-T03
feature_id: MP-E6
chunk_id: MP-E6-C3
bucket: 2-platform
title: Privacy preflight before every conversation and the voice.conversation capability
status: blocked
blocked_by: ["DESIGN-E6 (waived for this ticket: backend; refusal copy reuses contract §8 code)", MP-E6-C1-T01, MP-E6-C3-T01, MP-E6-C2-T02, MP-E5-C2-T03]
prior_units: []
prior_boundaries: [VOX]
prior_features: [integrations-51]
prior_findings: []
size_owner: n/a (new files)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C3-T03 — `Preflight` and `Capability`

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C3.
- **User value:** aiur refuses to start a voice conversation if the provider agent would
  record audio or has lost the privacy settings aiur relies on, rather than trusting a
  one-time setup.
- **Deliverable:**
  1. `Aiur.VoiceConversation.Preflight.check/1` (PROPOSED): `GET` the agent; pass only if
     `record_voice == false`, retention is the configured shortest value, and the required
     overrides are enabled; result cached 10 minutes; refusal
     `{:error, :privacy_preflight_failed, [mismatch]}`.
  2. `Aiur.VoiceConversation.Capability.capabilities/0` (PROPOSED) producing the
     `voice.conversation` entry of contract §7, registered like MP-E5-C2-T03.
- **Non-goals:** repairing (C3-T02 `--repair`).

## Dependencies and blockers

- **Spike:** RQ-E6-3 decides the retention field and its accepted shortest value.
- **Predecessors:** C3-T01 (`agent_id`), C2-T02 (http + error mapping), MP-E5-C2-T03
  (`voice.stt` source and registration pattern).

## Verified starting point (base `45a290e3`)

- No preflight exists (new capability). Capability shape and reasons:
  `contracts/identity-and-capabilities.md` §2.2; contract §7 table row `voice.conversation`.
- Precedent for "check presence before starting": `Realtime.boot/2` returns
  `{:error, :unconfigured}` before connecting (`realtime.ex:122-140`).

## Chosen design

- `check(agent_id)` → `:ok | {:error, :privacy_preflight_failed, mismatches} |
  {:error, code}` where `code` is the C2-T02 provider error mapping.
- Cache: `{agent_id, result, checked_at}` in a small ETS table owned by the voice supervisor;
  failures are **not** cached longer than 60 s so a `--repair` takes effect quickly.
- Capability states:

| Condition | `voice.conversation` |
| --- | --- |
| component not compiled/started | `unavailable/not_installed` |
| `voice.stt` unavailable | `unavailable/dependency_unavailable`, `depends_on: ["voice.stt"]` |
| no `agent_id` | `unavailable/not_configured` |
| last preflight failed | `unavailable/not_configured` with `detail: "privacy_preflight_failed"` |
| preflight never run since boot | `unknown/unknown` (the first Start runs it) |
| `voice.tts` unavailable | `degraded/dependency_unavailable`, `depends_on: ["voice.tts"]` |
| otherwise | `available` |

- The session (C4-T01) calls `check/1` before `Provider.open/1`; a failure ends the start
  with `privacy_preflight_failed` (contract §8).

## Implementation steps

1. `preflight.ex` with injected http and clock.
2. `capability.ex` and registration.
3. Tests.

## Non-happy paths

- Provider unreachable during preflight → `provider_unavailable`, no session; capability
  unchanged (not "failed").
- Agent deleted → `not_configured` with detail `agent_missing`.

## Compatibility and rollout

New; no config beyond C3-T01. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "a recording agent fails preflight" | fixture `record_voice: true` → `privacy_preflight_failed`, mismatch list names it |
| "overrides disabled fails preflight" | fixture without prompt override → fail |
| "a passing result is cached; a failing one expires in 60 s" | injected clock |
| "preflight never run reports unknown, not available" | fresh boot → `unknown` |
| capability table test | each row above |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/preflight_test.exs test/aiur/voice_conversation/capability_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation checks.** Return `:ok` when `record_voice` is missing from the response: add a
fixture without the field — the test "a missing record_voice field fails closed" must fail.
Replace the never-run `unknown` branch with `available`: the unknown test fails.

## Completion and handoff

- [ ] Preflight and capability; tests green.
- [ ] Docs: covered by MP-E6-C9-T01 (privacy table "aiur checks before every session").
- **Dependents:** MP-E6-C4-T01, MP-E5-C3-T01/T02 (Converse visibility).
